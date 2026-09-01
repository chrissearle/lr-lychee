# Lightroom Classic Plugin: Lychee

A publish service plugin for Adobe Lightroom Classic that synchronises photos to a
[Lychee](https://lychee.electerious.com/) photo gallery. Each publish service is its own
connection, so you can publish to several Lychee instances from one catalog.

Tested against **Lychee 7.7.5**. Lychee 7.5 changed the API in ways that break earlier
versions of this plugin — see [For developers](#for-developers).

---

## Installation

1. Download `LrLychee.lrplugin.zip` from the
   [releases page](https://github.com/chrissearle/lr-lychee/releases) and unzip it.
   (To run from a checkout instead, use the `LrLychee.lrdevplugin` folder directly.)
2. In Lightroom Classic: **File → Plug-in Manager → Add**, and select the
   `LrLychee.lrplugin` folder.
3. In Lychee, generate an API token: click your user name → **Edit My User** → create a
   token. Copy it — Lychee shows it only once.
4. In Lightroom's **Library** module, find **Lychee Gallery** in the **Publish
   Services** panel on the left and click **Set Up…**. Enter:
   - **Gallery URL** — e.g. `https://photos.example.com` (a trailing slash is fine)
   - **API token** — the token from step 3
5. Click **Test** to confirm the connection, then **Save**.

### Requirements

- Adobe Lightroom Classic
- Lychee **7.5 or newer** (developed and tested against 7.7.5)

---

## Usage

### Publishing

Create a **Published Collection** under the Lychee service, drag photos in, and click
**Publish**. The Lychee album is created on that first publish.

Nest collections inside **Published Collection Sets** to mirror the structure in your
gallery — sets become albums, to any depth.

### Album settings

Right-click a collection → **Edit Published Collection** to set description, copyright,
licence, sort order, layout, aspect ratio, timeline options, header image, and
visibility (public/private, NSFW, link-required, password, download and full-size
access).

These apply **as soon as you click the confirm button** — you do not need to publish
afterwards. The exception is a brand-new collection that has never been published: its
settings are held until the first publish creates the album.

Collection sets have the same dialog, and their settings apply to **that set's album
only** — they do not cascade to albums beneath it.

### What does not work

These are known limitations, most of them imposed by the Lightroom SDK rather than by
Lychee or this plugin.

| Limitation | Detail |
|---|---|
| **Publishing with nothing pending does nothing** | If no photo needs uploading, Lightroom never calls the plugin — "Publish Now" and the Publish button both no-op. Anything the plugin syncs *during* a publish (collection-set renames, album moves) will not happen. Use **Mark to Republish** on a photo to force a real publish. |
| **Deleting a collection set deletes nothing in Lychee** | The whole subtree — the set's album, nested sets, child albums and every photo — stays in the gallery. Lightroom provides no set-delete callback and does not raise its per-collection delete prompt for sets, so the plugin is never told. **Delete the album in Lychee by hand.** |
| **Renaming a collection set is not immediate** | Lightroom does not notify plugins when a *set* is renamed. The new name reaches Lychee on the next publish of a collection beneath it (and see the first row — that publish must have something to do). |
| **Empty collections and sets create no album** | An album appears once there is something to publish. An empty collection cannot even be published — Lightroom offers no publish action. |
| **"Leave the photos" keeps the Lychee album** | When deleting a collection, Lightroom asks whether to delete the published photos. Choose *leave them in their published location* and the album and photos stay in Lychee. This is Lightroom's behaviour, not a bug. |
| **Album moves apply on publish, not on drop** | Dragging a collection into or out of a set relocates the Lychee album at the next publish. |
| **Editing a photo changes its Lychee URL** | A develop edit means a re-upload, which gets a new Lychee photo ID — so any link you shared to that photo breaks. Title/caption-only changes are patched in place and keep the ID. |
| **Identical files are deduplicated** | Lychee matches on checksum. Uploading byte-identical images to the same album silently keeps one. |
| **JPEG and PNG only, sRGB only, no video** | Set in the export panels; other formats are not offered. |
| **No custom sort order** | Lightroom's manual drag-to-reorder is not supported. Use the album sort settings in the Edit dialog instead. |

### Troubleshooting

The plugin logs to `LycheePlugin.log` in Lightroom Classic's log folder. On macOS
that is:

```
~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LycheePlugin.log
```

On Windows it is the equivalent `LrClassicLogs` folder. Note the SDK documentation
still describes the older `~/Documents/<name>.log` location, which current Lightroom
Classic versions no longer use — if you cannot find the file, search for
`LycheePlugin.log`.

It records every album and photo operation, including the IDs involved, which is
usually enough to see what happened. If you report a problem, the log around the failing
publish is the most useful thing to include.

After editing plugin files, use **Plug-in Manager → Reload Plug-in**; Lightroom does not
pick up changes on its own.

---

## For developers

`DEVELOPMENT.md` holds the detailed notes. This section covers the decisions worth
knowing before changing anything.

### Read the SDK API Reference first

`docs/AdobeSDK.md` is only the **Programmer's Guide** — it does not list the
`publishServiceProvider` callbacks, so its silence proves nothing about whether a
callback exists. The real reference is the SDK download from
[developer.adobe.com/lightroom-classic](https://developer.adobe.com/lightroom-classic/);
unpack it into `docs/` (gitignored) and start at `API Reference/index.html`.

A good deal of this plugin's history is behaviour rediscovered by experiment that the
reference states outright. Check it before inferring anything from how Lightroom behaves.

### Lightroom re-executes the file for every callback

Each callback runs in a **fresh Lua state**, so module-level variables reset between
calls. Anything that must survive from one callback to the next goes in `LrPrefs`
(`prefsForPlugin()`), which is catalog-backed. The plugin uses it for:

- `pending_<name>` — collection settings entered before the album exists, applied on
  first publish and then cleared
- `hash_<photoId>` — the image-data hash of the last upload (see below)
- `setalbum_<localCollectionId>` — a collection set's Lychee album ID

### Recording remote IDs: two different mechanisms

Inside `processRenderedPhotos`, use the export session:

```lua
exportSession:recordRemoteCollectionId(albumId)
exportSession:recordRemoteCollectionUrl(albumUrl)
```

`publishedCollectionInfo` has **no `publishedCollection`** in that callback, so
`setRemoteId`/`setRemoteUrl` have nothing to write to and fail silently. Everywhere else
(dialog callbacks, where a real collection object exists) use the catalog form inside
`withWriteAccessDo`.

### Never wrap a yielding catalog call in `pcall`

`withReadAccessDo` / `withWriteAccessDo` yield, and yielding across a `pcall` boundary
raises `Yielding is not allowed within a C or metamethod call`. It looks exactly like
the operation legitimately failing, so a `pcall` added "for safety" silently takes the
fallback path forever. Put the `pcall` inside the access block instead.

### Collection sets get no lifecycle callbacks

`didCreateNewPublishedCollectionSet`, `renamePublishedCollectionSet` and
`deletePublishedCollectionSet` **do not exist** — confirmed against the API Reference,
which lists 42 `publishServiceProvider` members. Only the settings and label callbacks
exist for sets. Sets also carry no remote ID.

So sets are handled lazily from `ensureAncestorAlbums`: the album is created on the
first publish of a descendant, its ID is kept in `LrPrefs`, and a rename is detected by
comparing the set's Lightroom name against the album's **actual title on the server**.
Do not compare against a cached name — cache and Lightroom drift into agreeing with each
other while the gallery stays wrong.

Deletion cannot be handled at all; nothing publishes afterwards and no callback fires.

### Telling an image edit from a metadata change

The SDK gives no usable signal in `processRenderedPhotos`: `rendition.publishedPhoto` is
nil and `rendition.wasEditedSinceLastPublish` is not a real property. The plugin hashes
the rendered file instead and compares against the previous upload.

It hashes **only the JPEG image data** — walking the segment headers to the `SOS` marker
(`0xFFDA`) and hashing from there. Lightroom writes title and caption into the APP
segments, so hashing the whole file makes every caption change look like an image edit.

`LrPublishedPhoto:getEditedFlag()` is the authoritative answer and would be better; see
the follow-ups in `DEVELOPMENT.md`.

### Lychee API notes

Base URL is `{gallery_url}/api/v2`, Bearer token auth. Every request needs
**`Content-Type: application/json`** as well as `Accept` — without it the API returns
406, even for GETs with no body.

- **7.5 removed `GET /Album`**, splitting it into `Album::head`, `Album::photos` and
  `Album::albums`. `Album::head` returns `{ config, resource }` and carries no photos.
- **`POST /Album`** returns a bare unquoted ID as `text/html`.
- **`POST /Photo`** returns `expected_id` — optimistic, not a promise. Lychee dedupes by
  checksum on the queue worker, so confirm the ID appears in the album before trusting it.
- **`DELETE /Photo`** requires `from_id` as well as `photo_ids[]`, or 422.
- **`PATCH /Album`** requires all fourteen editable fields, or 422.
- Photos come back with `original_name: null`; the filename is in `title`.
- Non-ASCII arrives as `\uXXXX` escapes. The hand-rolled JSON decoder must convert them
  to UTF-8 — Lightroom is Lua 5.1, so there is no `utf8` library.

### Test rig

`test/docker-compose.yml` brings up a pinned Lychee instance, a queue worker and MariaDB
on `localhost:8000`. `test/TESTING.md` is the manual test plan — ~60 cases naming exactly
which of the images in `test/images/` to use, because photo state carries between
sections. `test/api-samples/` holds real captured responses for every endpoint the plugin
calls.

### AI assistance

Much of this code was written with AI assistance (Claude, Copilot). The behaviour is
verified against a real Lychee instance via `test/TESTING.md` rather than assumed.
