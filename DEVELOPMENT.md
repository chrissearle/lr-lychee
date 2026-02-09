# Development Notes

Technical reference for working on the lr-lychee plugin. Covers Lightroom Classic SDK quirks and Lychee Gallery API details learned during development.

## Adobe Lightroom Classic SDK

### Plugin Structure

- `Info.lua` — plugin manifest, declares `LrExportServiceProvider` pointing to the main provider file
- `LycheePublishServiceProvider.lua` — all SDK callbacks (publish, collections, dialogs)
- `LycheeAPI.lua` — HTTP client for Lychee's REST API

### Key SDK Imports

```lua
local LrView = import 'LrView'           -- UI building
local LrBinding = import 'LrBinding'     -- Observable data binding
local LrDialogs = import 'LrDialogs'     -- Alert dialogs
local LrTasks = import 'LrTasks'         -- Async tasks, sleep
local LrHttp = import 'LrHttp'           -- HTTP requests
local LrPathUtils = import 'LrPathUtils' -- File path manipulation
local LrApplication = import 'LrApplication' -- Catalog access
local LrErrors = import 'LrErrors'       -- Error handling
local LrLogger = import 'LrLogger'       -- Logging (writes to ~/Documents/lrClassicLogs/)
```

### Publish Service Provider Properties

```lua
publishServiceProvider.exportPresetFields = { { key = 'field_name', default = '' } }
publishServiceProvider.supportsIncrementalPublish = 'only'
publishServiceProvider.canRenamePublishedCollection = true
publishServiceProvider.canRenamePublishedCollectionSet = true
publishServiceProvider.allowFileFormats = { 'JPEG', 'PNG' }
publishServiceProvider.allowColorSpaces = { 'sRGB' }
publishServiceProvider.canExportVideo = false
```

#### Section Visibility

`showSections` acts as a **whitelist** — only listed sections appear. `hideSections` is a blacklist but is overridden by `showSections`. If you use `showSections`, every section you want visible must be listed:

```lua
publishServiceProvider.showSections = { 'fileNaming', 'imageSettings', 'outputSharpening', 'metadata' }
publishServiceProvider.hideSections = { 'exportLocation', 'video' }
```

Available section IDs: `exportLocation`, `fileNaming`, `video`, `imageSettings`, `outputSharpening`, `metadata`, `watermarking`.

### Callback Lifecycle

#### Publishing

1. `processRenderedPhotos(functionContext, exportContext)` — main upload loop
   - Already runs in an async context (can yield)
   - `exportContext.exportSession:countRenditions()` for count
   - `exportContext:renditions { stopIfCanceled = true }` to iterate
   - Each `rendition:waitForRender()` returns `(success, pathOrMessage)`
   - `rendition.publishedPhotoId` — the stored remote ID (nil for new photos)
   - `rendition.photo` — the LrPhoto object for metadata access
   - `rendition:recordPublishedPhotoId(remoteId)` — store the remote ID after upload
   - `rendition:uploadPhoto(...)` — NOT a real method; use your own API call
   - The rendered file path already reflects any File Naming template the user configured

#### Collections

- `getCollectionBehaviorInfo(publishSettings)` — return table with `defaultCollectionName`, `canAddCollection`, `canAddCollectionSet`, etc.
- `didCreateNewPublishedCollectionSet(publishSettings, info)` — called AFTER a collection set is created; `info.publishedCollectionSet`, `info.name`, `info.parents`
- `deletePublishedCollectionSet(publishSettings, info)` — called to delete; `info.remoteId`, `info.name`
- `renamePublishedCollection(publishSettings, info)` — `info.publishedCollection`, `info.name`
- `renamePublishedCollectionSet(publishSettings, info)` — `info.publishedCollectionSet`, `info.remoteId`, `info.name`
- `deletePhotosFromPublishedCollection(publishSettings, arrayOfPhotoIds, deletedCallback, localCollectionId)` — call `deletedCallback(photoId)` for each successfully deleted photo

#### Collection Settings (Edit Published Collection Dialog)

- `viewForCollectionSettings(f, publishSettings, info)` — **synchronous**, must return a view immediately
  - `info.collectionSettings` — `LrObservableTable`, properties bound to UI controls update live
  - `info.publishedCollection` — the published collection object (nil for new collections)
  - `info.name` — collection name
  - Use `LrTasks.startAsyncTask(function() ... end)` inside to fetch data from server
  - Setting properties on `collectionSettings` from async task updates bound UI controls in real time

