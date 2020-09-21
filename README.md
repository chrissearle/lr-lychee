# Lightroom plugin for Lychee

A Lightroom Classic plugin for publishing to [Lychee](https://lycheeorg.github.io/)

You will need to set an api key on your lychee instance (settings > advanced > api_key) - some long unique ID.

## Initial Goals

Login and upload images to a gallery

- Login
- List all available galleries
- Upload image

## Concepts

Once the user has added the plugin - they enter their credentials via the plugin admin page in the Plugin Manager window.

The album tree will be fetched and created as a folder structure under the Lychee Publish Service (collection/collection sets or similar)

On publish - add a custom tag to each image with its lychee ID (or something like that)

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
