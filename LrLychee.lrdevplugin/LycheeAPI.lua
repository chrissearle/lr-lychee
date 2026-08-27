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

-- Encode a Unicode code point as UTF-8. Lightroom runs Lua 5.1, which has no utf8
-- library, so this is done by hand.
local function codepointToUtf8(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40),
                           0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + (math.floor(cp / 0x1000) % 0x40),
                           0x80 + (math.floor(cp / 0x40) % 0x40),
                           0x80 + (cp % 0x40))
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
                elseif escaped == 'u' then
                    -- \uXXXX - Lychee returns non-ASCII this way ("\u00a9" for ©).
                    -- Without this branch the backslash was dropped and the literal
                    -- "u00a9" kept, silently corrupting the value on every round trip.
                    local cp = tonumber(str:sub(pos + 1, pos + 4), 16)
                    pos = pos + 4
                    if cp then
                        -- Surrogate pair for code points above the BMP
                        if cp >= 0xD800 and cp <= 0xDBFF and str:sub(pos + 1, pos + 2) == '\\u' then
                            local lo = tonumber(str:sub(pos + 3, pos + 6), 16)
                            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                                cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                                pos = pos + 6
                            end
                        end
                        result = result .. codepointToUtf8(cp)
                    end
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

-- Find album by title scoped to a specific parent album
-- If parentId is nil, searches top-level albums only
-- Returns album table or nil
function LycheeAPI.findAlbumByTitleUnderParent(settings, title, parentId)
    if parentId then
        -- Fetch child albums using Album::albums endpoint (Lychee 7.5+, returns { data: [...] })
        local url = getBaseUrl(settings) .. '/Album::albums?album_id=' .. parentId
        local headers = buildHeaders(settings)
        local result = LrHttp.get(url, headers, 30)
        if not result then
            return nil, 'Failed to fetch child albums'
        end
        local albumsData = jsonDecode(result)
        if not albumsData then
            return nil, 'Invalid response fetching child albums'
        end
        if type(albumsData) == 'table' and (albumsData.error or albumsData.exception) then
            return nil, albumsData.message or 'Failed to fetch child albums'
        end

        local childAlbums = albumsData.data or {}
        for _, album in ipairs(childAlbums) do
            if album.title == title then
                return album, nil
            end
        end

        return nil, nil -- Not found under this parent
    else
        -- No parent - search top-level albums only (not recursively)
        local albums, err = LycheeAPI.getAlbums(settings)
        if not albums then
            return nil, err
        end

        if albums.albums then
            for _, album in ipairs(albums.albums) do
                if album.title == title then
                    return album, nil
                end
            end
        end

        return nil, nil
    end
end