- `updateCollectionSettings(publishSettings, info)` — called when user clicks OK
  - `info.collectionSettings` — the final settings values
  - `info.remoteId` — **often nil** for old collections; use fallback resolution
  - `info.publishedCollection` — the collection object

- `viewForCollectionSetSettings` / `updateCollectionSetSettings` — identical pattern for collection sets

#### Key SDK Constraints (viewForCollectionSettings)

1. **Must return view synchronously** — no yielding in the callback itself; use `startAsyncTask` for server calls
2. **`popup_menu` `items` binding works** — `items = bind 'property_name'` updates the popup dynamically when the observable property changes (this is how header image photo list works)
3. **`popup_menu` `value` binding works** — standard observable binding
4. **`visible` binding on containers does NOT work** in this context — use `enabled` on individual controls instead
5. **`enabled` binding on individual controls DOES work** — use for showing/hiding sub-options

#### Collection URL

- `getCollectionUrl(publishSettings, publishedCollectionInfo)` — **synchronous**, cannot yield
  - `publishedCollectionInfo.remoteId` — may be nil
  - Return a URL string or nil
  - Returning nil shows "Can't find the URL" error dialog — return gallery root as fallback instead

#### Remote ID Management

- `publishedCollection:getRemoteId()` — must be called inside `catalog:withReadAccessDo()`
- `publishedCollection:setRemoteId(id)` — must be called inside `catalog:withWriteAccessDo('reason', fn)`
- `publishedCollection:setRemoteUrl(url)` — same write access requirement
- Remote IDs can be nil for collections created before the plugin stored them — always have a fallback

### LrObservableTable

Properties set on an `LrObservableTable` (like `info.collectionSettings`) trigger UI updates on bound controls:

```lua
collectionSettings.description = 'new value'  -- Updates bound edit_field immediately
collectionSettings.header_items = { ... }      -- Updates bound popup_menu items immediately
```

This works from async tasks too — the UI refreshes as soon as the property is set.

### LrView UI Building

```lua
f:row { spacing = f:label_spacing(), ... }
f:column { spacing = f:control_spacing(), fill_horizontal = 1, ... }
f:group_box { title = 'Section', fill_horizontal = 1, ... }
f:static_text { title = 'Label', alignment = 'right', width = LrView.share 'shared_width' }
f:edit_field { value = bind 'prop', width_in_chars = 40 }
f:popup_menu { value = bind 'prop', items = STATIC_TABLE, width = 200 }
f:popup_menu { value = bind 'prop', items = bind 'dynamic_items_prop', width = 200 }
f:checkbox { value = bind 'prop', title = 'Label', enabled = bind 'other_prop' }
```

`LrView.share 'name'` — share a width measurement across controls for alignment.

### HTTP Requests (LrHttp)

```lua
LrHttp.get(url, headers, timeout)
LrHttp.post(url, body, headers, timeout)
LrHttp.post(url, body, headers, 'PATCH', timeout)  -- Method override for PATCH/DELETE
LrHttp.post(url, body, headers, 'DELETE', timeout)
LrHttp.postMultipart(url, content, headers, timeout)
```

- All return `(result, responseHeaders)`
- `responseHeaders.status` contains the HTTP status code
- For multipart uploads, set `skipContentType = true` on headers (postMultipart adds its own)

### Logging

```lua
local logger = LrLogger('LycheePlugin')
logger:enable('logfile')  -- Writes to ~/Documents/lrClassicLogs/LycheePlugin.log
logger:info('message')
logger:warn('message')
logger:error('message')
```

### Catalog Access

```lua
local catalog = LrApplication.activeCatalog()

-- Read access (for getRemoteId, etc.)
catalog:withReadAccessDo(function()
    local id = publishedCollection:getRemoteId()
end)

-- Write access (for setRemoteId, etc.)
catalog:withWriteAccessDo('Reason string', function()
    publishedCollection:setRemoteId(albumId)
end)
```

**Important**: These calls yield, so they can only be used inside async tasks or other yielding contexts (like `processRenderedPhotos`).

---

## Lychee Gallery API (v7.x)

Base URL: `{gallery_url}/api/v2`

### Authentication

All requests use Bearer token authentication:
```
Authorization: Bearer {api_token}
```

Token is generated in Lychee under user settings (Edit My User).

### Endpoints

#### Albums

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/Albums::tree` | Get full album tree |
| GET | `/Album?album_id={id}` | Get album details (includes photos, editable, policy) |
| POST | `/Album` | Create album (`title`, `parent_id`) |
| PATCH | `/Album` | Update album properties |
| POST | `/Album::move` | Move album to new parent |
| DELETE | `/Album` | Delete album |

#### Photos

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/Photo::upload` | Upload photo (multipart) |
| PATCH | `/Photo` | Update photo metadata |
| DELETE | `/Photo` | Delete photos |
| POST | `/Photo::move` | Move photos between albums |

