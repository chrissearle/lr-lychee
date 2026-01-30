# Lightroom Classic Plugin: Lychee

This project is a plugin for Adobe Lightroom Classic that synchronizes photos to a web gallery. It uses the Adobe Lightroom SDK to integrate with Lightroom Classic.

Each publish service gets its own connection (you can connect to several Lychee instances) and can have several Publish Collections (maps to album on Lychee).

## Getting Started

1. Install Adobe Lightroom Classic.
2. Copy the `Lychee.lrdevplugin` folder to the Lightroom plugins directory (or add it where it is via Add Plugin)
3. Enable the plugin in Lightroom Classic.
4. Add a publish service - set the gallery URL and token (token can be generated under edit my user in Lychee)
5. Add a publish collection and photos and publish.

## Caveats

- The code here is generated with claude code - my Lua skills and the state of the adobe documentation combined are not great :P
- Only tested against lychee 7.x
- So far - only album creation, upload of photo, and change of metadata (title, caption, tags) tested.
