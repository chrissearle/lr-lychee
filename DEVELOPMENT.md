# Development Notes

Technical reference for working on the lr-lychee plugin. Covers Lightroom Classic SDK quirks and Lychee Gallery API details learned during development.

## Adobe Lightroom Classic SDK

> **`docs/AdobeSDK.md` is the Programmer's Guide only — not the API Reference.**
> It documents `processRenderedPhotos` but has zero mentions of
> `renamePublishedCollection`, `deletePhotosFromPublishedCollection`,
> `viewForCollectionSettings` or `metadataThatTriggersRepublish`, all of which are
> real callbacks this plugin uses. Absence from that file proves nothing about
> whether a callback exists.
>
> The authoritative reference is the SDK download from
> <https://developer.adobe.com/lightroom-classic/>, unpacked in `docs/` (currently
> `LrC_15.3_.../API Reference/index.html`). Check it **first** — several hours went
> into rediscovering by experiment what it states outright. Useful pages:
> `modules/SDK - Publish service provider.html` (all 42 callbacks),
> `modules/LrPublishedPhoto.html`, `modules/LrCatalog.html`, plus `Sample Plugins/`.

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

**There are two different mechanisms, and using the wrong one fails silently.**

*Inside `processRenderedPhotos`* — use the export session:

```lua
exportSession:recordRemoteCollectionId(albumId)
exportSession:recordRemoteCollectionUrl(albumUrl)
```

`exportContext.publishedCollectionInfo` has **no `publishedCollection` field** in this
callback, so `setRemoteId`/`setRemoteUrl` have nothing to write to. Guarding with
`if publishedCollectionInfo.publishedCollection then ... end` silently skips the write
and the collection ends up with no Published Album URL and no stored remote ID — with
nothing in the log to say so. This mirrors `rendition:recordPublishedPhotoId/Url` for
photos; collections and photos work the same way here.

*Everywhere else* (dialog callbacks such as `viewForCollectionSettings`, where an
`info.publishedCollection` object genuinely exists) — use the catalog:

- `publishedCollection:getRemoteId()` — inside `catalog:withReadAccessDo()`
- `publishedCollection:setRemoteId(id)` — inside `catalog:withWriteAccessDo('reason', fn)`
- `publishedCollection:setRemoteUrl(url)` — same write access requirement

`publishedCollectionInfo` fields to expect in `processRenderedPhotos`:
`isDefaultCollection`, `name`, `parents`, and — **only once something has recorded
them** — `remoteId` and `remoteUrl`. The field is `remoteId`; there is no
`remoteCollectionId`. Note `pairs()` will not list `remoteId`/`remoteUrl` until they
have a value, so an empty-looking dump does not mean the field is unsupported.

`remoteId` being nil is what makes `isNewAlbum` true, which drives album creation and
skips move detection — so a plugin that never records it will re-create albums and
break drag-into-set moves. Remote IDs can also be legitimately nil for collections
created before the plugin stored them; `resolveRemoteId` falls back to a title search.

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

**Never wrap them in `pcall`.** Yielding across a `pcall` boundary raises:

```
Yielding is not allowed within a C or metamethod call
```

This fails at runtime only, and if you were using the `pcall` for safety it looks
exactly like the operation legitimately failing — so it silently takes your fallback
path forever. Put the `pcall` *inside* the access block, around the non-yielding
lookups:

```lua
local failure
catalog:withReadAccessDo(function()
    local ok, err = pcall(function()
        -- getPublishServices, getPublishedPhotos, getEditedFlag, ...
    end)
    if not ok then failure = err end
end)
```

### Collection sets get no create/rename/delete callbacks

Confirmed against the official SDK 15.3 API Reference in `docs/` (`API
Reference/modules/SDK - Publish service provider.html`), which lists 42
`publishServiceProvider` members. These **do not
exist** and were dead code here until removed:

- `didCreateNewPublishedCollectionSet`
- `renamePublishedCollectionSet`
- `deletePublishedCollectionSet`
- `canRenamePublishedCollection` / `canRenamePublishedCollectionSet` — the real field
  is the inverse, `disableRenamePublishedCollection` / `...Set`

The set callbacks that *do* exist are only `viewForCollectionSetSettings`,
`updateCollectionSetSettings`, `endDialogForCollectionSetSettings`,
`disableRenamePublishedCollectionSet` and `titleForPublishedCollectionSet` — i.e.
settings and labels, nothing about lifecycle.

Sets also carry no remote id: the `info` table has no `remoteId`, and a long-standing
Adobe bug leaves the documented `info.publishedCollectionSet` nil. The `parents`
entries in `processRenderedPhotos` carry only `isDefaultCollection`,
`localCollectionId` and `name`.

