--[[----------------------------------------------------------------------------
Info.lua - LrLychee Plugin Manifest

Lightroom Classic publish plugin for Lychee photo gallery.
------------------------------------------------------------------------------]]

return {
    LrSdkVersion = 11.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = 'org.chrissearle.lightroom.lychee',
    LrPluginName = 'Lychee Gallery',

    LrPluginInfoUrl = 'https://github.com/chrissearle/LrLychee',

    LrExportServiceProvider = {
        title = 'Lychee Gallery',
        file = 'LycheePublishServiceProvider.lua',
    },

    VERSION = { major = 1, minor = 0, revision = 0, build = 1 },
}
