--[[----------------------------------------------------------------------------
LycheeAPI.lua - HTTP client for Lychee Gallery API

Handles album management and photo upload/deletion using Bearer token authentication.
------------------------------------------------------------------------------]]

local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrLogger = import 'LrLogger'
local LrTasks = import 'LrTasks'

local logger = LrLogger('LycheePlugin')
logger:enable('logfile')

local LycheeAPI = {}

-- Special marker for JSON null (since Lua nil can't be stored in tables)
local JSON_NULL = {}

-- JSON encoding/decoding utilities
local function jsonEncode(tbl)
    -- Handle JSON_NULL marker
    if tbl == JSON_NULL then
        return 'null'
    end

    if type(tbl) ~= 'table' then
        if type(tbl) == 'string' then
            return '"' .. tbl:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
        elseif type(tbl) == 'number' or type(tbl) == 'boolean' then
            return tostring(tbl)
        elseif tbl == nil then
            return 'null'
        end
        return '""'
    end

    local isArray = #tbl > 0
    local parts = {}

    if isArray then
        for _, v in ipairs(tbl) do
            table.insert(parts, jsonEncode(v))
        end
        return '[' .. table.concat(parts, ',') .. ']'
    else
        for k, v in pairs(tbl) do
            table.insert(parts, '"' .. tostring(k) .. '":' .. jsonEncode(v))
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
end

local function jsonDecode(str)
    if not str or str == '' then
        return nil
    end
    -- Simple JSON decoder for API responses
    local pos = 1
    local function skipWhitespace()
        while pos <= #str and str:sub(pos, pos):match('%s') do
            pos = pos + 1
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1 -- skip opening quote
        local result = ''
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return result
            elseif c == '\\' then
                pos = pos + 1
                local escaped = str:sub(pos, pos)
                if escaped == 'n' then result = result .. '\n'
                elseif escaped == 'r' then result = result .. '\r'
                elseif escaped == 't' then result = result .. '\t'
                elseif escaped == '\\' then result = result .. '\\'
                elseif escaped == '"' then result = result .. '"'
                elseif escaped == '/' then result = result .. '/'
                else result = result .. escaped
                end
                pos = pos + 1
            else
                result = result .. c
                pos = pos + 1
            end
        end
        return result
    end

    local function parseNumber()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match('[0-9]') do pos = pos + 1 end
        if pos <= #str and str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= #str and str:sub(pos, pos):match('[0-9]') do pos = pos + 1 end
        end
        if pos <= #str and str:sub(pos, pos):lower() == 'e' then
            pos = pos + 1
            if str:sub(pos, pos):match('[+-]') then pos = pos + 1 end
            while pos <= #str and str:sub(pos, pos):match('[0-9]') do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parseObject()
        local obj = {}
        pos = pos + 1 -- skip {
        skipWhitespace()
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while true do
            skipWhitespace()
            if str:sub(pos, pos) ~= '"' then break end
            local key = parseString()
            skipWhitespace()
            pos = pos + 1 -- skip :
            skipWhitespace()
            obj[key] = parseValue()
            skipWhitespace()
            if str:sub(pos, pos) == '}' then
                pos = pos + 1
                break
            end
            pos = pos + 1 -- skip ,
        end
        return obj
    end

    local function parseArray()
        local arr = {}
        pos = pos + 1 -- skip [
        skipWhitespace()
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        while true do
            skipWhitespace()
            table.insert(arr, parseValue())
            skipWhitespace()
            if str:sub(pos, pos) == ']' then
                pos = pos + 1
                break
            end
            pos = pos + 1 -- skip ,
        end
        return arr
    end

    parseValue = function()
        skipWhitespace()
        local c = str:sub(pos, pos)
        if c == '"' then return parseString()
        elseif c == '{' then return parseObject()
        elseif c == '[' then return parseArray()
        elseif c == 't' then pos = pos + 4; return true
        elseif c == 'f' then pos = pos + 5; return false
        elseif c == 'n' then pos = pos + 4; return nil
        elseif c == '-' or c:match('[0-9]') then return parseNumber()
        end
        return nil
    end

    return parseValue()
end

-- Build the API base URL from settings
local function getBaseUrl(settings)
    local url = settings.gallery_url or ''
    -- Remove trailing slash
    url = url:gsub('/$', '')
    return url .. '/api/v2'
end

-- Build headers for API requests with Bearer token authentication
-- Set skipContentType=true for multipart uploads (postMultipart sets it automatically)
local function buildHeaders(settings, skipContentType)
    local headers = {
        { field = 'Accept', value = 'application/json' },
        { field = 'Authorization', value = 'Bearer ' .. (settings.api_token or '') },
    }
    if not skipContentType then
        table.insert(headers, { field = 'Content-Type', value = 'application/json' })
    end
    return headers
end

-- Test connection with API token
function LycheeAPI.testConnection(settings)
    local url = getBaseUrl(settings) .. '/Albums'
    local headers = buildHeaders(settings)

    local result, respHeaders = LrHttp.get(url, headers, 30)

    if not result then
        return false, 'Connection failed'
    end

    local response = jsonDecode(result)

    -- Check for error response
    if type(response) == 'table' and response.exception then
        return false, response.message or 'Authentication failed'
    end

    -- If we got a valid response (albums list), connection is successful
    if type(response) == 'table' then
        return true, 'Connection successful'
    end

    return false, 'Invalid response from server'
end

-- Get all albums
function LycheeAPI.getAlbums(settings)
    local url = getBaseUrl(settings) .. '/Albums'
    local headers = buildHeaders(settings)

    local result, respHeaders = LrHttp.get(url, headers, 30)

    if not result then
        return nil, 'Failed to fetch albums'
    end

    local response = jsonDecode(result)
    if not response then
        return nil, 'Invalid response from server: ' .. tostring(result)
    end

    -- Check for errors
    if type(response) == 'table' and response.exception then
        return nil, response.message or response.exception
    end

    return response, nil
end

-- Get a specific album by ID
function LycheeAPI.getAlbum(settings, albumId)
    local url = getBaseUrl(settings) .. '/Album?album_id=' .. albumId
    local headers = buildHeaders(settings)

    local result, respHeaders = LrHttp.get(url, headers, 30)

    if not result then
        return nil, 'Failed to fetch album'
    end

    local response = jsonDecode(result)
    if not response then
        return nil, 'Invalid response from server'
    end

    return response, nil
end

-- Find album by title (searches in all album collections)
function LycheeAPI.findAlbumByTitle(settings, title)
    local albums, err = LycheeAPI.getAlbums(settings)
    if not albums then
        return nil, err
    end

    -- Search through album structure
    local function searchAlbums(albumList)
        if not albumList then return nil end
        for _, album in ipairs(albumList) do
            if album.title == title then
                return album
            end
            -- Check children if present
            if album.albums then
                local found = searchAlbums(album.albums)
                if found then return found end
            end
        end
        return nil
    end

    -- Albums response has different sections: albums, smart_albums, tag_albums, etc.
    if albums.albums then
        local found = searchAlbums(albums.albums)
        if found then return found, nil end
    end

    -- Also check smart_albums and shared_albums
    if albums.smart_albums then
        local found = searchAlbums(albums.smart_albums)
        if found then return found, nil end
    end

    return nil, nil -- Not found, but no error
end

-- Create a new album
-- Returns the album ID as a string on success
function LycheeAPI.createAlbum(settings, title, parentId)
    local url = getBaseUrl(settings) .. '/Album'
    local headers = buildHeaders(settings)

    -- parent_id must be present - use empty string for root-level albums
    local bodyTable = {
        title = title,
        parent_id = parentId or '',
    }
    local body = jsonEncode(bodyTable)

    local result, respHeaders = LrHttp.post(url, body, headers, 30)

    if not result then
        return nil, 'Failed to create album'
    end

    -- Try to decode as JSON first
    local response = jsonDecode(result)

    -- Check if response is a table (error response)
    if type(response) == 'table' then
        if response.error or response.message then
            return nil, response.message or 'Failed to create album'
        end
        -- Might have an id field
        if response.id then
            return response.id, nil
        end
    end

    -- Response might be a JSON-encoded string: "albumId"
    if type(response) == 'string' and response ~= '' then
        return response, nil
    end

    -- API might return raw album ID without JSON encoding
    local trimmedResult = result:match('^%s*(.-)%s*$')  -- Trim whitespace
    if trimmedResult and trimmedResult:match('^[%w%-_]+$') then
        return trimmedResult, nil
    end

    return nil, 'Invalid response from server: ' .. tostring(result)
end

-- Find or create album by title
-- Returns album table with id and title fields
function LycheeAPI.findOrCreateAlbum(settings, title)
    -- First try to find existing album
    local album, err = LycheeAPI.findAlbumByTitle(settings, title)
    if err then
        return nil, err
    end

    if album and album.id then
        return album, nil
    end

    -- Create new album - returns just the album ID
    local albumId, createErr = LycheeAPI.createAlbum(settings, title, nil)
    if createErr then
        return nil, createErr
    end

    if not albumId then
        return nil, 'Failed to create album: no ID returned'
    end

    -- Return the created album with its ID
    return { id = albumId, title = title }, nil
end

-- Rename an album
function LycheeAPI.renameAlbum(settings, albumId, newTitle)
    local url = getBaseUrl(settings) .. '/Album'
    local headers = buildHeaders(settings)

    local body = jsonEncode({
        album_id = albumId,
        title = newTitle,
    })

    local result, respHeaders = LrHttp.post(url, body, headers, 'PATCH', 30)

    if not result then
        return false, 'Failed to rename album'
    end

    local response = jsonDecode(result)
    if type(response) == 'table' and (response.error or response.exception) then
        return false, response.message or 'Failed to rename album'
    end

    return true, nil
end

-- Get album details including photos
function LycheeAPI.getAlbumDetails(settings, albumId)
    local url = getBaseUrl(settings) .. '/Album?album_id=' .. albumId
    local headers = buildHeaders(settings)

    local result, respHeaders = LrHttp.get(url, headers, 30)

    if not result then
        return nil, 'Failed to get album details'
    end

    local response = jsonDecode(result)
    if type(response) == 'table' and (response.error or response.exception) then
        return nil, response.message or 'Failed to get album'
    end

    return response, nil
end

-- Normalize filename for comparison (remove special chars, lowercase)
local function normalizeFilename(name)
    if not name then return '' end
    -- Remove extension
    local base = name:match('(.+)%.[^.]+$') or name
    -- Remove spaces, parentheses, underscores, dashes and lowercase
    return base:gsub('[%s%(%%)_%-]', ''):lower()
end

-- Find a photo in album by original filename
local function findPhotoByFilename(albumData, targetFilename)
    -- Album response has structure: { resource: { photos: [...] } }
    local resource = albumData.resource
    if not resource then
        logger:warn('No resource in album data')
        return nil
    end

    local photos = resource.photos
    if not photos then
        logger:warn('No photos in album resource')
        return nil
    end

    logger:info('Searching for: ' .. targetFilename)
    logger:info('Album has ' .. #photos .. ' photos')

    local normalizedTarget = normalizeFilename(targetFilename)

    for i, photo in ipairs(photos) do
        local photoName = photo.original_name or ''
        local photoTitle = photo.title or ''
        logger:info('Photo ' .. i .. ': id=' .. tostring(photo.id) .. ', original_name=' .. photoName .. ', title=' .. photoTitle)

        -- Check original_name or title against our filename
        local nameToCheck = photoName ~= '' and photoName or photoTitle

        -- Exact match first
        if nameToCheck == targetFilename then
            return photo.id
        end

        -- Try without extension
        local baseName = targetFilename:match('(.+)%.[^.]+$') or targetFilename
        local photoBaseName = nameToCheck:match('(.+)%.[^.]+$') or nameToCheck
        if photoBaseName == baseName then
            return photo.id
        end

        -- Try normalized comparison (handles spaces, parentheses, etc.)
        if normalizeFilename(nameToCheck) == normalizedTarget then
            return photo.id
        end
    end

    -- Do NOT use a fallback here - if we can't find the photo by filename,
    -- return nil so the caller can retry. Using a fallback when uploading
    -- multiple photos would assign the wrong ID to the wrong photo.

    return nil
end

-- Upload a photo to an album
-- Returns table with id field (photo ID) on success
-- knownPhotoIds is an optional table of photo IDs already in the album (to avoid returning duplicates)
function LycheeAPI.uploadPhoto(settings, filePath, albumId, knownPhotoIds)
    -- Validate albumId
    if not albumId or albumId == '' then
        return nil, 'No album ID provided'
    end

    local url = getBaseUrl(settings) .. '/Photo'
    local fileName = LrPathUtils.leafName(filePath)

    -- Ensure albumId is a string
    local albumIdStr = tostring(albumId)

    -- Build lookup table of known IDs
    local knownIds = {}
    if knownPhotoIds then
        for _, id in ipairs(knownPhotoIds) do
            knownIds[id] = true
        end
    end

    -- Build multipart form data
    -- For single-chunk uploads, uuid_name and extension must be present but empty
    local content = {
        { name = 'album_id', value = albumIdStr },
        { name = 'file_name', value = fileName },
        { name = 'uuid_name', value = '' },
        { name = 'extension', value = '' },
        { name = 'chunk_number', value = '1' },
        { name = 'total_chunks', value = '1' },
        { name = 'file', filePath = filePath, fileName = fileName, contentType = 'application/octet-stream' },
    }

    -- Skip Content-Type header - postMultipart sets it to multipart/form-data automatically
    local headers = buildHeaders(settings, true)

    local result, respHeaders = LrHttp.postMultipart(url, content, headers, 300)

    logger:info('Upload response (raw): ' .. tostring(result))

    if not result then
        return nil, 'Failed to upload photo'
    end

    local response = jsonDecode(result)

    logger:info('Upload response (decoded): ' .. jsonEncode(response or {}))

    -- Check for error response
    if type(response) == 'table' and (response.error or response.exception) then
        return nil, response.message or 'Failed to upload photo'
    end

    -- Check if response directly contains photo ID (24 chars)
    if type(response) == 'table' then
        local photoId = response.id or response.photo_id
        if photoId and photoId ~= '' and #photoId == 24 then
            logger:info('Found photo ID directly in response: ' .. photoId)
            return { id = photoId }, nil
        end

        -- UploadMetaResource means we need to fetch album to get real photo ID
        if response.uuid_name and response.stage == 'ready' then
            logger:info('Got UploadMetaResource with uuid_name: ' .. response.uuid_name .. ' - need to fetch album for real photo ID')
        end
    end

    -- Response might be a string photo ID (24 chars)
    if type(response) == 'string' and response ~= '' and #response == 24 then
        logger:info('Response is string photo ID: ' .. response)
        return { id = response }, nil
    end

    -- Upload succeeded but we need to find the photo ID by querying the album
    -- This happens when Lychee returns UploadMetaResource instead of the photo ID
    logger:info('Looking up photo in album, searching for filename: ' .. fileName)

    -- Retry album fetch with delays (Lychee needs time to process the upload)
    -- We track the photo count to detect when our new photo appears
    local albumData, albumErr
    local photoId
    local maxRetries = 10
    local initialPhotoCount = nil

    for attempt = 1, maxRetries do
        -- Wait before each attempt (including first) to give Lychee time to process
        if attempt == 1 then
            LrTasks.sleep(1) -- Short initial wait
        else
            logger:info('Retrying album fetch, attempt ' .. attempt .. ' after delay...')
            LrTasks.sleep(3) -- Longer wait between retries
        end

        albumData, albumErr = LycheeAPI.getAlbumDetails(settings, albumIdStr)
        if not albumData then
            logger:warn('Album fetch attempt ' .. attempt .. ' failed: ' .. (albumErr or 'unknown'))
        else
            -- Get current photo count
            local photos = albumData.resource and albumData.resource.photos or {}
            local currentCount = #photos
            logger:info('Album has ' .. currentCount .. ' photos (attempt ' .. attempt .. ')')

            -- Track initial count to detect new photos
            if initialPhotoCount == nil then
                initialPhotoCount = currentCount
            end

            -- First try to find by filename
            photoId = findPhotoByFilename(albumData, fileName)
            if photoId then
                logger:info('Found photo ID by filename: ' .. photoId)
                return { id = photoId }, nil
            end

            -- Look for a photo ID that we haven't seen before (not in knownIds)
            -- This handles the case where Lychee doesn't preserve the original filename
            local newPhotoId = nil
            local newPhotoTime = nil
            for _, photo in ipairs(photos) do
                if photo.id and not knownIds[photo.id] then
                    local createdAt = photo.created_at or ''
                    -- If multiple new photos, pick the one with the newest timestamp
                    if newPhotoId == nil or createdAt > (newPhotoTime or '') then
                        newPhotoId = photo.id
                        newPhotoTime = createdAt
                    end
                end
            end
            if newPhotoId then
                logger:info('Found new photo not in known IDs: ' .. newPhotoId)
                return { id = newPhotoId }, nil
            end

            logger:info('Photo not found in album yet, will retry...')
        end
    end

    if not albumData then
        return nil, 'Upload succeeded but could not get album to find photo ID: ' .. (albumErr or 'unknown')
    end

    logger:warn('Could not find photo in album after ' .. maxRetries .. ' attempts for: ' .. fileName)
    return nil, 'Upload succeeded but could not find photo ID in album for: ' .. fileName
end

-- Delete photos by IDs
-- API uses query parameters: photo_ids[]=id1&photo_ids[]=id2
function LycheeAPI.deletePhotos(settings, photoIds)
    if not photoIds or #photoIds == 0 then
        return true, nil
    end

    -- Build query string with photo_ids array
    local queryParts = {}
    for _, photoId in ipairs(photoIds) do
        table.insert(queryParts, 'photo_ids[]=' .. tostring(photoId))
    end
    local queryString = table.concat(queryParts, '&')

    local url = getBaseUrl(settings) .. '/Photo?' .. queryString
    local headers = buildHeaders(settings)

    -- Use LrHttp.post with DELETE method override
    local result, respHeaders = LrHttp.post(url, '', headers, 'DELETE', 30)

    if not result then
        return false, 'Failed to delete photos'
    end

    local response = jsonDecode(result)
    if type(response) == 'table' and response.error then
        return false, response.message or 'Failed to delete photos'
    end

    return true, nil
end

-- Update photo metadata using PATCH /Photo
-- Required fields: photo_id, title, description, license, upload_date, tags, from_id (album_id)
-- If title or description are nil in metadata, the existing values should be passed in
function LycheeAPI.updatePhoto(settings, photoId, albumId, metadata)
    local url = getBaseUrl(settings) .. '/Photo'
    local headers = buildHeaders(settings)

    -- Build body with required fields
    -- All fields are required by Lychee API
    local body = {
        photo_id = photoId,
        from_id = albumId,  -- Required by Lychee - the album ID (undocumented)
        title = metadata.title or '',
        description = metadata.description or '',  -- Required by Lychee, even if empty
        license = 'none',
        upload_date = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        tags = metadata.tags or {},
    }

    local jsonBody = jsonEncode(body)
    logger:info('Updating photo metadata: ' .. jsonBody)

    -- LrHttp.post(url, postBody, headers, method, timeout)
    local result, respHeaders = LrHttp.post(url, jsonBody, headers, 'PATCH', 30)

    logger:info('Update response: ' .. tostring(result))

    if not result then
        -- Check if we got any response headers for debugging
        local statusInfo = ''
        if respHeaders then
            for _, h in ipairs(respHeaders) do
                local field = h.field or h[1]
                local value = h.value or h[2]
                if field and field:lower() == 'status' then
                    statusInfo = ', status: ' .. tostring(value)
                    break
                end
            end
        end
        return nil, 'Failed to update photo (no response' .. statusInfo .. ')'
    end

    local response = jsonDecode(result)
    -- Check for various error response formats
    -- Lychee can return: {error: ...}, {exception: ...}, or {errors: {...}, message: ...}
    if type(response) == 'table' and (response.error or response.exception or response.errors) then
        return nil, 'Update failed: ' .. (response.message or response.exception or 'Unknown error')
    end

    return response or {}, nil
end

return LycheeAPI