So the plugin handles sets entirely lazily, from `ensureAncestorAlbums`:

- **Creation** — the album is created on the first publish of a descendant. An empty
  set has no Lychee album yet, by design.
- **Identity** — the album id is recorded in `LrPrefs` against `localCollectionId`,
  Lightroom's stable handle for the set.
- **Rename** — detected in `ensureAncestorAlbums` by comparing `parent.name` against
  the album's **actual title on the server** (`Album::head`), then synced.

  Do *not* compare against a cached name: if the rename happens while the cache is
  being populated, cache and Lightroom agree with each other forever while the gallery
  stays wrong, and the bug conceals itself. The server title cannot go stale, so this
  also self-heals any existing drift.

  It takes effect during the next publish of a descendant — and note that with
  `supportsIncrementalPublish = 'only'`, a publish with nothing to do does not call
  `processRenderedPhotos` at all, so the rename will not sync until something actually
  publishes (Mark to Republish forces it).
- **Delete** — *cannot* be handled at all. Deleting a set in Lightroom leaves the
  **entire subtree** in Lychee: the set's album, nested set albums, every child
  album and every photo. Verified 2026-08-27.

  There is no set-delete callback, and the children are not covered either:
  `deletePublishedCollection` is "only invoked when the user clicks the 'Delete'
  button in the dialog which Lightroom presents... If the user chooses to leave the
  photos in their published location, the function is not called." Deleting a set
  never raises that dialog, so nothing fires.

  The same caveat applies to deleting a single collection: if the user picks "leave
  the photos", the Lychee album survives by design.

  A future mitigation could be an explicit plug-in menu item that lists Lychee albums
  with no corresponding published collection and offers to remove them. It must stay
  user-initiated — albums created directly in Lychee must never be swept up.

`reparentPublishedCollection` **does** exist and is not currently used — the plugin
detects moves at publish time by comparing `getAlbumParentId` with the expected
parent. Implementing the callback would make moves apply immediately instead of on
the next publish.

### Detecting whether a photo's image was edited

Lightroom hands `processRenderedPhotos` every photo that needs republishing, but does
**not** say why. Distinguishing "the image was edited" (re-upload) from "only metadata
changed" (PATCH) is left to the plugin, and the obvious routes are all dead ends:

- `rendition.publishedPhoto` is `nil` in this callback.
- `rendition.wasEditedSinceLastPublish` is **not an SDK property** — it reads nil
  always, silently downgrading every develop edit to a metadata-only update.
- The catalog route (`getPublishServices` → `getPublishedPhotos` →
  `LrPublishedPhoto:getEditedFlag()`) **yields from inside the read-access block**, so
  it cannot be guarded with `pcall`, and the SDK guide does not document
  `getPublishServices`' signature well enough to call it unguarded.

What works: **hash the rendered file's image data** and keep it in `LrPrefs` keyed by
the remote photo id. On re-publish, compare the fresh render against the stored hash.
This needs no SDK support and cannot yield.

Hashing the *whole* file does not work: Lightroom writes title and caption into the
exported JPEG's APP1/APP13 metadata segments, so a caption-only change alters the bytes
without touching a pixel, and every metadata edit looks like an image edit. Skip the
metadata by walking the JPEG segment headers to the **SOS marker (`0xFFDA`)** and
hashing from there:

```lua
-- verified: two renders differing only in a COM/APP segment hash identically,
-- while a genuinely different image does not
local function jpegImageDataOffset(data)
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil end
    local i = 3
    while i + 3 <= #data do
        if data:byte(i) ~= 0xFF then return nil end
        local marker = data:byte(i + 1)
        if marker == 0xDA then return i end                       -- image data
        if marker >= 0xD0 and marker <= 0xD9 then i = i + 2       -- standalone
        else i = i + 2 + (data:byte(i + 2) * 256 + data:byte(i + 3)) end
    end
    return nil
end
```

Non-JPEG renders (the service also allows PNG) fall back to hashing the whole file,
which errs towards re-uploading.

Every site that calls `rendition:recordPublishedPhotoId` must also store the hash, and
re-uploads must clear the old id's entry, or the prefs drift out of sync.

When the hash is missing or unreadable, **re-upload**: a redundant upload is cheap, a
stale image left online is not. Photos published before hashing existed re-upload once,
then settle.

---

## Lychee Gallery API (v7.x)

Base URL: `{gallery_url}/api/v2`

