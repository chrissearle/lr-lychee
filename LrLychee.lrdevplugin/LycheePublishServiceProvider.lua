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

local logger = LrLogger('LycheePlugin')
logger:enable('logfile')

local LycheeAPI = require 'LycheeAPI'

local publishServiceProvider = {}

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
    local albumId = publishedCollectionInfo.remoteId

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

    -- Store album ID on the published collection
    if publishedCollectionInfo.publishedCollection then
        publishedCollectionInfo.publishedCollection:setRemoteId(albumId)
        publishedCollectionInfo.publishedCollection:setRemoteUrl(
            publishSettings.gallery_url .. '/gallery/' .. albumId
        )
    end

    -- Get existing photo IDs and data in the album
    -- This is used to:
    -- 1. Avoid duplicate ID assignment when uploading multiple photos
    -- 2. Preserve existing metadata when updating (e.g., don't blank title if user only changed caption)
    local knownPhotoIds = {}
    local knownPhotoData = {}  -- Lookup table by photo ID
    local albumDetails = LycheeAPI.getAlbumDetails(publishSettings, albumId)
    if albumDetails and albumDetails.resource and albumDetails.resource.photos then
        for _, photo in ipairs(albumDetails.resource.photos) do
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
                local freshAlbumData = LycheeAPI.getAlbumDetails(publishSettings, albumId)
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
                        -- Still delete the old copy from the source album
                        if duplicateId ~= existingPhotoId then
                            local deleteOk, deleteErr = LycheeAPI.deletePhotos(publishSettings, { existingPhotoId })
                            if not deleteOk then
                                logger:warn('Could not delete old copy of ' .. existingPhotoId .. ': ' .. (deleteErr or 'unknown'))
                            end
                        end
                        rendition:recordPublishedPhotoId(duplicateId)
                        rendition:recordPublishedPhotoUrl(
                            publishSettings.gallery_url .. '/gallery/' .. albumId .. '/' .. duplicateId
                        )
                        updatePhotoMetadata(duplicateId)
                    else
                        -- Delete from old album (best effort - may fail if album was already deleted)
                        local deleteOk, deleteErr = LycheeAPI.deletePhotos(publishSettings, { existingPhotoId })
                        if not deleteOk then
                            logger:warn('Could not delete old copy of ' .. existingPhotoId .. ': ' .. (deleteErr or 'unknown'))
                        end

                        -- Upload to the current album
                        local uploadResult, uploadErr = LycheeAPI.uploadPhoto(publishSettings, photoPath, albumId, knownPhotoIds)

                        if uploadResult and uploadResult.id then
                            table.insert(knownPhotoIds, uploadResult.id)
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
                    -- Photo is in the current album - normal update flow
                    -- Check if this is just a metadata update or if the image was edited
                    local wasEdited = rendition.wasEditedSinceLastPublish

                    logger:info('Existing photo ID: ' .. tostring(existingPhotoId))
                    logger:info('Was edited since last publish: ' .. tostring(wasEdited))
                    logger:info('Title: ' .. tostring(title))
                    logger:info('Caption: ' .. tostring(caption))

                    if wasEdited then
                        -- Image was edited - delete old version and re-upload
                        -- Lychee will read title/description/tags from EXIF on upload
                        progressScope:setCaption(string.format('Re-uploading %s...', photoName))

                        local deleteSuccess, deleteErr = LycheeAPI.deletePhotos(publishSettings, { existingPhotoId })
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
            deletedCallback(photoId)
        end
    else
        LrDialogs.message('Delete Failed', deleteErr or 'Could not delete photos from Lychee gallery.', 'critical')
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
    info.publishedCollectionSet:setRemoteId(albumId)
    info.publishedCollectionSet:setRemoteUrl(
        publishSettings.gallery_url .. '/gallery/' .. albumId
    )
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

    return nil
end

-- Export file format settings
publishServiceProvider.allowFileFormats = { 'JPEG', 'PNG' }
publishServiceProvider.allowColorSpaces = { 'sRGB' }

publishServiceProvider.hideSections = {
    'exportLocation',
    'fileNaming',
    'video',
}

publishServiceProvider.canExportVideo = false

-- Hide the watermark section by default
publishServiceProvider.showSections = {
    'imageSettings',
    'outputSharpening',
    'metadata',
}

return publishServiceProvider
