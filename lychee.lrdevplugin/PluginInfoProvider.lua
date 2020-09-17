local LrHttp = import "LrHttp"

local function sectionsForTopOfDialog( f, _ )
	return {
			{
				title = "Lychee Server and Login",
				f:row {
					spacing = f:control_spacing(),

					f:static_text {
						title = "Lychee Site URL",
						width_in_chars = 20,
					},
					f:edit_field {
						fill_horizonal = 1,
						width_in_chars = 35,
					}
				},
				f:row {
					spacing = f:control_spacing(),

					f:static_text {
						title = "Lychee API Key",
						width_in_chars = 20,
					},
					f:edit_field {
						fill_horizonal = 1,
						width_in_chars = 35,
					}
				},
				f:row {
					spacing = f:control_spacing(),
					f:static_text {
						title = "To set an API key in Lychee - Settings > Advanced > api_key",
						fill_horizontal = 1,
						size = 'small',
					},
				},
				f:row {
					spacing = f:control_spacing(),

					f:static_text {
						title = "Username",
						width_in_chars = 20,
					},
					f:edit_field {
						fill_horizonal = 1,
						width_in_chars = 35,
					}
				},
				f:row {
					spacing = f:control_spacing(),

					f:static_text {
						title = "Password",
						width_in_chars = 20,
					},
					f:password_field {
						fill_horizonal = 1,
						width_in_chars = 35,
					}
				},
			},
	
		}
end

return {
	sectionsForTopOfDialog = sectionsForTopOfDialog,
}
