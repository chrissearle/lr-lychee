# Lightroom Classic Plugin: Lychee

This project is a plugin for Adobe Lightroom Classic that synchronizes photos to a web gallery. It uses the Adobe Lightroom SDK to integrate seamlessly with Lightroom Classic.

## Getting Started

1. Install Adobe Lightroom Classic.
2. Copy the `Lychee.lrdevplugin` folder to the Lightroom plugins directory (or add it where it is via Add Plugin)
3. Enable the plugin in Lightroom Classic.
4. Configyure site URL, username and password in Plugin Manager

## Development

- Use Lua for scripting.
- Follow Adobe's [Lightroom SDK documentation](https://www.adobe.io/apis/creativecloud/lightroomclassic.html).
- Follow Lychee's API (append /docs/api to your gallery URL)

## Initial Goals

Login and upload images to a gallery

- Login - working
- List all available galleries - TODO
- Upload images - TODO

## Concepts

Once the user has added the plugin - they enter their credentials via the plugin admin page in the Plugin Manager window.

The album tree will be fetched and created as a folder structure under the Lychee Publish Service (collection/collection sets or similar)

On publish - add a custom tag to each image with its lychee ID (or something like that)

TODO - check for any changes in Lychee API v2

| Publish Service Action                                |  Lychee API                                    | Notes                                  |
| ----------------------------------------------------- | ---------------------------------------------- | -------------------------------------- |
| Add new image to publish service                      | Photo::add + Photo::setTags                    |                                        |
| Update a published image (editing or metadata change) | Photo::delete then Photo::add + Photo::setTags | Did not see a replace or update method |
| Remove image from publish service                     | Photo::delete                                  |                                        |
| Add collection or collection set                      | Album::add                                     |                                        |
| Rename collection or collection set                   | Album::setTitle                                |                                        |
| Delete a collection or collection set                 | Album::delete                                  | Do we really want to do this?          |

### Things to think about

- Existing images from before the plugin was set up - can we sync back to LR if we have them in LR?
- Do we want to delete albums? Or should the user do that in the web admin?
- If we have a published collection and the user deletes it via the web - how to handle?
- If the user deletes an image in an album via the web - can we pick this up?
-

## License

This project is licensed under the MIT License.
