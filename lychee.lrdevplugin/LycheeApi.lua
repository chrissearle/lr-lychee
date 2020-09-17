local LrErrors = import 'LrErrors'
local LrHttp = import "LrHttp"

local prefs = import 'LrPrefs'.prefsForPlugin()

local logger = import 'LrLogger'( 'Lychee' )

LycheeApi = {}


function LycheeApi.getConfig()

	local url, api_key, username, password = prefs.lychee_site_url, prefs.lychee_api_key, prefs.lychee_username, prefs.lychee_password
	
	if not(
		type( url ) == 'string' and #url >= 10 and
		type( api_key ) == 'string' and #api_key >= 1 and
		type( username ) == 'string' and #username >= 1 and
		type( password ) == 'string' and #password >= 1
    ) then do
        LrErrors.throwUserError( "You need to enter the configuration via Plugin Manager" )
	end
	
	return url, api_key, username, password
end


function LycheeApi.login()
    local url, api_key, username, password = getConfig()

    local loginResponse = LrHttp.post(
		url .. '/api/Session::login',
		'user=' .. username .. '&password=' .. password,
		{
			{
				'field' = 'Content-Type',
				'value' = 'x-www-form-urlencoded'
			},
			{
				'field' = 'Authorization',
				'value' = api_key
			}
		},
		'POST'
	)

	if not(loginResponse == 'true') then do
		 LrErrors.throwUserError( "login failed - please check the configuration via Plugin Manager" )
	end
end

function 