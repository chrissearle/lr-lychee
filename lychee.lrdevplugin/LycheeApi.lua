local LrErrors = import "LrErrors"
local LrDialogs = import "LrDialogs"
local LrHttp = import "LrHttp"
local LrPathUtils = import "LrPathUtils"

local logger = import "LrLogger"("Lychee")

logger:enable("logfile")

local prefs = import "LrPrefs".prefsForPlugin()

JSON = (loadfile(LrPathUtils.child(_PLUGIN.path, "json.lua")))()

LycheeAPI = {}

local function getCookies(data)
	local cookies = {}

	for _, v in pairs(data) do
		if (type(v) == "table") then
			if (v.field == "Set-Cookie") then
				cookies[#cookies + 1] = v.value
			end
		end
	end

	return cookies
end

local function initHeaders(headers)
	local cookies = LycheeAPI.init()

	for _, cookie in pairs(cookies) do
		c = LrHttp.parseCookie(cookie)

		if c["lychee_session"] ~= nil then
			headers[#headers + 1] = {
				field = "Cookie",
				value = "lychee_session=" .. c["lychee_session"]
			}
		end
	end

	return headers
end

function LycheeAPI.getConfig()
	local url, api_key, username, password =
		prefs.lychee_site_url,
		prefs.lychee_api_key,
		prefs.lychee_username,
		prefs.lychee_password

	if
		not (type(url) == "string" and #url >= 10 and type(api_key) == "string" and #api_key >= 1 and
			type(username) == "string" and
			#username >= 1 and
			type(password) == "string" and
			#password >= 1)
	 then
		logger.info("Did not find enough config")

		LrErrors.throwUserError("You need to enter the configuration via Plugin Manager")
	end

	return url, api_key, username, password
end

function LycheeAPI.init()
	local url, api_key, username, password = LycheeAPI.getConfig()

	local init_url = url .. "/api/Session::init"

	logger:info("Calling init on " .. init_url)

	local headers = {
		{field = "Authorization", value = api_key}
	}

	local _, data = LrHttp.post(init_url, "", headers, "POST")

	return getCookies(data)
end

function LycheeAPI.login()
	local url, api_key, username, password = LycheeAPI.getConfig()

	local login_url = url .. "/api/Session::login"

	logger:info("Calling login on " .. login_url)

	local headers =
		initHeaders(
		{
			{field = "Authorization", value = api_key},
			{field = "Content-Type", value = "application/x-www-form-urlencoded"}
		}
	)

	local loginResponse, data = LrHttp.post(login_url, "user=" .. username .. "&password=" .. password, headers, "POST")

	if (loginResponse == "true") then
		LrDialogs.message("Login succeeded")
	else
		LrErrors.throwUserError("Login failed - please check the configuration via Plugin Manager")
	end
end

function LycheeAPI.getAlbums()
	local url, api_key, username, password = LycheeAPI.getConfig()

	local albums_url = url .. "/api/Albums::get"

	logger:info("Calling albums on " .. albums_url)

	local headers =
		initHeaders(
		{
			{field = "Authorization", value = api_key},
			{field = "Content-Type", value = "application/x-www-form-urlencoded"}
		}
	)

	local albumsResponse, data = LrHttp.post(albums_url, "", headers, "POST")

	local albums = JSON:decode(albumsResponse)

	logger:info(JSON:encode_pretty(albums))
end
