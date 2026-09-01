# Lychee 7.7.5 API samples

Real responses captured from the local test rig (`test/docker-compose.yml`,
`ghcr.io/lycheeorg/lychee:v7.7.5`) on 2026-08-27, using the same headers the plugin
sends. These are the ground truth behind the API notes in `../../DEVELOPMENT.md`.

The full OpenAPI 3.1 spec (207 paths) is not vendored — fetch it from a running
instance at <http://localhost:8000/docs/api>. The JSON is embedded in that page
rather than served at `/docs/api.json`, which 404s.

| File | Call |
|---|---|
| `GET_Albums.json` | `GET /Albums` — **root albums only** |
| `GET_Album_head_root.json` | `GET /Album::head` — root album, `parent_id: null` |
| `GET_Album_head_child.json` | `GET /Album::head` — nested album, `parent_id` set |
| `GET_Album_photos_EMPTY.json` | `GET /Album::photos` — empty album |
| `GET_Album_photos_POPULATED.json` | `GET /Album::photos` — one photo |
| `GET_Album_albums_root.json` | `GET /Album::albums` — child albums, `{ data: [...] }` |
| `GET_Photo_albums.json` | `GET /Photo/{id}/albums` — `[{ id, title }]` |
| `POST_Album_root.json` | `POST /Album` — bare unquoted ID, `text/html` |
| `POST_Photo.json` | `POST /Photo` — `UploadMetaResource` with `expected_id` |
| `PATCH_Photo.json` | `PATCH /Photo` — 404 body (id from a deduplicated upload) |
| `POST_Album_updateProtectionPolicy.json` | 201 + resulting policy |

`POST /Album::move` and `DELETE /Album` return 204 with no body, so they have no
sample file.

## Things these samples settle

1. **`Content-Type: application/json` is mandatory on every request**, GETs included.
   Without it: 406 `UnexpectedContentType`. `Accept` alone is not enough.
2. **`Album::head` returns `{ config, resource }`** and carries no `photos` and no
   child albums. `resource.parent_id` is null at root, set when nested, and updates
   after `Album::move`.
3. **`Album::photos` on an empty album returns `{"photos": []}`** — the key is
   present. The plugin's hand-rolled decoder turns that into an empty table, so
   `findPhotoByFilename` does not warn. (An earlier theory that the key was absent
   was wrong for 7.7.5.)
4. **`POST /Album` returns a bare unquoted ID** with `Content-Type: text/html`, so
   `jsonDecode` yields nil and `createAlbum`'s raw-ID fallback is what actually runs.
5. **`POST /Photo` returns `expected_id`** — optimistic only. Lychee deduplicates by
   checksum on the queue worker; re-uploading identical bytes drops the upload and
   the id is never allocated. Confirm it in `Album::photos` before trusting it.
6. **Photos have `original_name: null`**; the filename lands in `title`.
7. **`DELETE /Photo` requires `from_id`** as well as `photo_ids[]` → 422 without it.
8. **`DELETE /Album` cascades** to child albums and their photos, and accepts a JSON
   body even though the spec documents `album_ids[]` as a query parameter.

## Regenerating

The rig has no seeded content. Create an album, upload
a photo, and curl each endpoint with:

```
-H 'Accept: application/json' -H 'Content-Type: application/json' \
-H "Authorization: Bearer $TOKEN"
```