**Verified against Lychee 7.7.5** (2026-08-27). Captured responses for every
endpoint the plugin uses live in `test/api-samples/`. A running instance documents
itself at `{gallery_url}/docs/api` — the full OpenAPI 3.1 spec is embedded in that
page (`/docs/api.json` itself 404s).

### Non-ASCII text

Lychee returns non-ASCII as `\uXXXX` escapes (`"\u00a9 Test"` for `© Test`). The
plugin's hand-rolled `jsonDecode` must decode those to UTF-8 — an unknown-escape
fallback that keeps the letter after the backslash silently turns `© Test` into
`u00a9 Test`, and because the settings dialog loads from the server and writes back,
the corruption is persisted and compounds on every round trip.

Lightroom runs Lua 5.1, so there is no `utf8` library; encode code points by hand and
handle surrogate pairs for anything above the BMP. `jsonEncode` needs no matching
change — raw UTF-8 bytes are valid JSON on the way out.

### Content type

Every request must send **`Content-Type: application/json`** as well as
`Accept: application/json`. Without the Content-Type header the API returns
**406 `UnexpectedContentType`** ("Content type `json` required") - even for GETs
with no body. `buildHeaders()` sets both.

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
| GET | `/Albums` | Root-level albums only - `albums`, `smart_albums`, `shared_albums`, ... |
| GET | `/Album::head?album_id={id}` | Album metadata - `{ config, resource }`. **No photos, no child albums** |
| GET | `/Album::photos?album_id={id}` | Paginated photos - `{ photos, current_page, last_page, per_page, total }` |
| GET | `/Album::albums?album_id={id}` | Child albums - `{ data: [...] }` |
| POST | `/Album` | Create album (`title`, `parent_id`). Returns a **bare unquoted ID** as `text/html` |
| PATCH | `/Album` | Update album properties |
| POST | `/Album::move` | Move album to new parent. 204 on success |
| DELETE | `/Album` | Delete album (cascades to children + photos). 204 on success |

**`GET /Album` was removed in Lychee 7.5** and split into the three `Album::*`
endpoints above. `GET /Albums` returns only *root* albums - nested albums are not
in that list, so recursing via `Album::albums` is the only way to walk the tree.

#### Photos

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/Photo` | Upload photo (multipart). **Not** `/Photo::upload` |
| PATCH | `/Photo` | Update photo metadata |
| DELETE | `/Photo` | Delete photos - `photo_ids[]` **and `from_id`** as query params |
| GET | `/Photo/{photo_id}/albums` | Albums containing a photo - `[{ id, title }]` |
| POST | `/Photo::move` | Move photos between albums |

**`DELETE /Photo` requires `from_id`** (the album the photos are being removed
from) as well as `photo_ids[]`. Omitting it returns **422** - "The from id field is
required." When the caller doesn't know the album, `LycheeAPI.deletePhotos`
resolves it via `GET /Photo/{photo_id}/albums`.

#### Protection Policy

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/Album::updateProtectionPolicy` | Update visibility/access settings |

### Album Details Response Structure

`GET /Album::head?album_id={id}` returns `{ config, resource }`. Note there is **no
`photos` array** - fetch photos separately with `Album::photos`:

