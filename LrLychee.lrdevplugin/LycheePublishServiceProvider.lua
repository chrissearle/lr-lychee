--[[----------------------------------------------------------------------------
LycheePublishServiceProvider.lua - Lightroom Publish Service for Lychee Gallery

Provides publish service integration between Lightroom Classic and Lychee.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrPathUtils = import 'LrPathUtils'
local LrBinding = import 'LrBinding'
local LrLogger = import 'LrLogger'
local LrErrors = import 'LrErrors'
local LrColor = import 'LrColor'
local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrMD5 = import 'LrMD5'
local LrFileUtils = import 'LrFileUtils'

local logger = LrLogger('LycheePlugin')
logger:enable('logfile')

local LycheeAPI = require 'LycheeAPI'

-- Keep in sync with VERSION in Info.lua (used only for the log banner).
local pluginVersion = '1.2.1'

local publishServiceProvider = {}

-- Helpers for persisting pending collection settings across Lightroom callback invocations.
-- Lightroom re-executes this module file for each callback (fresh Lua state), so module-level
-- tables reset between calls. LrPrefs is catalog-backed and survives across contexts.
-- Keys are "pending_<name>"; entries are cleared after the first successful publish.
local function storePendingSettings(name, settings)
    LrPrefs.prefsForPlugin()['pending_' .. name] = settings
end

local function getPendingSettings(name)
    return LrPrefs.prefsForPlugin()['pending_' .. name]
end

local function clearPendingSettings(name)
    LrPrefs.prefsForPlugin()['pending_' .. name] = nil
end

-- Remember the MD5 of the file we last uploaded for a given Lychee photo, so a
-- re-publish can tell "the image changed" from "only metadata changed".
--
-- The SDK gives us no usable signal for this inside processRenderedPhotos:
-- rendition.publishedPhoto is nil, rendition.wasEditedSinceLastPublish is not a real
-- property, and the catalog route (getPublishServices -> getPublishedPhotos ->
-- getEditedFlag) yields from inside the read-access block, so it cannot be guarded
-- with pcall. Hashing the rendered file is self-contained and needs no SDK support.
local function storePhotoHash(photoId, hash)
    LrPrefs.prefsForPlugin()['hash_' .. tostring(photoId)] = hash
end

local function getPhotoHash(photoId)
    return LrPrefs.prefsForPlugin()['hash_' .. tostring(photoId)]
end

local function clearPhotoHash(photoId)
    LrPrefs.prefsForPlugin()['hash_' .. tostring(photoId)] = nil
end

-- Offset (1-based) of the JPEG SOS marker - where compressed image data begins.
-- Everything before it is metadata and coding tables. Lightroom writes title and
-- caption into APP1/APP13 segments there, so a caption change alters the file's
-- bytes without touching a single pixel; hashing from SOS onwards ignores that.
local function jpegImageDataOffset(data)
    if #data < 4 then return nil end
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil end
    local i = 3
    while i + 3 <= #data do
        if data:byte(i) ~= 0xFF then return nil end
        local marker = data:byte(i + 1)
        if marker == 0xDA then
            return i
        end
        if marker >= 0xD0 and marker <= 0xD9 then
            i = i + 2
        else
            local len = data:byte(i + 2) * 256 + data:byte(i + 3)
            if len < 2 then return nil end
            i = i + 2 + len
        end
    end
    return nil
end

-- MD5 of a rendered photo's image data, or nil if the file cannot be read.
local function fileHash(path)
    local contents = LrFileUtils.readFile(path)
    if not contents then
        return nil
    end

    local offset = jpegImageDataOffset(contents)
    if offset then
        return LrMD5.digest(contents:sub(offset))
    end

    -- Not a JPEG (the service also allows PNG). Hash the whole file: a metadata
    -- change will then look like an image change and force a re-upload, which is
    -- the safe direction to be wrong in.
    return LrMD5.digest(contents)
end

-- Forward declaration (defined later, but called from processRenderedPhotos)
local saveAlbumSettingsToLychee

-- Define the fields that will be stored in export presets
publishServiceProvider.exportPresetFields = {
    { key = 'gallery_url', default = '' },
    { key = 'api_token', default = '' },
}

-- Define that this is a publish service (not just export)
publishServiceProvider.supportsIncrementalPublish = 'only'

-- Small icon for the publish service
publishServiceProvider.small_icon = 'logo.png'

-- Define publish service behavior
publishServiceProvider.publish_fallbackNameBinding = 'fullname'

-- Title for the service
publishServiceProvider.title = 'Lychee Gallery'

-- Allow collections to be renamed
publishServiceProvider.canRenamePublishedCollection = true

-- Allow collection sets to be renamed
publishServiceProvider.canRenamePublishedCollectionSet = true

-- Define what happens with collections
function publishServiceProvider.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = 'Photos',
        defaultCollectionCanBeDeleted = true,
        canAddCollection = true,
        canAddCollectionSet = true,
    }
end

-- Helper to validate publish settings
local function validateSettings(publishSettings)
    if not publishSettings.gallery_url or publishSettings.gallery_url == '' then
        return false
    end
    if not publishSettings.api_token or publishSettings.api_token == '' then
        return false
    end
    return true
end

-- Store a Lychee album ID and its gallery URL on a published collection or
-- collection set.
--
-- setRemoteId/setRemoteUrl require catalog write access (see DEVELOPMENT.md,
-- "Remote ID Management"). Called without the gate they fail silently, which is
-- what left newly published albums with no Published Album URL in the LR panel.
local function storeRemoteAlbum(target, albumId, publishSettings, label)
    if not target or not albumId or albumId == '' then
        return false
    end

    local albumUrl = publishSettings.gallery_url .. '/gallery/' .. albumId

    local function apply()
        target:setRemoteId(albumId)
        target:setRemoteUrl(albumUrl)
    end

    -- No pcall around withWriteAccessDo - it yields, and yielding across a pcall
    -- boundary raises "Yielding is not allowed within a C or metamethod call".
    local catalog = LrApplication.activeCatalog()
    catalog:withWriteAccessDo('Set Lychee album ID', apply)

    logger:info('Stored remoteId ' .. albumId .. ' and URL ' .. albumUrl .. ' on ' .. label)
    return true
end

-- Walk the parents chain and ensure all ancestor albums exist on Lychee.
-- Creates any missing ancestor albums automatically.
-- Returns the innermost parent's Lychee album ID (or nil for root-level).
local function ensureAncestorAlbums(publishSettings, parents)
    if not parents or #parents == 0 then
        return nil
    end

    local currentParentId = nil

    -- parents is ordered outermost to innermost
    for _, parent in ipairs(parents) do
        if parent.remoteCollectionId and parent.remoteCollectionId ~= '' then
            -- This ancestor already has a Lychee album ID
            currentParentId = parent.remoteCollectionId
            logger:info('Ancestor "' .. (parent.name or '?') .. '" already has remote ID: ' .. currentParentId)
        else
            -- This ancestor needs an album created (or found)
            logger:info('Ancestor "' .. (parent.name or '?') .. '" has no remote ID, finding or creating...')
            local album, err = LycheeAPI.findOrCreateAlbum(publishSettings, parent.name, currentParentId)
            if album and album.id then
                currentParentId = album.id
                logger:info('Ancestor "' .. (parent.name or '?') .. '" resolved to album ID: ' .. currentParentId)
            else
                logger:warn('Failed to ensure ancestor "' .. (parent.name or '?') .. '": ' .. (err or 'unknown'))
                -- Continue with current parent - best effort
            end
        end
    end

    return currentParentId
end

-- Settings UI at the top of the dialog
function publishServiceProvider.sectionsForTopOfDialog(f, propertyTable)
    local bind = LrView.bind
    local share = LrView.share

    return {
        {
            title = 'Lychee Gallery Settings',
            synopsis = bind { key = 'gallery_url', object = propertyTable },

            f:row {
                f:static_text {
                    title = 'Gallery URL:',
                    alignment = 'right',
                    width = share 'title_width',
                },
                f:edit_field {
                    value = bind 'gallery_url',
                    truncation = 'middle',
                    immediate = true,
                    width_in_chars = 40,
                    tooltip = 'The URL of your Lychee gallery (e.g., https://gallery.example.com)',
                },
            },

            f:row {
                f:static_text {
                    title = 'API Token:',
                    alignment = 'right',
                    width = share 'title_width',
                },
                f:password_field {
                    value = bind 'api_token',
                    width_in_chars = 40,
                    tooltip = 'Your Lychee API token (generate in Lychee settings)',
                },
            },

            f:row {
                f:static_text {
                    title = '',
                    width = share 'title_width',
                },
                f:push_button {
                    title = 'Test Connection',
                    action = function()
                        LrFunctionContext.callWithContext('testConnection', function(context)
                            LrDialogs.attachErrorDialogToFunctionContext(context)
                            LrTasks.startAsyncTask(function()
                                local success, message = LycheeAPI.testConnection(propertyTable)
                                if success then
                                    LrDialogs.message('Connection Test', 'Successfully connected to Lychee gallery!', 'info')
                                else
                                    LrDialogs.message('Connection Test Failed', message or 'Could not connect to gallery.', 'critical')
                                end
                            end)
                        end)
                    end,
                },
            },
        },
    }
end

-- Validate settings before export
function publishServiceProvider.startDialog(propertyTable)
    -- Nothing special needed on dialog start
end

-- Called when user updates the dialog
function publishServiceProvider.endDialog(propertyTable)
    -- Nothing special needed on dialog end
end

-- Check if settings are complete
function publishServiceProvider.updateExportSettings(exportSettings)
    -- Validation happens in processRenderedPhotos
end

-- Main function to process and upload rendered photos
function publishServiceProvider.processRenderedPhotos(functionContext, exportContext)
    logger:info('LrLychee v' .. pluginVersion .. ' — processRenderedPhotos started')
    local exportSession = exportContext.exportSession
    local publishSettings = exportContext.propertyTable
    local nPhotos = exportSession:countRenditions()

    -- Validate settings
    if not publishSettings.gallery_url or publishSettings.gallery_url == '' then
        LrDialogs.message('Configuration Error', 'Please configure the gallery URL in the publish service settings.', 'critical')
        return
    end

    if not publishSettings.api_token or publishSettings.api_token == '' then
        LrDialogs.message('Configuration Error', 'Please configure the API token in the publish service settings.', 'critical')
        return
    end

    -- Get collection info
    local publishedCollectionInfo = exportContext.publishedCollectionInfo
    local collectionName = publishedCollectionInfo.name

    -- Create progress scope
    local progressScope = exportContext:configureProgress {
        title = nPhotos > 1
            and string.format('Publishing %d photos to Lychee', nPhotos)
            or 'Publishing 1 photo to Lychee',
    }

    -- Resolve album for this collection
    -- 1. If we already have a remoteId, use it directly (but check if it needs moving)
    -- 2. Otherwise, ensure ancestor albums exist and find/create under the correct parent
    progressScope:setCaption('Finding or creating album...')
    -- publishedCollectionInfo.remoteId is populated from whatever we last recorded via
    -- exportSession:recordRemoteCollectionId. It is nil only on a genuinely new
    -- collection - if it were ever wrongly nil, the move detection below could not run
    -- and dragging into a set would create a duplicate album instead of moving one.
    local albumId = publishedCollectionInfo.remoteId
    local isNewAlbum = not albumId or albumId == ''
    logger:info('Collection "' .. collectionName .. '" remoteId=' .. tostring(albumId))

    -- Determine the expected parent album from the collection set hierarchy
    local expectedParentId = ensureAncestorAlbums(publishSettings, publishedCollectionInfo.parents)

    if not albumId or albumId == '' then
        -- No remote ID yet - find or create under the correct parent
        local album, albumErr = LycheeAPI.findOrCreateAlbum(publishSettings, collectionName, expectedParentId)
        if not album then
            LrDialogs.message('Album Error', albumErr or 'Could not find or create album.', 'critical')
            return
        end

        albumId = album.id
    else
        -- Album already exists on Lychee - check if it needs to be moved
        -- (e.g. collection was dragged into/out of a collection set)
        local currentParentId, parentErr = LycheeAPI.getAlbumParentId(publishSettings, albumId)
        -- currentParentId is nil for root-level, a string for nested
        -- expectedParentId is nil for root-level, a string for nested
        local needsMove = false
        if expectedParentId and currentParentId then
            needsMove = (expectedParentId ~= currentParentId)
        elseif expectedParentId or currentParentId then
            -- One is nil and the other isn't: moving to/from root
            needsMove = true
        end

        if needsMove then
            logger:info('Album ' .. albumId .. ' needs moving: current parent=' ..
                tostring(currentParentId) .. ', expected parent=' .. tostring(expectedParentId))
            local moveOk, moveErr = LycheeAPI.moveAlbum(publishSettings, albumId, expectedParentId)
            if moveOk then
                logger:info('Successfully moved album ' .. albumId .. ' to parent ' .. tostring(expectedParentId))
            else
                LrDialogs.message('Move Warning',
                    'Could not move album to its new location in Lychee: ' .. (moveErr or 'Unknown error') ..
                    '\nPhotos will still be uploaded to the existing album.',
                    'warning')
            end
        end
    end
    if not albumId or albumId == '' then
        LrDialogs.message('Album Error', 'Album was found/created but no ID was returned.', 'critical')
        return
    end

    -- Record the album against the published collection.
    --
    -- Inside processRenderedPhotos the supported route is the exportSession, mirroring
    -- rendition:recordPublishedPhotoId/Url for photos. publishedCollectionInfo has no
    -- .publishedCollection here, so setRemoteId/setRemoteUrl had nothing to write to -
    -- that is why newly published albums showed no Published Album URL.
    local albumUrl = publishSettings.gallery_url .. '/gallery/' .. albumId

    local recOk, recErr = pcall(function()
        exportSession:recordRemoteCollectionId(albumId)
        exportSession:recordRemoteCollectionUrl(albumUrl)
    end)
    if recOk then
        logger:info('Recorded collection id ' .. albumId .. ' and URL ' .. albumUrl)
    else
        logger:warn('Could not record collection id/URL: ' .. tostring(recErr))
    end

    -- Apply collection settings for newly created albums.
    -- Settings are stored in LrPrefs by updateCollectionSettings (which runs in a separate
    -- Lua state), retrieved here, applied to the newly created Lychee album, then cleared.
    if isNewAlbum then
        local settingsToApply = getPendingSettings(collectionName)
        logger:info('New album "' .. collectionName .. '": prefs pending settings ' ..
            (settingsToApply and 'found' or 'NOT found'))

        if not settingsToApply and publishedCollectionInfo.publishedCollection then
            -- Fallback: read settings from the catalog if prefs entry is missing.
            logger:info('No pending settings found for "' .. collectionName .. '", reading from catalog...')
            local catalog = LrApplication.activeCatalog()
            catalog:withReadAccessDo(function()
                local info = publishedCollectionInfo.publishedCollection:getCollectionInfoSummary()
                if info and info.collectionSettings then
                    settingsToApply = info.collectionSettings
                    logger:info('Loaded collection settings from catalog for "' .. collectionName .. '"')
                else
                    logger:info('Catalog returned no collectionSettings for "' .. collectionName ..
                        '" (info=' .. tostring(info ~= nil) .. ')')
                end
            end)
        elseif not settingsToApply then
            logger:info('Cannot fall back to catalog: publishedCollection is nil for "' .. collectionName .. '"')
        end

        if settingsToApply then
            logger:info('New album created — applying collection settings for "' .. collectionName .. '"')
            saveAlbumSettingsToLychee(publishSettings, albumId, collectionName, settingsToApply)
        else
            logger:info('WARNING: No settings to apply for new album "' .. collectionName ..
                '" — settings will need to be re-entered and published again')
        end
        clearPendingSettings(collectionName)
    end

    -- Get existing photo IDs and data in the album
    -- This is used to:
    -- 1. Avoid duplicate ID assignment when uploading multiple photos
    -- 2. Preserve existing metadata when updating (e.g., don't blank title if user only changed caption)
    local knownPhotoIds = {}
    local knownPhotoData = {}  -- Lookup table by photo ID
    local albumPhotos = LycheeAPI.getAlbumPhotos(publishSettings, albumId)
    if albumPhotos and albumPhotos.photos then
        for _, photo in ipairs(albumPhotos.photos) do
            if photo.id then
                table.insert(knownPhotoIds, photo.id)
                knownPhotoData[photo.id] = photo
                logger:info('Known photo ID in album: ' .. photo.id)
            end
        end
    end
    logger:info('Starting uploads with ' .. #knownPhotoIds .. ' known photo IDs')

    -- Process each rendition
    local failures = {}

    for i, rendition in exportContext:renditions { stopIfCanceled = true } do
        progressScope:setPortionComplete((i - 1) / nPhotos)

        if progressScope:isCanceled() then break end

        -- Brief pause between uploads to let Lychee index each photo
        if i > 1 then
            LrTasks.sleep(1)
        end

        local success, pathOrMessage = rendition:waitForRender()

        if progressScope:isCanceled() then break end

        if success then
            local photoPath = pathOrMessage
            local photoName = LrPathUtils.leafName(photoPath)

            -- Check if this photo was already published (has a remote ID)
            local existingPhotoId = rendition.publishedPhotoId

            -- Get photo metadata for title/description
            local photo = rendition.photo
            local title = photo:getFormattedMetadata('title')
            local caption = photo:getFormattedMetadata('caption')

            -- Helper: check if a photo with this filename already exists in the album.
            -- Returns the photo ID if found, nil otherwise.
            local function findDuplicateInAlbum(fileName)
                -- Refresh album data to catch recently-uploaded photos
                local freshAlbumData = LycheeAPI.getAlbumPhotos(publishSettings, albumId)
                if freshAlbumData then
                    local matchId = LycheeAPI.findPhotoByFilename(freshAlbumData, fileName)
                    if matchId then
                        logger:info('Found existing photo in album matching "' .. fileName .. '": ' .. matchId)
                        return matchId
                    end
                end
                return nil
            end

            -- Helper: upload a photo, but first check if it already exists in the album.
            -- Returns { id = photoId } on success (whether matched or uploaded), or nil + error.
            local function uploadOrMatchPhoto(filePath, fileName)
                -- Check for an existing copy first
                local existingId = findDuplicateInAlbum(fileName)
                if existingId then
                    -- Already in the album - skip upload, use the existing one
                    logger:info('Skipping upload of "' .. fileName .. '" - already exists as ' .. existingId)
                    if not knownPhotoData[existingId] then
                        table.insert(knownPhotoIds, existingId)
                    end
                    return { id = existingId }, nil
                end

                -- Not found - do the upload
                return LycheeAPI.uploadPhoto(publishSettings, filePath, albumId, knownPhotoIds)
            end

            -- Helper function to update metadata after upload
            -- Uses existing Lychee data as fallback to avoid blanking fields
            local function updatePhotoMetadata(photoId)
                -- Get existing photo data from Lychee (if available)
                local existingData = knownPhotoData[photoId] or {}
                local existingTitle = existingData.title or ''
                local existingDescription = existingData.description or ''

                -- Build metadata, using LR values if set, otherwise preserve existing
                local metadata = {
                    title = (title and title ~= '') and title or existingTitle,
                    description = (caption and caption ~= '') and caption or existingDescription,
                }

                -- Only update if we have something to send
                if metadata.title ~= '' or metadata.description ~= '' then
                    logger:info('Updating metadata - title: "' .. metadata.title .. '", description: "' .. metadata.description .. '"')
                    local updateResult, updateErr = LycheeAPI.updatePhoto(publishSettings, photoId, albumId, metadata)
                    if not updateResult then
                        -- Log warning but don't fail the upload
                        table.insert(failures, {
                            photo = photo,
                            message = 'Photo uploaded but metadata update failed: ' .. (updateErr or 'Unknown error'),
                        })
                    end
                end
            end

            if existingPhotoId then
                -- Photo already exists on server

                -- Check if this photo is in a different album (collection was moved in LR).
                -- knownPhotoIds/knownPhotoData were built from the current album's contents.
                -- If the photo isn't there, it's in an old album and needs to be
                -- deleted and re-uploaded to the current one.
                local photoInCurrentAlbum = (knownPhotoData[existingPhotoId] ~= nil)
                if not photoInCurrentAlbum then
                    for _, kid in ipairs(knownPhotoIds) do
                        if kid == existingPhotoId then
                            photoInCurrentAlbum = true
                            break
                        end
                    end
                end

                if not photoInCurrentAlbum then
                    -- Photo is in a different album - delete old copy and re-upload here
                    logger:info('Photo ' .. existingPhotoId .. ' not in current album, re-uploading to new location')
                    progressScope:setCaption(string.format('Relocating %s...', photoName))

                    -- Check if this photo already exists in the current album (duplicate from prior attempt)
                    local duplicateId = findDuplicateInAlbum(photoName)
                    if duplicateId then
                        -- Already in the target album - just adopt it
                        logger:info('Photo already in target album as ' .. duplicateId .. ', skipping re-upload')
                        -- Still delete the old copy from the source album. No albumId
                        -- hint: the old copy is in the *previous* album, not this one.
                        if duplicateId ~= existingPhotoId then
                            local deleteOk, deleteErr = LycheeAPI.deletePhotos(publishSettings, { existingPhotoId })
                            if not deleteOk then
                                logger:warn('Could not delete old copy of ' .. existingPhotoId .. ': ' .. (deleteErr or 'unknown'))
                            end
                        end
                        clearPhotoHash(existingPhotoId)
                        storePhotoHash(duplicateId, fileHash(photoPath))
                        rendition:recordPublishedPhotoId(duplicateId)
                        rendition:recordPublishedPhotoUrl(
                            publishSettings.gallery_url .. '/gallery/' .. albumId .. '/' .. duplicateId
                        )
                        updatePhotoMetadata(duplicateId)
                    else
                        -- Delete from old album (best effort - may fail if album was already
                        -- deleted). No albumId hint: the copy is in the previous album.
                        local deleteOk, deleteErr = LycheeAPI.deletePhotos(publishSettings, { existingPhotoId })
                        if not deleteOk then
                            logger:warn('Could not delete old copy of ' .. existingPhotoId .. ': ' .. (deleteErr or 'unknown'))
                        end

                        -- Upload to the current album
                        local uploadResult, uploadErr = LycheeAPI.uploadPhoto(publishSettings, photoPath, albumId, knownPhotoIds)

                        if uploadResult and uploadResult.id then
                            table.insert(knownPhotoIds, uploadResult.id)
                            clearPhotoHash(existingPhotoId)
                            storePhotoHash(uploadResult.id, fileHash(photoPath))
                            rendition:recordPublishedPhotoId(uploadResult.id)
                            rendition:recordPublishedPhotoUrl(
                                publishSettings.gallery_url .. '/gallery/' .. albumId .. '/' .. uploadResult.id
                            )
                            -- Update metadata on the new copy
                            updatePhotoMetadata(uploadResult.id)
                        else
                            table.insert(failures, {
                                photo = photo,
                                message = 'Failed to relocate photo: ' .. (uploadErr or 'Unknown error'),
                            })
                        end
                    end
                else
                    -- Photo is in the current album - normal update flow.
                    --
                    -- Lightroom only hands us photos that need republishing at all, so
                    -- the question here is narrower: did the *image* change (re-upload)
                    -- or only its metadata (PATCH)? That lives on the published photo as
                    -- getEditedFlag(). `rendition.wasEditedSinceLastPublish` is not an
                    -- SDK property - it read nil every time, so every develop edit was
                    -- silently downgraded to a metadata-only update.
                    -- Compare the freshly rendered file against the one we last
                    -- uploaded for this photo. Different bytes means the image itself
                    -- changed; identical bytes means only metadata did.
                    local renderedHash = fileHash(photoPath)
                    local storedHash = getPhotoHash(existingPhotoId)
                    local wasEdited
                    local editedVia
                    if not renderedHash then
                        -- Could not hash the render. Lightroom only sends photos that
                        -- need republishing, so re-uploading is the safe default: a
                        -- redundant upload is cheap, a stale image online is not.
                        wasEdited = true
                        editedVia = 'fallback (render unreadable)'
                    elseif not storedHash then
                        -- Published before we started recording hashes. Re-upload once;
                        -- the hash is stored below and later publishes settle down.
                        wasEdited = true
                        editedVia = 'fallback (no stored hash)'
                    else
                        wasEdited = (renderedHash ~= storedHash)
                        editedVia = 'file hash'
                    end

                    logger:info('Existing photo ID: ' .. tostring(existingPhotoId))
                    logger:info('Was edited: ' .. tostring(wasEdited) .. ' via ' .. editedVia)
                    logger:info('Title: ' .. tostring(title))
                    logger:info('Caption: ' .. tostring(caption))

                    if wasEdited then
                        -- Image was edited - delete old version and re-upload
                        -- Lychee will read title/description/tags from EXIF on upload
                        progressScope:setCaption(string.format('Re-uploading %s...', photoName))

                        local deleteSuccess, deleteErr = LycheeAPI.deletePhotos(publishSettings, { existingPhotoId }, albumId)
                        if not deleteSuccess then
                            table.insert(failures, {
                                photo = photo,
                                message = 'Failed to delete old version: ' .. (deleteErr or 'Unknown error'),
                            })
                        else
                            -- Remove old ID from known list since we deleted it
                            for idx, id in ipairs(knownPhotoIds) do
                                if id == existingPhotoId then
                                    table.remove(knownPhotoIds, idx)
                                    break
                                end
                            end

                            local uploadResult, uploadErr = LycheeAPI.uploadPhoto(publishSettings, photoPath, albumId, knownPhotoIds)

                            if uploadResult and uploadResult.id then
                                -- Add to known IDs for subsequent uploads
                                table.insert(knownPhotoIds, uploadResult.id)
                                clearPhotoHash(existingPhotoId)
                                storePhotoHash(uploadResult.id, renderedHash)
                                rendition:recordPublishedPhotoId(uploadResult.id)
                                rendition:recordPublishedPhotoUrl(
                                    publishSettings.gallery_url .. '/gallery/' .. albumId .. '/' .. uploadResult.id
                                )
                            else
                                table.insert(failures, {
                                    photo = photo,
                                    message = uploadErr or 'Unknown upload error',
                                })
                            end
                        end
                    else
                        -- Only metadata changed - update via PATCH
                        logger:info('Metadata-only update for photo: ' .. existingPhotoId)
                        progressScope:setCaption(string.format('Updating metadata for %s...', photoName))
                        updatePhotoMetadata(existingPhotoId)
                        storePhotoHash(existingPhotoId, renderedHash)
                        -- Must call recordPublishedPhotoId before recordPublishedPhotoUrl
                        rendition:recordPublishedPhotoId(existingPhotoId)
                        rendition:recordPublishedPhotoUrl(
                            publishSettings.gallery_url .. '/gallery/' .. albumId .. '/' .. existingPhotoId
                        )
                    end
                end
            else
                -- New photo - upload it (or match if already in album)
                -- Lychee will read title/description/tags from EXIF on upload
                progressScope:setCaption(string.format('Uploading %s...', photoName))

                local uploadResult, uploadErr = uploadOrMatchPhoto(photoPath, photoName)

                if uploadResult and uploadResult.id then
                    -- Add to known IDs for subsequent uploads
                    table.insert(knownPhotoIds, uploadResult.id)
                    -- Remember what we uploaded, so a later re-publish can tell an image
                    -- edit from a metadata-only change
                    storePhotoHash(uploadResult.id, fileHash(photoPath))
                    -- Record the published photo ID
                    rendition:recordPublishedPhotoId(uploadResult.id)
                    rendition:recordPublishedPhotoUrl(
                        publishSettings.gallery_url .. '/gallery/' .. albumId .. '/' .. uploadResult.id
                    )
                else
                    table.insert(failures, {
                        photo = photo,
                        message = uploadErr or 'Unknown upload error',
                    })
                end
            end
        else
            table.insert(failures, {
                photo = rendition.photo,
                message = pathOrMessage or 'Render failed',
            })
        end
    end

    progressScope:setPortionComplete(1)

    -- Report any failures
    if #failures > 0 then
        local message = string.format('%d photo(s) failed to upload:\n', #failures)
        for _, failure in ipairs(failures) do
            message = message .. '\n• ' .. (failure.message or 'Unknown error')
        end
        LrDialogs.message('Upload Errors', message, 'warning')
    end
end

-- Delete photos from published collection
function publishServiceProvider.deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)
    -- Validate settings
    if not publishSettings.gallery_url or publishSettings.gallery_url == '' then
        return
    end

    if not publishSettings.api_token or publishSettings.api_token == '' then
        return
    end

    -- Delete photos
    local success, deleteErr = LycheeAPI.deletePhotos(publishSettings, arrayOfPhotoIds)

    if success then
        -- Mark all photos as deleted
        for _, photoId in ipairs(arrayOfPhotoIds) do
            clearPhotoHash(photoId)
            deletedCallback(photoId)
        end
    else
        LrDialogs.message('Delete Failed', deleteErr or 'Could not delete photos from Lychee gallery.', 'critical')
    end
end

-- Called when a Published Collection is being deleted
function publishServiceProvider.deletePublishedCollection(publishSettings, info)
    if not validateSettings(publishSettings) then
        return
    end

    local albumId = info.remoteId

    if albumId and albumId ~= '' then
        local success, err = LycheeAPI.deleteAlbum(publishSettings, albumId)
        if not success then
            LrDialogs.message('Delete Failed',
                err or 'Could not delete album from Lychee gallery.',
                'critical')
        else
            logger:info('Deleted album for collection "' .. (info.name or '') .. '": ' .. albumId)
        end
    end
end

-- Called when a published collection is being renamed
function publishServiceProvider.renamePublishedCollection(publishSettings, info)
    local newName = info.name

    -- Validate settings
    if not publishSettings.gallery_url or publishSettings.gallery_url == '' then
        return
    end

    if not publishSettings.api_token or publishSettings.api_token == '' then
        return
    end

    -- Get the album ID from the published collection
    local albumId = info.remoteId

    if albumId then
        -- Update album title via API
        local success, err = LycheeAPI.renameAlbum(publishSettings, albumId, newName)
        if not success then
            LrDialogs.message('Rename Failed', err or 'Could not rename album in Lychee gallery.', 'warning')
        end
    end
end

-- Called after a new Published Collection Set is created
function publishServiceProvider.didCreateNewPublishedCollectionSet(publishSettings, info)
    if not validateSettings(publishSettings) then
        return
    end

    -- Ensure all ancestor albums exist and get the parent album ID
    local parentAlbumId = ensureAncestorAlbums(publishSettings, info.parents)

    -- Create the album for this collection set
    local albumId, err = LycheeAPI.createAlbum(publishSettings, info.name, parentAlbumId)
    if not albumId then
        LrDialogs.message('Album Creation Failed',
            'Could not create album for collection set "' .. info.name .. '": ' .. (err or 'Unknown error'),
            'warning')
        return
    end

    logger:info('Created album for collection set "' .. info.name .. '": ' .. albumId)

    -- Store the album ID on the collection set
    storeRemoteAlbum(info.publishedCollectionSet, albumId, publishSettings,
        'collection set "' .. info.name .. '"')

    -- Apply pending settings if the user configured them during creation
    local pendingSet = getPendingSettings(info.name)
    if pendingSet then
        logger:info('Applying pending collection settings for set "' .. info.name .. '"')
        saveAlbumSettingsToLychee(publishSettings, albumId, info.name, pendingSet)
        clearPendingSettings(info.name)
    end
end

-- Called when a Published Collection Set is being deleted
function publishServiceProvider.deletePublishedCollectionSet(publishSettings, info)
    if not validateSettings(publishSettings) then
        return
    end

    local albumId = info.remoteId

    if albumId and albumId ~= '' then
        -- Warn the user about cascading delete
        local result = LrDialogs.confirm(
            'Delete Album from Lychee?',
            'Deleting this collection set will also delete the album "' .. (info.name or '') ..
            '" and ALL its sub-albums and photos from your Lychee gallery. This cannot be undone.',
            'Delete',
            'Cancel'
        )

        if result == 'cancel' then
            LrErrors.throwCanceled()
        end

        local success, err = LycheeAPI.deleteAlbum(publishSettings, albumId)
        if not success then
            LrDialogs.message('Delete Failed',
                err or 'Could not delete album from Lychee gallery.',
                'critical')
        else
            logger:info('Deleted album for collection set "' .. (info.name or '') .. '": ' .. albumId)
        end
    end
end

-- Called when a Published Collection Set is being renamed
function publishServiceProvider.renamePublishedCollectionSet(publishSettings, info)
    local newName = info.name

    if not validateSettings(publishSettings) then
        return
    end

    local albumId = info.remoteId

    if albumId then
        local success, err = LycheeAPI.renameAlbum(publishSettings, albumId, newName)
        if not success then
            LrDialogs.message('Rename Failed', err or 'Could not rename album in Lychee gallery.', 'warning')
        end
    end
end

-- Called when user tries to edit a published photo
function publishServiceProvider.shouldReverseSequenceForPublishedCollection(publishSettings, collectionInfo)
    return false
end

-- Metadata that can be updated on republish
function publishServiceProvider.metadataThatTriggersRepublish(publishSettings)
    return {
        default = false,
        title = true,
        caption = true,
        keywords = true,
    }
end

-- Indicate we can add comments (for future use)
publishServiceProvider.supportsCustomSortOrder = false

-- Get the URL for a published collection
function publishServiceProvider.getCollectionUrl(publishSettings, publishedCollectionInfo)
    if not publishSettings.gallery_url or publishSettings.gallery_url == '' then
        return nil
    end

    local remoteId = publishedCollectionInfo.remoteId
    if remoteId and remoteId ~= '' then
        return publishSettings.gallery_url .. '/gallery/' .. remoteId
    end

    -- No remoteId yet — return gallery root rather than nil (avoids error dialog)
    return publishSettings.gallery_url
end

--------------------------------------------------------------------------------
-- Album Settings (shown in Edit Published Collection / Collection Set dialog)
--------------------------------------------------------------------------------

-- Build header popup items from a photo list
local function buildHeaderItems(photos)
    local items = {
        { title = '— Default', value = '' },
        { title = 'Use compact header', value = 'compact' },
    }
    if photos then
        for _, photo in ipairs(photos) do
            if photo.id then
                local label = photo.title or photo.id
                items[#items + 1] = { title = label, value = photo.id }
            end
        end
    end
    return items
end

-- Popup items for album settings dropdowns
local LICENSE_ITEMS = {
    { title = 'None', value = 'none' },
    { title = 'All Rights Reserved', value = 'reserved' },
    { title = 'CC0 - Public Domain', value = 'CC0' },
    { title = 'CC Attribution 4.0', value = 'CC-BY-4.0' },
    { title = 'CC Attribution-ShareAlike 4.0', value = 'CC-BY-SA-4.0' },
    { title = 'CC Attribution-NoDerivs 4.0', value = 'CC-BY-ND-4.0' },
    { title = 'CC Attribution-NonCommercial 4.0', value = 'CC-BY-NC-4.0' },
    { title = 'CC Attribution-NonCommercial-ShareAlike 4.0', value = 'CC-BY-NC-SA-4.0' },
    { title = 'CC Attribution-NonCommercial-NoDerivs 4.0', value = 'CC-BY-NC-ND-4.0' },
}

local PHOTO_SORT_COLUMN_ITEMS = {
    { title = '—', value = '' },
    { title = 'Created at', value = 'created_at' },
    { title = 'Taken at', value = 'taken_at' },
    { title = 'Title', value = 'title' },
    { title = 'Description', value = 'description' },
    { title = 'Starred', value = 'is_starred' },
    { title = 'Type', value = 'type' },
}

local ALBUM_SORT_COLUMN_ITEMS = {
    { title = '—', value = '' },
    { title = 'Created at', value = 'created_at' },
    { title = 'Title', value = 'title' },
    { title = 'Description', value = 'description' },
    { title = 'Min taken at', value = 'min_taken_at' },
    { title = 'Max taken at', value = 'max_taken_at' },
}

local SORT_ORDER_ITEMS = {
    { title = '—', value = '' },
    { title = 'Ascending', value = 'ASC' },
    { title = 'Descending', value = 'DESC' },
}

local ASPECT_RATIO_ITEMS = {
    { title = '—', value = '' },
    { title = '1:1', value = '1/1' },
    { title = '5:4', value = '5/4' },
    { title = '3:2', value = '3/2' },
    { title = '2:3', value = '2/3' },
    { title = '4:5', value = '4/5' },
    { title = '16:9', value = '16/9' },
}

local PHOTO_LAYOUT_ITEMS = {
    { title = '—', value = '' },
    { title = 'Square', value = 'square' },
    { title = 'Justified', value = 'justified' },
    { title = 'Masonry', value = 'masonry' },
    { title = 'Grid', value = 'grid' },
}

local TIMELINE_ITEMS = {
    { title = '—', value = '' },
    { title = 'Default', value = 'default' },
    { title = 'Disabled', value = 'disabled' },
    { title = 'Year', value = 'year' },
    { title = 'Month', value = 'month' },
    { title = 'Day', value = 'day' },
}

local PHOTO_TIMELINE_ITEMS = {
    { title = '—', value = '' },
    { title = 'Default', value = 'default' },
    { title = 'Disabled', value = 'disabled' },
    { title = 'Year', value = 'year' },
    { title = 'Month', value = 'month' },
    { title = 'Day', value = 'day' },
    { title = 'Hour', value = 'hour' },
}

-- Helper: convert nil / JSON null to empty string for popup bindings
local function toVal(v)
    if v == nil or v == '' then return '' end
    return tostring(v)
end

-- Helper: set default values on collectionSettings for all album properties.
-- These are the values used when creating a new collection (no remote album yet).
local function initCollectionSettingsDefaults(collectionSettings)
    if collectionSettings.description == nil then collectionSettings.description = '' end
    if collectionSettings.license == nil then collectionSettings.license = 'none' end
    if collectionSettings.copyright == nil then collectionSettings.copyright = '' end
    if collectionSettings.photo_sorting_column == nil then collectionSettings.photo_sorting_column = '' end
    if collectionSettings.photo_sorting_order == nil then collectionSettings.photo_sorting_order = '' end
    if collectionSettings.album_sorting_column == nil then collectionSettings.album_sorting_column = '' end
    if collectionSettings.album_sorting_order == nil then collectionSettings.album_sorting_order = '' end
    if collectionSettings.album_aspect_ratio == nil then collectionSettings.album_aspect_ratio = '' end
    if collectionSettings.photo_layout == nil then collectionSettings.photo_layout = '' end
    if collectionSettings.album_timeline == nil then collectionSettings.album_timeline = '' end
    if collectionSettings.photo_timeline == nil then collectionSettings.photo_timeline = '' end
    if collectionSettings.is_public == nil then collectionSettings.is_public = false end
    if collectionSettings.is_link_required == nil then collectionSettings.is_link_required = false end
    if collectionSettings.is_nsfw == nil then collectionSettings.is_nsfw = false end
    if collectionSettings.grants_full_photo_access == nil then collectionSettings.grants_full_photo_access = false end
    if collectionSettings.grants_download == nil then collectionSettings.grants_download = false end
    if collectionSettings.is_password_required == nil then collectionSettings.is_password_required = false end
    if collectionSettings.password == nil then collectionSettings.password = '' end
    if collectionSettings.header_id == nil then collectionSettings.header_id = '' end
    if collectionSettings.header_items == nil then collectionSettings.header_items = buildHeaderItems(nil) end
    if collectionSettings.lychee_loaded == nil then collectionSettings.lychee_loaded = false end
end

-- Build the album settings view (shared between collections and collection sets)
local function buildAlbumSettingsView(f, collectionSettings)
    local bind = LrView.bind

    return f:column {
        spacing = f:control_spacing(),
        fill_horizontal = 1,
        bind_to_object = collectionSettings,

        -- Album Properties
        f:group_box {
            title = 'Lychee Album Settings',
            fill_horizontal = 1,

            f:column {
                spacing = f:control_spacing(),
                fill_horizontal = 1,

                f:static_text {
                    title = 'Description',
                },
                f:edit_field {
                    value = bind 'description',
                    fill_horizontal = 1,
                    height_in_lines = 3,
                    immediate = true,
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'Order photos by',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:popup_menu {
                        value = bind 'photo_sorting_column',
                        items = PHOTO_SORT_COLUMN_ITEMS,
                        width = 140,
                    },
                    f:popup_menu {
                        value = bind 'photo_sorting_order',
                        items = SORT_ORDER_ITEMS,
                        width = 100,
                    },
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'Order albums by',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:popup_menu {
                        value = bind 'album_sorting_column',
                        items = ALBUM_SORT_COLUMN_ITEMS,
                        width = 140,
                    },
                    f:popup_menu {
                        value = bind 'album_sorting_order',
                        items = SORT_ORDER_ITEMS,
                        width = 100,
                    },
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'License',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:popup_menu {
                        value = bind 'license',
                        items = LICENSE_ITEMS,
                        width = 250,
                    },
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'Copyright',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:edit_field {
                        value = bind 'copyright',
                        fill_horizontal = 1,
                        immediate = true,
                    },
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'Thumbs aspect ratio',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:popup_menu {
                        value = bind 'album_aspect_ratio',
                        items = ASPECT_RATIO_ITEMS,
                        width = 100,
                    },
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'Photo layout',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:popup_menu {
                        value = bind 'photo_layout',
                        items = PHOTO_LAYOUT_ITEMS,
                        width = 120,
                    },
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'Album timeline',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:popup_menu {
                        value = bind 'album_timeline',
                        items = TIMELINE_ITEMS,
                        width = 120,
                    },

                    f:static_text {
                        title = 'Photo timeline',
                    },
                    f:popup_menu {
                        value = bind 'photo_timeline',
                        items = PHOTO_TIMELINE_ITEMS,
                        width = 120,
                    },
                },

                f:row {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'Header',
                        alignment = 'right',
                        width = LrView.share 'lychee_label_width',
                    },
                    f:popup_menu {
                        value = bind 'header_id',
                        items = bind 'header_items',
                        width = 250,
                    },
                },
            },
        },

        -- Visibility & Access
        f:group_box {
            title = 'Visibility & Access',
            fill_horizontal = 1,

            f:column {
                spacing = f:control_spacing(),
                fill_horizontal = 1,

                f:row {
                    f:checkbox {
                        title = 'Public',
                        value = bind 'is_public',
                    },
                    f:static_text {
                        title = '— Anonymous users can access this album',
                        text_color = LrColor(0.6, 0.6, 0.6),
                    },
                },

                -- Sub-options disabled when Public is off
                f:column {
                    margin_left = 20,
                    spacing = f:control_spacing(),
                    fill_horizontal = 1,

                    f:checkbox {
                        title = 'Original — View full-resolution photos',
                        value = bind 'grants_full_photo_access',
                        enabled = bind 'is_public',
                    },
                    f:checkbox {
                        title = 'Hidden — Requires a direct link to access',
                        value = bind 'is_link_required',
                        enabled = bind 'is_public',
                    },
                    f:checkbox {
                        title = 'Downloadable — Allow anonymous downloads',
                        value = bind 'grants_download',
                        enabled = bind 'is_public',
                    },
                    f:checkbox {
                        title = 'Password protected',
                        value = bind 'is_password_required',
                        enabled = bind 'is_public',
                    },

                    f:row {
                        margin_left = 20,
                        spacing = f:label_spacing(),

                        f:static_text {
                            title = 'Password',
                            enabled = bind 'is_password_required',
                        },
                        f:edit_field {
                            value = bind 'password',
                            width = 200,
                            immediate = true,
                            enabled = bind 'is_password_required',
                        },
                    },
                },

                f:separator { fill_horizontal = 1 },

                f:row {
                    f:checkbox {
                        title = 'Sensitive',
                        value = bind 'is_nsfw',
                    },
                    f:static_text {
                        title = '— Album contains sensitive content',
                        text_color = LrColor(0.6, 0.6, 0.6),
                    },
                },
            },
        },
    }
end

-- Helper: push album settings and protection policy to Lychee.
-- Called from updateCollectionSettings / updateCollectionSetSettings / processRenderedPhotos.
saveAlbumSettingsToLychee = function(publishSettings, remoteId, collectionName, collectionSettings)
    logger:info('saveAlbumSettingsToLychee called, remoteId=' .. tostring(remoteId) .. ', name=' .. tostring(collectionName))
    if not remoteId or remoteId == '' then
        logger:info('No remote album ID — skipping settings push (will apply on first publish)')
        return
    end

    -- Fetch current album state to preserve is_pinned (not exposed in our UI)
    local albumData, fetchErr = LycheeAPI.getAlbumDetails(publishSettings, remoteId)
    local editable = {}
    if albumData and albumData.resource then
        editable = albumData.resource.editable or {}
    end

    -- Derive header fields from collectionSettings.header_id
    local headerVal = collectionSettings.header_id or ''
    local isCompact = headerVal == 'compact'
    local headerPhotoId = (headerVal ~= '' and headerVal ~= 'compact') and headerVal or nil

    -- Save album properties
    local settingsData = {
        title = collectionName or '',
        description = collectionSettings.description ~= '' and collectionSettings.description or nil,
        license = collectionSettings.license or 'none',
        copyright = collectionSettings.copyright ~= '' and collectionSettings.copyright or nil,
        photo_sorting_column = collectionSettings.photo_sorting_column ~= '' and collectionSettings.photo_sorting_column or nil,
        photo_sorting_order = collectionSettings.photo_sorting_order ~= '' and collectionSettings.photo_sorting_order or nil,
        album_sorting_column = collectionSettings.album_sorting_column ~= '' and collectionSettings.album_sorting_column or nil,
        album_sorting_order = collectionSettings.album_sorting_order ~= '' and collectionSettings.album_sorting_order or nil,
        album_aspect_ratio = collectionSettings.album_aspect_ratio ~= '' and collectionSettings.album_aspect_ratio or nil,
        photo_layout = collectionSettings.photo_layout ~= '' and collectionSettings.photo_layout or nil,
        album_timeline = collectionSettings.album_timeline ~= '' and collectionSettings.album_timeline or nil,
        photo_timeline = collectionSettings.photo_timeline ~= '' and collectionSettings.photo_timeline or nil,
        is_compact = isCompact,
        is_pinned = editable.is_pinned or false,
        header_id = headerPhotoId,
    }

    local ok, err = LycheeAPI.updateAlbumSettings(publishSettings, remoteId, settingsData)
    if not ok then
        LrDialogs.message('Error', 'Failed to save album settings: ' .. (err or 'Unknown error'), 'critical')
        return
    end

    -- Save protection policy
    local policyUpdate = {
        is_public = collectionSettings.is_public == true,
        is_link_required = collectionSettings.is_link_required == true,
        is_nsfw = collectionSettings.is_nsfw == true,
        grants_full_photo_access = collectionSettings.grants_full_photo_access == true,
        grants_download = collectionSettings.grants_download == true,
        grants_upload = false, -- not exposed in UI, default to false
    }

    -- Only send password if user typed one
    if collectionSettings.is_password_required and collectionSettings.password ~= '' then
        policyUpdate.password = collectionSettings.password
    end

    local pOk, pErr = LycheeAPI.updateProtectionPolicy(publishSettings, remoteId, policyUpdate)
    if not pOk then
        LrDialogs.message('Error',
            'Album properties saved, but failed to update visibility settings: '
            .. (pErr or 'Unknown error'), 'critical')
    end
end

-- Helper: get the remote album ID for a published collection/set.
-- Tries getRemoteId() first, falls back to searching Lychee by name.
-- Must be called from within an async task context.
local function resolveRemoteId(publishedCollection, publishSettings, collectionName)
    -- Try getRemoteId() from catalog
    if publishedCollection then
        local remoteId = nil
        local catalog = LrApplication.activeCatalog()
        catalog:withReadAccessDo(function()
            remoteId = publishedCollection:getRemoteId()
        end)

        if remoteId and remoteId ~= '' then
            logger:info('Got remoteId from catalog: ' .. tostring(remoteId))
            return remoteId
        end
    end

    -- Fallback: search Lychee by album name
    if collectionName and collectionName ~= '' then
        logger:info('remoteId not in catalog, searching Lychee for album "' .. collectionName .. '"')
        local album, findErr = LycheeAPI.findAlbumByTitle(publishSettings, collectionName)
        if album and album.id then
            local albumId = album.id
            logger:info('Found album by title: ' .. albumId)
            -- Also fix the catalog so future lookups work
            storeRemoteAlbum(publishedCollection, albumId, publishSettings,
                'collection "' .. tostring(collectionName) .. '" (recovered by title)')
            return albumId
        else
            logger:info('Could not find album by title: ' .. (findErr or 'not found'))
        end
    end

    logger:info('No remote album ID found for collection')
    return nil
end

-- SDK callback: build custom UI for the Create/Edit Published Collection dialog
function publishServiceProvider.viewForCollectionSettings(f, publishSettings, info)
    local collectionSettings = assert(info.collectionSettings)
    initCollectionSettingsDefaults(collectionSettings)

    -- Fetch from server inside an async task (where yielding is allowed)
    local publishedCollection = info.publishedCollection
    local collectionName = info.name
    if publishedCollection then
        LrTasks.startAsyncTask(function()
            local remoteId = resolveRemoteId(publishedCollection, publishSettings, collectionName)
            if remoteId then
                logger:info('Fetching album settings for ' .. remoteId)
                local albumData, fetchErr = LycheeAPI.getAlbumDetails(publishSettings, remoteId)
                if not albumData then
                    logger:warn('Could not load album settings: ' .. (fetchErr or 'Unknown error'))
                    return
                end

                local resource = albumData.resource
                if not resource then
                    logger:warn('Album::head returned no resource for ' .. tostring(remoteId))
                    return
                end
                local policy = resource.policy or {}
                local editable = resource.editable or {}
                local photoSorting = editable.photo_sorting or {}
                local albumSorting = editable.album_sorting or {}

                -- Fetch photos separately (Album::head doesn't include them)
                local albumPhotos = LycheeAPI.getAlbumPhotos(publishSettings, remoteId)
                local photos = (albumPhotos and albumPhotos.photos) or {}
                collectionSettings.header_items = buildHeaderItems(photos)
                logger:info('Loaded ' .. #photos .. ' photos for header selection')

                collectionSettings.description = resource.description or ''
                collectionSettings.copyright = resource.copyright or ''

                local rawLicense = toVal(editable.license)
                collectionSettings.license = rawLicense ~= '' and rawLicense or 'none'

                collectionSettings.photo_sorting_column = toVal(photoSorting.column)
                collectionSettings.photo_sorting_order = toVal(photoSorting.order)
                collectionSettings.album_sorting_column = toVal(albumSorting.column)
                collectionSettings.album_sorting_order = toVal(albumSorting.order)

                collectionSettings.album_aspect_ratio = toVal(editable.aspect_ratio)
                collectionSettings.photo_layout = toVal(editable.photo_layout)
                collectionSettings.album_timeline = toVal(editable.album_timeline)
                collectionSettings.photo_timeline = toVal(editable.photo_timeline)

                -- Header: editable.header_id is 'compact', a photo ID, or nil
                local hid = editable.header_id
                if hid == 'compact' then
                    collectionSettings.header_id = 'compact'
                elseif hid and hid ~= '' then
                    collectionSettings.header_id = hid
                else
                    collectionSettings.header_id = ''
                end

                collectionSettings.is_public = policy.is_public == true
                collectionSettings.is_link_required = policy.is_link_required == true
                collectionSettings.is_nsfw = policy.is_nsfw == true
                collectionSettings.grants_full_photo_access = policy.grants_full_photo_access == true
                collectionSettings.grants_download = policy.grants_download == true
                collectionSettings.is_password_required = policy.is_password_required == true
                collectionSettings.password = ''

                logger:info('Album settings loaded for ' .. remoteId)
            end
        end)
    end

    return buildAlbumSettingsView(f, collectionSettings)
end

-- SDK callback: save collection settings to Lychee when user clicks OK
function publishServiceProvider.updateCollectionSettings(publishSettings, info)
    local collectionSettings = assert(info.collectionSettings)
    local name = info.name
    local publishedCollection = info.publishedCollection

    -- Store settings in LrPrefs immediately so processRenderedPhotos can find them even though
    -- each LR callback runs in a separate Lua state (module-level tables reset between calls).
    storePendingSettings(name, {
        description = collectionSettings.description,
        license = collectionSettings.license,
        copyright = collectionSettings.copyright,
        photo_sorting_column = collectionSettings.photo_sorting_column,
        photo_sorting_order = collectionSettings.photo_sorting_order,
        album_sorting_column = collectionSettings.album_sorting_column,
        album_sorting_order = collectionSettings.album_sorting_order,
        album_aspect_ratio = collectionSettings.album_aspect_ratio,
        photo_layout = collectionSettings.photo_layout,
        album_timeline = collectionSettings.album_timeline,
        photo_timeline = collectionSettings.photo_timeline,
        header_id = collectionSettings.header_id,
        is_public = collectionSettings.is_public,
        is_link_required = collectionSettings.is_link_required,
        is_nsfw = collectionSettings.is_nsfw,
        grants_full_photo_access = collectionSettings.grants_full_photo_access,
        grants_download = collectionSettings.grants_download,
        is_password_required = collectionSettings.is_password_required,
        password = collectionSettings.password,
    })
    logger:info('Stored pending settings in prefs for "' .. name .. '"')

    LrTasks.startAsyncTask(function()
        local remoteId = info.remoteId
        if (not remoteId or remoteId == '') and publishedCollection then
            remoteId = resolveRemoteId(publishedCollection, publishSettings, name)
        end

        if remoteId and remoteId ~= '' then
            -- Album already exists — push settings now and clear the prefs entry.
            logger:info('Remote album found for "' .. name .. '" — applying settings immediately')
            clearPendingSettings(name)
            saveAlbumSettingsToLychee(publishSettings, remoteId, name, collectionSettings)
        end
        -- If no remoteId the album doesn't exist yet; the prefs entry stays for
        -- processRenderedPhotos to consume after it creates the album.
    end)
end

-- SDK callback: build custom UI for the Create/Edit Published Collection Set dialog
function publishServiceProvider.viewForCollectionSetSettings(f, publishSettings, info)
    local collectionSettings = assert(info.collectionSettings)
    initCollectionSettingsDefaults(collectionSettings)

    -- Fetch from server inside an async task (where yielding is allowed)
    local publishedCollection = info.publishedCollection
    local collectionName = info.name
    if publishedCollection then
        LrTasks.startAsyncTask(function()
            local remoteId = resolveRemoteId(publishedCollection, publishSettings, collectionName)
            if remoteId then
                logger:info('Fetching album settings for set ' .. remoteId)
                local albumData, fetchErr = LycheeAPI.getAlbumDetails(publishSettings, remoteId)
                if not albumData then
                    logger:warn('Could not load album settings: ' .. (fetchErr or 'Unknown error'))
                    return
                end

                local resource = albumData.resource
                if not resource then
                    logger:warn('Album::head returned no resource for ' .. tostring(remoteId))
                    return
                end
                local policy = resource.policy or {}
                local editable = resource.editable or {}
                local photoSorting = editable.photo_sorting or {}
                local albumSorting = editable.album_sorting or {}

                -- Fetch photos separately (Album::head doesn't include them)
                local albumPhotos = LycheeAPI.getAlbumPhotos(publishSettings, remoteId)
                local photos = (albumPhotos and albumPhotos.photos) or {}
                collectionSettings.header_items = buildHeaderItems(photos)

                collectionSettings.description = resource.description or ''
                collectionSettings.copyright = resource.copyright or ''

                local rawLicense = toVal(editable.license)
                collectionSettings.license = rawLicense ~= '' and rawLicense or 'none'

                collectionSettings.photo_sorting_column = toVal(photoSorting.column)
                collectionSettings.photo_sorting_order = toVal(photoSorting.order)
                collectionSettings.album_sorting_column = toVal(albumSorting.column)
                collectionSettings.album_sorting_order = toVal(albumSorting.order)

                collectionSettings.album_aspect_ratio = toVal(editable.aspect_ratio)
                collectionSettings.photo_layout = toVal(editable.photo_layout)
                collectionSettings.album_timeline = toVal(editable.album_timeline)
                collectionSettings.photo_timeline = toVal(editable.photo_timeline)

                local hid = editable.header_id
                if hid == 'compact' then
                    collectionSettings.header_id = 'compact'
                elseif hid and hid ~= '' then
                    collectionSettings.header_id = hid
                else
                    collectionSettings.header_id = ''
                end

                collectionSettings.is_public = policy.is_public == true
                collectionSettings.is_link_required = policy.is_link_required == true
                collectionSettings.is_nsfw = policy.is_nsfw == true
                collectionSettings.grants_full_photo_access = policy.grants_full_photo_access == true
                collectionSettings.grants_download = policy.grants_download == true
                collectionSettings.is_password_required = policy.is_password_required == true
                collectionSettings.password = ''

                logger:info('Album settings loaded for set ' .. remoteId)
            end
        end)
    end

    return buildAlbumSettingsView(f, collectionSettings)
end

-- SDK callback: save collection set settings to Lychee when user clicks OK
function publishServiceProvider.updateCollectionSetSettings(publishSettings, info)
    local collectionSettings = assert(info.collectionSettings)
    local name = info.name
    local publishedCollection = info.publishedCollection

    -- Store settings in LrPrefs immediately — same reasoning as updateCollectionSettings.
    storePendingSettings(name, {
        description = collectionSettings.description,
        license = collectionSettings.license,
        copyright = collectionSettings.copyright,
        photo_sorting_column = collectionSettings.photo_sorting_column,
        photo_sorting_order = collectionSettings.photo_sorting_order,
        album_sorting_column = collectionSettings.album_sorting_column,
        album_sorting_order = collectionSettings.album_sorting_order,
        album_aspect_ratio = collectionSettings.album_aspect_ratio,
        photo_layout = collectionSettings.photo_layout,
        album_timeline = collectionSettings.album_timeline,
        photo_timeline = collectionSettings.photo_timeline,
        header_id = collectionSettings.header_id,
        is_public = collectionSettings.is_public,
        is_link_required = collectionSettings.is_link_required,
        is_nsfw = collectionSettings.is_nsfw,
        grants_full_photo_access = collectionSettings.grants_full_photo_access,
        grants_download = collectionSettings.grants_download,
        is_password_required = collectionSettings.is_password_required,
        password = collectionSettings.password,
    })
    logger:info('Stored pending settings in prefs for set "' .. name .. '"')

    LrTasks.startAsyncTask(function()
        local remoteId = info.remoteId
        if (not remoteId or remoteId == '') and publishedCollection then
            remoteId = resolveRemoteId(publishedCollection, publishSettings, name)
        end

        if remoteId and remoteId ~= '' then
            -- Album already exists — push settings now and clear the prefs entry.
            logger:info('Remote album found for set "' .. name .. '" — applying settings immediately')
            clearPendingSettings(name)
            saveAlbumSettingsToLychee(publishSettings, remoteId, name, collectionSettings)
        end
        -- If no remoteId the album doesn't exist yet; the prefs entry stays for
        -- didCreateNewPublishedCollectionSet / processRenderedPhotos to consume.
    end)
end

-- Export file format settings
publishServiceProvider.allowFileFormats = { 'JPEG', 'PNG' }
publishServiceProvider.allowColorSpaces = { 'sRGB' }

publishServiceProvider.hideSections = {
    'exportLocation',
    'video',
}

publishServiceProvider.canExportVideo = false

-- Hide the watermark section by default
publishServiceProvider.showSections = {
    'fileNaming',
    'imageSettings',
    'outputSharpening',
    'metadata',
}

return publishServiceProvider
