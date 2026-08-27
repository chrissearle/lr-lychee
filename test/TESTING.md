# LrLychee Plugin — Manual Test Plan

Run these tests against a real Lychee 7.5+ instance with the plugin loaded in Lightroom Classic.
Each test lists what to do in Lightroom and what to verify in the Lychee web UI (and vice versa).
After each publish operation, **refresh the Lychee page** before verifying.

---

## 0. Prerequisites

### Local test rig

```
docker compose -f test/docker-compose.yml up -d
```

Brings up Lychee **v7.7.5** (pinned) plus a queue worker and MariaDB on
<http://localhost:8000>. State lives in the `lychee_prod_mysql` volume and the
`test/lychee/` bind mounts; delete both for a clean slate.

First run only — create the admin user (there is no seeded account):

```
docker exec lychee-api php artisan lychee:create_user admin <password>
```

Then generate an API token in Lychee under **Edit My User** and paste it, with
`http://localhost:8000`, into the Lightroom publish service.

Lychee's own logs are bind-mounted into `test/lychee/logs/` (`errors.log`,
`daily-*.log`, `jobs-*.log`) — check these when a call fails server-side rather than
in Lua. The plugin log is at
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/LycheePlugin.log`.

The API is self-documenting at <http://localhost:8000/docs/api>; captured responses
for every endpoint the plugin uses are in `test/api-samples/`.

### Lightroom

- Plugin installed and Lightroom restarted
- Publish service configured with a valid Gallery URL and API token
- Test library of at least 5–10 photos with varied titles/captions
- Lychee instance accessible in a browser

> **Note on duplicates:** Lychee deduplicates photos by checksum. Uploading the same
> image bytes twice is silently dropped rather than creating a second photo. Use
> genuinely distinct images when a test calls for multiple photos.

---

## 1. Publish Service Setup

| # | Action | Expected result |
|---|--------|----------------|
| 1.1 | Open Publish Service settings with blank Gallery URL | Validation error shown, cannot save |
| 1.2 | Open Publish Service settings with blank API token | Validation error shown, cannot save |
| 1.3 | Configure valid Gallery URL and token, click Test | Success response shown |
| 1.4 | Configure invalid token, click Test | Error shown |

---

## 2. Collection (Album) — Create & First Publish

| # | Action | Expected result |
|---|--------|----------------|
| 2.1 | Create new Published Collection "Test Album A" | No album created in Lychee yet (album created on first publish) |
| 2.2 | Add 3 photos to "Test Album A", publish | Album "Test Album A" appears in Lychee at root level with 3 photos |
| 2.3 | After publish: check LR collection panel | Collection shows a clickable Published Album URL |
| 2.4 | After publish: check published photos in LR | Each photo shows a Published Photo URL |
| 2.5 | Click the Published Album URL | Opens correct Lychee album page in browser |

---

## 3. Photo Publishing — Re-publish Scenarios

| # | Action | Expected result |
|---|--------|----------------|
| 3.1 | Edit one of the published photos in Develop module, publish | Photo is replaced in Lychee (same album), same photo ID or new one, URL updated |
| 3.2 | Change title/caption of a published photo (no develop edit), publish | Photo is NOT re-uploaded; only metadata updated in Lychee. Photo count unchanged |
| 3.3 | Publish the same collection again with no changes | Nothing changes in Lychee; no errors |
| 3.4 | Add a 4th photo to the collection, publish | Only the new photo is uploaded; existing 3 are untouched |
| 3.5 | Remove one photo from the collection (Remove from Published Collection) | Photo is deleted from Lychee album |

---

## 4. Album Settings

For each test: open Edit Collection dialog → set value → click OK → publish (if not yet published) or trigger re-apply.

| # | Setting | Action | Expected result |
|---|---------|--------|----------------|
| 4.1 | Description | Set "My test description" | Lychee album shows description |
| 4.2 | License | Set to "CC BY" | Lychee album license updated |
| 4.3 | Copyright | Set "© Test" | Lychee album copyright updated |
| 4.4 | Photo sort | Set "Upload date, Ascending" | Photos in Lychee sorted accordingly |
| 4.5 | Album sort | Set "Title, Ascending" | Sub-albums sorted accordingly (visible in Lychee) |
| 4.6 | Photo layout | Set "Masonry" | Lychee album layout updated |
| 4.7 | Visibility — Public | Set Public = on | Album accessible without login in Lychee |
| 4.8 | Visibility — Private | Set Public = off | Album requires login to view |
| 4.9 | Visibility — NSFW | Set NSFW = on | Album flagged as NSFW in Lychee |
| 4.10 | Visibility — Password | Set password required + password | Lychee album requires password to view |
| 4.11 | Header photo | Select a photo from dropdown | Lychee album shows selected header photo |
| 4.12 | Header compact | Select "Use compact header" | Lychee album shows compact header |
| 4.13 | Settings on **new** album | Set settings before first publish | Settings applied automatically on first publish (not lost) |
| 4.14 | Settings on **existing** album | Change settings after album exists | Settings applied immediately when clicking OK (no re-publish needed) |

---

## 5. Album Rename & Delete

| # | Action | Expected result |
|---|--------|----------------|
| 5.1 | Right-click collection → Rename to "Test Album A Renamed" | Lychee album title updates to "Test Album A Renamed" |
| 5.2 | Right-click collection → Delete Published Collection, confirm | Album and all its photos deleted from Lychee |
| 5.3 | Delete collection, cancel at confirmation | Nothing deleted in Lychee |

---

## 6. Collection Sets (Nested Albums)

| # | Action | Expected result |
|---|--------|----------------|
| 6.1 | Create Published Collection Set "Parent Set" | Album "Parent Set" created in Lychee at root level |
| 6.2 | Create Published Collection "Child Album" inside "Parent Set" | Album "Child Album" created in Lychee nested under "Parent Set" |
| 6.3 | Add photos to "Child Album", publish | Photos appear in the nested Lychee album |
| 6.4 | Published Album URL for "Child Album" | URL points to the nested album (not the root) |
| 6.5 | Create a second level: Set → Set → Collection | Three-level nesting works correctly in Lychee |
| 6.6 | Rename "Parent Set" | Lychee album renamed, children unaffected |
| 6.7 | Delete "Parent Set" (confirm) | Parent album and all children (albums + photos) deleted from Lychee |
| 6.8 | Open Edit Collection Set dialog | Album settings panel shows and loads existing settings from Lychee |

---

## 7. Moving Albums (Drag & Drop)

| # | Action | Expected result |
|---|--------|----------------|
| 7.1 | Drag "Test Album A" (at root) into "Parent Set" | On next publish, album moves to be nested under "Parent Set" in Lychee |
| 7.2 | Drag "Child Album" out of set to root level | On next publish, album moves to root in Lychee |
| 7.3 | Move album into a different set | On next publish, album appears under the new parent in Lychee |
| 7.4 | Verify photos are preserved after a move | All photos still present in album after move |

---

## 8. Duplicate / Edge Cases

| # | Action | Expected result |
|---|--------|----------------|
| 8.1 | Publish a collection where the album already exists in Lychee (remoteId lost, e.g. fresh LR catalog) | Plugin finds existing album by name and re-uses it; no duplicate created |
| 8.2 | Publish collection with 0 photos | No error; album is created/found but empty |
| 8.3 | Two collections with the same name in different sets | Each publishes to its own correctly-scoped album in Lychee |
| 8.4 | Re-publish a photo that was manually deleted from Lychee | Photo is re-uploaded cleanly; no error dialog |
| 8.5 | Upload photo with special characters in filename | Photo uploads and URL is correct |
| 8.6 | Publish with gallery_url that has a trailing slash | URL in LR and links in Lychee still correct (no double slash) |

---

## 9. Photo Deletion

| # | Action | Expected result |
|---|--------|----------------|
| 9.1 | Select published photos → right-click → Remove from Published Collection | Confirmation shown (if LR prompts); photos deleted from Lychee |
| 9.2 | Delete album that still has photos | All photos deleted from Lychee along with the album |

---

## 10. Regression — Previously Reported Bugs

| # | Bug | Test | Expected result |
|---|-----|------|----------------|
| R1 | Settings lost on first publish | Set album settings before first publish, publish | Settings applied (not default/blank) |
| R2 | `knownPhotoIds` always empty → re-upload loop | Re-publish an existing album with 5 photos, no edits | 0 photos re-uploaded; no delete+reupload in Lychee |
| R3 | Published photo URL missing after re-publish | Re-publish an unedited collection | All photos retain their Published Photo URL in LR |
| R4 | Published album URL missing | Publish a new collection | Collection shows Published Album URL in LR panel immediately after publish |
| R5 | Album URL for old-code albums | Albums published before the nested-album feature was added | Still show correct Published Album URL |

---

## Checklist Summary

Before shipping a release, all of the following should pass:

- [ ] First publish of a root collection
- [ ] First publish of a nested collection (inside a set)  
- [ ] Re-publish with no changes (no re-upload, no errors)
- [ ] Re-publish after image edit (photo replaced in Lychee)
- [ ] Re-publish after metadata-only change (metadata updated, no upload)
- [ ] Album settings applied on first publish of new album
- [ ] Album settings updated on existing album without re-publish
- [ ] Collection renamed → Lychee album renamed
- [ ] Collection deleted → Lychee album deleted
- [ ] Collection set created → Lychee nested album created
- [ ] Collection dragged into set → album moves in Lychee on next publish
- [ ] Published Album URL shown after publish
- [ ] Published Photo URL shown after publish
- [ ] No duplicate albums created on second publish
- [ ] Deleting a photo from LR removes it from Lychee
