local LrHttp = import 'LrHttp'
local LrPrefs = import 'LrPrefs'
local LrErrors = import 'LrErrors'

local prefs = LrPrefs.prefsForPlugin()

local logger = require 'Logger'

local LycheeAPI = {}

local currentToken = {}

-- Function to construct the base URL for the Lychee API
function LycheeAPI.getBaseUrl()
    local baseUrl = prefs.lycheeSiteUrl
    if not baseUrl or baseUrl == "" then
        logger.error("Lychee Site URL is not configured.")
        LrErrors.throwUserError("Lychee Site URL is not configured.")
    end
    return baseUrl .. "api/v2"
end

function LycheeAPI.updateTokenFromCookies(headers)
    for _, header in ipairs(headers) do
        if header.field:lower() == "set-cookie" then
            local cookieTable = LrHttp.parseCookie(header.value, true)
            if cookieTable["XSRF-TOKEN"] then
                currentToken.xsrfToken = cookieTable["XSRF-TOKEN"]
                logger:info("Updated XSRF Token: " .. (currentToken.xsrfToken or "nil"))
            end
        end
    end
end

function LycheeAPI.getOriginalToken()
    local initUrl = prefs.lycheeSiteUrl
    local initResponse, initHeaders = LrHttp.get(initUrl)

    if not initResponse then
        logger.error("Failed to connect to Lychee server.")
        LrErrors.throwUserError("Failed to connect to Lychee server.")
    end

    LycheeAPI.updateTokenFromCookies(initHeaders)

    if not currentToken.xsrfToken then
        logger.error("Failed to retrieve initial CSRF token.")
        LrErrors.throwUserError("Failed to retrieve initial CSRF token.")
    end
end

-- Function to handle HTTP response errors
function LycheeAPI.handleResponseErrors(response, responseHeaders)
    local statusCode = responseHeaders.status or 0

    if not response or statusCode < 200 or statusCode >= 300 then
        logger:info("HTTP Error. Status code: " .. statusCode .. ", Response body: " .. (response or nil))
        
        LrErrors.throwUserError("Request failed with HTTP status code: " .. statusCode)
    end
end

-- Function to log in to the Lychee API
function LycheeAPI.login()
    LycheeAPI.getOriginalToken()

    local username = prefs.lycheeUsername
    local password = prefs.lycheePassword

    if not username or username == "" or not password or password == "" then
        LrErrors.throwUserError("Lychee username or password is not configured.")
    end

    local url = LycheeAPI.getBaseUrl() .. "/Auth::login"
    local body = string.format("{\"username\":\"%s\",\"password\":\"%s\"}", username, password)

    local headers = {
        { field = "Content-Type", value = "application/json" },
        { field = "Accept", value = "application/json" },
        { field = "X-Requested-With", value = "XMLHttpRequest" },
        { field = "X-XSRF-TOKEN", value = currentToken.xsrfToken },
    }
    
    local response, responseHeaders = LrHttp.post(url, body, headers)

    LycheeAPI.handleResponseErrors(response, responseHeaders)

    LycheeAPI.updateTokenFromCookies(responseHeaders)

    return response, responseHeaders
end

return LycheeAPI