#### Protection Policy

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/Album::updateProtectionPolicy` | Update visibility/access settings |

### Album Details Response Structure

`GET /Album?album_id={id}` returns:

```json
{
  "resource": {
    "id": "24-char-hex-string",
    "title": "Album Name",
    "description": "...",
    "copyright": "...",
    "photos": [
      { "id": "24-char-hex", "title": "Photo Title", "original_name": "DSC_1234.jpg" }
    ],
    "editable": {
      "license": "none|reserved|CC0|CC-BY-4.0|...",
      "photo_sorting": { "column": "created_at|taken_at|title|...", "order": "ASC|DESC" },
      "album_sorting": { "column": "created_at|title|...", "order": "ASC|DESC" },
      "aspect_ratio": "5/4|4/3|3/2|16/9|1/1|2/3",
      "photo_layout": "square|justified|masonry|grid|...",
      "album_timeline": "...",
      "photo_timeline": "...",
      "header_id": null | "compact" | "24-char-photo-id",
      "is_pinned": true|false
    },
    "policy": {
      "is_public": true|false,
      "is_link_required": true|false,
      "is_nsfw": true|false,
      "grants_full_photo_access": true|false,
      "grants_download": true|false,
      "is_password_required": true|false
    }
  }
}
```

**Important**: Settings like `license`, `photo_sorting`, `aspect_ratio`, etc. are in `resource.editable`, NOT directly on `resource`.

### PATCH /Album Required Fields

When updating album properties, these fields are **required** even if unchanged:

```json
{
  "album_id": "...",
  "title": "...",
  "is_compact": false,
  "is_pinned": false,
  "header_id": null
}
```

- `is_compact` — derived from `header_id == 'compact'` (boolean)
- `header_id` — null for default, or a 24-char photo ID for a specific header photo
- When `is_compact` is true, `header_id` should be null
- `is_pinned` — preserve from server (not exposed in our UI)

### updateProtectionPolicy Required Fields

```json
{
  "albumID": "...",
  "is_public": false,
  "is_link_required": false,
  "is_nsfw": false,
  "grants_full_photo_access": false,
  "grants_download": false,
  "is_password_required": false,
  "grants_upload": false
}
```

**Note**: `grants_upload` is required even though we don't expose it in the UI — always send `false`.

### Photo Upload

Multipart POST to `/Photo::upload`:
- `album_id` — target album
- File field with the photo data
- Returns the uploaded photo's ID (after matching via album refresh)

### Header Image States

The `header_id` field has three possible states:

1. **`null`** — default auto-generated header from album photos
2. **`"compact"`** — no hero banner, just a compact title bar
3. **`"24-char-photo-id"`** — specific album photo used as the hero banner

In the PATCH request, this is split into two fields:
- `is_compact = true` + `header_id = null` → compact mode
- `is_compact = false` + `header_id = null` → default mode
- `is_compact = false` + `header_id = "photo-id"` → specific photo

### Album Tree Response

`GET /Albums::tree` returns a flat list of albums with parent relationships. Each album has:
- `id` — 24-character hex string
- `title` — album name
- `parent_id` — parent album ID or null for root

---

## Plugin Architecture Patterns

### Remote ID Resolution

Many old collections don't have a stored `remoteId`. The `resolveRemoteId` function handles this:

1. Try `publishedCollection:getRemoteId()` via `catalog:withReadAccessDo()`
2. If nil, fall back to `LycheeAPI.findAlbumByTitle(settings, name)`
3. If found, store it back via `setRemoteId()` and `setRemoteUrl()` for future use

### Duplicate Detection

Before uploading, check if a photo with the same filename already exists in the album:

1. Refresh album data via `getAlbumDetails()`
2. Use `findPhotoByFilename()` to match by `original_name` or `title`
3. Matching is normalized (case-insensitive, special chars stripped)
4. If found, skip upload and use the existing photo's ID

### Move Detection

When republishing, if a photo's `publishedPhotoId` exists but isn't found in the current album's photo list, it was moved:

1. Delete the photo from the old album
2. Re-upload to the current album
3. Update the stored remote ID

### Known Photo ID Tracking

The `knownPhotoIds` array tracks IDs of photos already in the album. This prevents the duplicate detection from matching a just-uploaded photo to itself when processing multiple photos in one publish batch.