-- Create a new album
-- Returns the album ID as a string on success
function LycheeAPI.createAlbum(settings, title, parentId)
    local url = getBaseUrl(settings) .. '/Album'
    local headers = buildHeaders(settings)

    -- parent_id must be present - use JSON null for root-level albums
    local bodyTable = {
        title = title,
        parent_id = parentId or JSON_NULL,
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

-- Find or create album by title, optionally scoped to a parent album
-- Returns album table with id and title fields
function LycheeAPI.findOrCreateAlbum(settings, title, parentId)
    -- First try to find existing album (scoped to parent if provided)
    local album, err = LycheeAPI.findAlbumByTitleUnderParent(settings, title, parentId)
    if err then
        return nil, err
    end

    if album and album.id then
        return album, nil
    end

    -- Create new album under the specified parent (or at root)
    local albumId, createErr = LycheeAPI.createAlbum(settings, title, parentId)
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

-- Move album(s) to a new parent album (or to root if newParentId is nil)
-- Uses POST /Album::move with { album_id: destination, album_ids: [sources] }
function LycheeAPI.moveAlbum(settings, albumId, newParentId)
    local url = getBaseUrl(settings) .. '/Album::move'
    local headers = buildHeaders(settings)

    local body = jsonEncode({
        album_id = newParentId or JSON_NULL,
        album_ids = { albumId },
    })

    local result, respHeaders = LrHttp.post(url, body, headers, 30)

    -- Lychee may return 204 No Content on success
    if result == nil and respHeaders then
        for _, h in ipairs(respHeaders) do
            local field = h.field or h[1]
            local value = h.value or h[2]
            if field and field:lower() == 'status' then
                local status = tonumber(tostring(value):match('%d+'))
                if status and status >= 200 and status < 300 then
                    return true, nil
                end
            end
        end
    end

    if result and result ~= '' then
        local response = jsonDecode(result)
        if type(response) == 'table' and (response.error or response.exception) then
            return false, response.message or 'Failed to move album'
        end
    end

    return true, nil
end

-- Move photos to a different album
-- Uses POST /Photo::move with { album_id: destination, photo_ids: [ids] }
function LycheeAPI.movePhotos(settings, photoIds, targetAlbumId)
    if not photoIds or #photoIds == 0 then
        return true, nil
    end

    local url = getBaseUrl(settings) .. '/Photo::move'
    local headers = buildHeaders(settings)

    local body = jsonEncode({
        album_id = targetAlbumId,
        photo_ids = photoIds,
    })

    local result, respHeaders = LrHttp.post(url, body, headers, 30)

    -- Lychee may return 204 No Content on success
    if result == nil and respHeaders then
        for _, h in ipairs(respHeaders) do
            local field = h.field or h[1]
            local value = h.value or h[2]
            if field and field:lower() == 'status' then
                local status = tonumber(tostring(value):match('%d+'))
                if status and status >= 200 and status < 300 then
                    return true, nil
                end
            end
        end
    end

    if result and result ~= '' then
        local response = jsonDecode(result)
        if type(response) == 'table' and (response.error or response.exception) then
            return false, response.message or 'Failed to move photos'
        end
    end

    return true, nil
end

-- Get the parent album ID for a given album
-- Returns parentId (string) or nil if album is at root
function LycheeAPI.getAlbumParentId(settings, albumId)
    local albumDetails, err = LycheeAPI.getAlbumDetails(settings, albumId)
    if not albumDetails then
        return nil, err
    end

    -- Album::head returns { config = {...}, resource = {...} }; parent_id is on
    -- the resource and is null for root-level albums.
    local resource = albumDetails.resource
    if not resource then
        return nil, 'Album::head returned no resource'
    end
    local parentId = resource.parent_id

    -- parent_id may be null/nil for root-level albums
    if parentId and parentId ~= '' then
        return parentId, nil
    end

    return nil, nil
end

-- Get album details (metadata and parent info) - uses Album::head endpoint (Lychee 7.5+)
function LycheeAPI.getAlbumDetails(settings, albumId)
    local url = getBaseUrl(settings) .. '/Album::head?album_id=' .. albumId
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

-- Get photos in an album (paginated) - uses Album::photos endpoint (Lychee 7.5+)
-- Returns { photos: [...], current_page, last_page, per_page, total } or nil, err
function LycheeAPI.getAlbumPhotos(settings, albumId, page)
    local url = getBaseUrl(settings) .. '/Album::photos?album_id=' .. albumId
    if page and page > 1 then
        url = url .. '&page=' .. page
    end
    local headers = buildHeaders(settings)

    local result, respHeaders = LrHttp.get(url, headers, 30)

    if not result then
        return nil, 'Failed to get album photos'
    end

    local response = jsonDecode(result)
    if type(response) == 'table' and (response.error or response.exception) then
        return nil, response.message or 'Failed to get album photos'
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
-- Also accessible as LycheeAPI.findPhotoByFilename for external use
-- albumData is the response from getAlbumPhotos: { photos: [...] }
local function findPhotoByFilename(albumData, targetFilename)
    local photos = albumData.photos
    if not photos then
        logger:warn('No photos in album data')
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

    -- Lychee 7.7+ returns the id it intends to give the photo as `expected_id`.
    -- It is optimistic, not a promise: the import runs on the queue worker, and if
    -- Lychee finds an existing photo with the same checksum it drops the upload and
    -- the expected_id is never used. So treat it as a candidate to confirm below
    -- rather than an answer, and keep the filename search as the fallback.
    local expectedId = nil
    if type(response) == 'table' and type(response.expected_id) == 'string'
        and #response.expected_id == 24 then
        expectedId = response.expected_id
        logger:info('Upload returned expected_id ' .. expectedId .. ' - will confirm in album')
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

        albumData, albumErr = LycheeAPI.getAlbumPhotos(settings, albumIdStr)
        if not albumData then
            logger:warn('Album fetch attempt ' .. attempt .. ' failed: ' .. (albumErr or 'unknown'))
        else
            -- Get current photo count
            local photos = albumData.photos or {}
            local currentCount = #photos
            logger:info('Album has ' .. currentCount .. ' photos (attempt ' .. attempt .. ')')

            -- Track initial count to detect new photos
            if initialPhotoCount == nil then
                initialPhotoCount = currentCount
            end

            -- Prefer the id Lychee told us to expect, once it actually shows up in
            -- the album. Matching on id avoids the filename guesswork entirely
            -- (photos come back with original_name null and the filename in title).
            if expectedId then
                for _, photo in ipairs(photos) do
                    if photo.id == expectedId then
                        logger:info('Confirmed expected_id in album: ' .. expectedId)
                        return { id = expectedId }, nil
                    end
                end
            end

            -- Otherwise try to find by filename
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

-- Delete an album by ID
-- Lychee cascades: all child albums and photos are also deleted
function LycheeAPI.deleteAlbum(settings, albumId)
    if not albumId or albumId == '' then
        return true, nil
    end

    local url = getBaseUrl(settings) .. '/Album'
    local headers = buildHeaders(settings)

    local body = jsonEncode({
        album_ids = { albumId },
    })

    -- Use LrHttp.post with DELETE method override
    local result, respHeaders = LrHttp.post(url, body, headers, 'DELETE', 30)

    -- Lychee returns 204 No Content on success (result may be empty)
    if result == nil and respHeaders then
        -- Check for successful status in headers
        for _, h in ipairs(respHeaders) do
            local field = h.field or h[1]
            local value = h.value or h[2]
            if field and field:lower() == 'status' then
                local status = tonumber(tostring(value):match('%d+'))
                if status and status >= 200 and status < 300 then
                    return true, nil
                end
            end
        end
    end

    if result and result ~= '' then
        local response = jsonDecode(result)
        if type(response) == 'table' and (response.error or response.exception) then
            return false, response.message or 'Failed to delete album'
        end
    end

    return true, nil
end

-- Delete photos by IDs
-- API uses query parameters: photo_ids[]=id1&photo_ids[]=id2
-- List the albums a photo belongs to - GET /Photo/{photo_id}/albums
-- Returns an array of { id, title } or nil, err
function LycheeAPI.getPhotoAlbums(settings, photoId)
    local url = getBaseUrl(settings) .. '/Photo/' .. tostring(photoId) .. '/albums'
    local headers = buildHeaders(settings)

    local result = LrHttp.get(url, headers, 30)
    if not result then
        return nil, 'Failed to get albums for photo'
    end

    local response = jsonDecode(result)
    if type(response) ~= 'table' then
        return nil, 'Invalid response listing albums for photo'
    end
    if response.error or response.exception then
        return nil, response.message or 'Failed to get albums for photo'
    end

    return response, nil
end

-- Delete photos.
--
-- DELETE /Photo requires BOTH photo_ids[] and from_id (the album the photos are
-- being removed from) as query parameters - omitting from_id returns 422. Pass
-- albumId whenever the caller knows it; otherwise we resolve it from the first
-- photo, which costs one extra request.
function LycheeAPI.deletePhotos(settings, photoIds, albumId)
    if not photoIds or #photoIds == 0 then
        return true, nil
    end

    local fromId = albumId
    if not fromId or fromId == '' then
        local albums = LycheeAPI.getPhotoAlbums(settings, photoIds[1])
        if albums and albums[1] and albums[1].id then
            fromId = albums[1].id
            logger:info('Resolved from_id ' .. fromId .. ' for photo ' .. tostring(photoIds[1]))
        else
            return false, 'Could not determine which album to delete the photos from'
        end
    end

    -- Build query string with photo_ids array plus the required from_id
    local queryParts = {}
    for _, photoId in ipairs(photoIds) do
        table.insert(queryParts, 'photo_ids[]=' .. tostring(photoId))
    end
    table.insert(queryParts, 'from_id=' .. tostring(fromId))
    local queryString = table.concat(queryParts, '&')

    local url = getBaseUrl(settings) .. '/Photo?' .. queryString
    local headers = buildHeaders(settings)

    -- Use LrHttp.post with DELETE method override
    local result, respHeaders = LrHttp.post(url, '', headers, 'DELETE', 30)

    -- Lychee returns 204 No Content on success, so an empty body is expected.
    if result == nil or result == '' then
        if respHeaders then
            for _, h in ipairs(respHeaders) do
                local field = h.field or h[1]
                local value = h.value or h[2]
                if field and field:lower() == 'status' then
                    local status = tonumber(tostring(value):match('%d+'))
                    if status and (status < 200 or status >= 300) then
                        return false, 'Failed to delete photos (status ' .. status .. ')'
                    end
                end
            end
        end
        return true, nil
    end

    local response = jsonDecode(result)
    if type(response) == 'table' and (response.error or response.exception or response.errors) then
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

-- Update album settings (everything except title, which is handled by renameAlbum)
-- Uses PATCH /Album with all editable properties
function LycheeAPI.updateAlbumSettings(settings, albumId, albumData)
    local url = getBaseUrl(settings) .. '/Album'
    local headers = buildHeaders(settings)

    local body = jsonEncode({
        album_id = albumId,
        title = albumData.title or '',
        description = albumData.description or JSON_NULL,
        license = albumData.license or 'none',
        copyright = albumData.copyright or JSON_NULL,
        photo_sorting_column = albumData.photo_sorting_column or JSON_NULL,
        photo_sorting_order = albumData.photo_sorting_order or JSON_NULL,
        album_sorting_column = albumData.album_sorting_column or JSON_NULL,
        album_sorting_order = albumData.album_sorting_order or JSON_NULL,
        album_aspect_ratio = albumData.album_aspect_ratio or JSON_NULL,
        photo_layout = albumData.photo_layout or JSON_NULL,
        album_timeline = albumData.album_timeline or JSON_NULL,
        photo_timeline = albumData.photo_timeline or JSON_NULL,
        -- Required by Lychee even if not changed
        is_compact = albumData.is_compact or false,
        is_pinned = albumData.is_pinned or false,
        header_id = albumData.header_id or JSON_NULL,
    })

    logger:info('Updating album settings: ' .. body)

    local result, respHeaders = LrHttp.post(url, body, headers, 'PATCH', 30)

    if not result then
        return false, 'Failed to update album settings (no response)'
    end

    local response = jsonDecode(result)
    if type(response) == 'table' and (response.error or response.exception or response.errors) then
        return false, 'Update failed: ' .. (response.message or response.exception or 'Unknown error')
    end

    return true, nil
end

-- Update album protection / visibility policy
-- Uses POST /Album::updateProtectionPolicy
function LycheeAPI.updateProtectionPolicy(settings, albumId, policyData)
    local url = getBaseUrl(settings) .. '/Album::updateProtectionPolicy'
    local headers = buildHeaders(settings)

    local body = {
        album_id = albumId,
        is_public = policyData.is_public or false,
        is_link_required = policyData.is_link_required or false,
        is_nsfw = policyData.is_nsfw or false,
        grants_full_photo_access = policyData.grants_full_photo_access or false,
        grants_download = policyData.grants_download or false,
        grants_upload = policyData.grants_upload or false,
    }

    -- Only include password field if explicitly provided
    if policyData.password and policyData.password ~= '' then
        body.password = policyData.password
    end

    local jsonBody = jsonEncode(body)
    logger:info('Updating protection policy: ' .. jsonBody)

    local result, respHeaders = LrHttp.post(url, jsonBody, headers, 30)

    -- Lychee may return 204 No Content on success
    if result == nil and respHeaders then
        for _, h in ipairs(respHeaders) do
            local field = h.field or h[1]
            local value = h.value or h[2]
            if field and field:lower() == 'status' then
                local status = tonumber(tostring(value):match('%d+'))
                if status and status >= 200 and status < 300 then
                    return true, nil
                end
            end
        end
    end

    if result and result ~= '' then
        local response = jsonDecode(result)
        if type(response) == 'table' and (response.error or response.exception or response.errors) then
            return false, 'Update failed: ' .. (response.message or response.exception or 'Unknown error')
        end
    end

    return true, nil
end

-- Expose findPhotoByFilename for use by the publish service provider
LycheeAPI.findPhotoByFilename = findPhotoByFilename

return LycheeAPI
