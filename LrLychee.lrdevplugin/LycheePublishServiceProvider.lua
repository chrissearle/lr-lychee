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
    }
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

    -- Find or create album for this collection
    progressScope:setCaption('Finding or creating album...')
    local album, albumErr = LycheeAPI.findOrCreateAlbum(publishSettings, collectionName)
    if not album then
        LrDialogs.message('Album Error', albumErr or 'Could not find or create album.', 'critical')
        return
    end

    local albumId = album.id
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
            else
                -- New photo - upload it
                -- Lychee will read title/description/tags from EXIF on upload
                progressScope:setCaption(string.format('Uploading %s...', photoName))

                local uploadResult, uploadErr = LycheeAPI.uploadPhoto(publishSettings, photoPath, albumId, knownPhotoIds)

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
