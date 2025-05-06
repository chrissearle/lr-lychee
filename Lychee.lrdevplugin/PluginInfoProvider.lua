local LrView = import 'LrView'
local LrPrefs = import 'LrPrefs'

local prefs = LrPrefs.prefsForPlugin()

return {
    sectionsForTopOfDialog = function(f)
        return {
            {
                title = "Lychee Configuration",
                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = "Lychee Site URL:",
                        alignment = 'right',
                        width = 150,
                    },
                    f:edit_field {
                        value = LrView.bind {
                            key = 'lycheeSiteUrl',
                            bind_to_object = prefs,
                        },
                        width_in_chars = 40,
                    },
                },
                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = "Lychee Username:",
                        alignment = 'right',
                        width = 150,
                    },
                    f:edit_field {
                        value = LrView.bind {
                            key = 'lycheeUsername',
                            bind_to_object = prefs,
                        },
                        width_in_chars = 40,
                    },
                },
                f:row {
                    spacing = f:control_spacing(),
                    f:static_text {
                        title = "Lychee Password:",
                        alignment = 'right',
                        width = 150,
                    },
                    f:password_field {
                        value = LrView.bind {
                            key = 'lycheePassword',
                            bind_to_object = prefs,
                        },
                        width_in_chars = 40,
                    },
                },
            },
        }
    end,
}