```json
{
  "config": { "...": "viewer/layout flags" },
  "resource": {
    "id": "24-char-hex-string",
    "title": "Album Name",
    "description": "...",
    "copyright": "...",
    "parent_id": null,
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

When updating album properties, **all fourteen** of these are required even if
unchanged (per the 7.7.5 spec - sending a subset returns 422):

```json
{
  "album_id": "...", "title": "...", "license": "none",
  "description": null, "copyright": null,
  "photo_sorting_column": null, "album_sorting_column": null,
  "album_aspect_ratio": null, "photo_layout": null,
  "album_timeline": null, "photo_timeline": null,
  "is_compact": false, "is_pinned": false, "header_id": null
}
```

`photo_sorting_order` and `album_sorting_order` are optional, as are `tags` and
`slug`.

- `is_compact` — derived from `header_id == 'compact'` (boolean)
- `header_id` — null for default, or a 24-char photo ID for a specific header photo
- When `is_compact` is true, `header_id` should be null
- `is_pinned` — preserve from server (not exposed in our UI)

### updateProtectionPolicy Required Fields

```json
{
  "album_id": "...",
  "is_public": false,
  "is_link_required": false,
  "is_nsfw": false,
  "grants_full_photo_access": false,
  "grants_download": false,
  "grants_upload": false
}
```

**Note**: `grants_upload` is required even though we don't expose it in the UI — always send `false`.
`password` is the only optional field; `is_password_required` is returned by the API
but is not accepted as input. Returns 201 with the resulting policy.

### Photo Upload

Multipart `POST /Photo` with `album_id`, `file_name`, `uuid_name` (empty),
`extension` (empty), `chunk_number=1`, `total_chunks=1`, and the `file` part.

The response is an `UploadMetaResource`, **not** the photo:

```json
{
  "file_name": "Test Photo (1).jpg", "extension": ".jpg",
  "uuid_name": "ovW7znrnmlOa10F-.jpg", "stage": "ready",
  "chunk_number": 1, "total_chunks": 1,
  "expected_id": "XjBKS2D2GbxzyvReRiAbYLDq",
  "title": null, "description": null
}
```

**`expected_id` (Lychee 7.7+) is optimistic, not a promise.** The import runs on
the queue worker, and **Lychee deduplicates by checksum**: upload bytes that already
exist and the upload is silently dropped, no photo is added to the album, and the
`expected_id` is never allocated. Verified - a second upload of identical bytes left
the album at one photo and `PATCH /Photo` on its `expected_id` returned 404.

So `uploadPhoto` treats `expected_id` as a *candidate*: it polls `Album::photos` and
returns it only once that id actually appears, falling back to filename matching
otherwise. Matching on id is far more reliable than on filename, because...

**Photos come back with `original_name: null`** and the filename in `title`. The
`original_name or title` fallback in `findPhotoByFilename` is load-bearing, not
defensive.

### Header Image States

The `header_id` field has three possible states:

1. **`null`** — default auto-generated header from album photos
2. **`"compact"`** — no hero banner, just a compact title bar
3. **`"24-char-photo-id"`** — specific album photo used as the hero banner

In the PATCH request, this is split into two fields:
- `is_compact = true` + `header_id = null` → compact mode
- `is_compact = false` + `header_id = null` → default mode
- `is_compact = false` + `header_id = "photo-id"` → specific photo

### Walking the Album Tree

There is no single tree call in use. `GET /Albums` gives **root albums only**;
descend with `GET /Album::albums?album_id={id}` (`{ data: [...] }`) one level at a
time. `findAlbumByTitleUnderParent` relies on this to scope a title lookup to the
right parent, which is what makes two same-named collections in different sets work.

`resource.parent_id` from `Album::head` is `null` for root-level albums and the
parent's id otherwise; it updates correctly after `Album::move`, so it is a reliable
basis for the "has this collection been dragged elsewhere?" check.

---

## Plugin Architecture Patterns

### Remote ID Resolution

Many old collections don't have a stored `remoteId`. The `resolveRemoteId` function handles this:

1. Try `publishedCollection:getRemoteId()` via `catalog:withReadAccessDo()`
2. If nil, fall back to `LycheeAPI.findAlbumByTitle(settings, name)`
3. If found, store it back via `setRemoteId()` and `setRemoteUrl()` for future use

### Duplicate Detection

Before uploading, check if a photo with the same filename already exists in the album:

1. Refresh album data via `getAlbumPhotos()` (not `getAlbumDetails` - `Album::head`
   carries no photos)
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


---

## Known follow-ups

Both are viable now that the SDK API Reference is in `docs/`; neither is urgent.

### Use `getEditedFlag()` instead of hashing renders

`LrPublishedPhoto:getEditedFlag()` is documented as "reports whether the associated
photo has been edited since last published" — exactly the signal the SOS-hash
heuristic approximates. Reach it via `catalog:getPublishServices(PLUGIN_ID)` →
published collections → `getPublishedCollections`/`getPublishedPhotos()`.

The earlier attempt failed only because the whole block was wrapped in `pcall`, which
is illegal around a yielding catalog call. The signature is confirmed:
`getPublishServices(pluginId)`.

The hash approach works and is verified end to end, but it assumes Lightroom's JPEG
encoding is deterministic and it keeps state in `LrPrefs` that can be lost. The SDK
flag is authoritative.

### `reparentPublishedCollection` for immediate moves

Exists and is unused. The plugin currently detects a move at publish time by
comparing `getAlbumParentId` with the expected parent, so a drag into a set only takes
effect on the next publish. The callback would make it immediate.

### `getPublishedCollectionByLocalIdentifier` for collection sets

`catalog:getPublishedCollectionByLocalIdentifier(id)` retrieves "a publish collection
**or collection set**". That would give a real object for a set from
`parent.localCollectionId`, instead of the `LrPrefs` mapping used now. Marginal:
there are no set lifecycle callbacks either way, so it would not restore rename or
delete — but it would survive prefs loss.
