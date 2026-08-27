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

### Test images

The repo ships six deliberately distinct images in `test/images/`. **Import that
whole folder into Lightroom before starting.** Every test below names the exact
images to use — the assignments are not arbitrary, because photo state carries
between sections (an image removed in §3 is reused in §6).

| Short name | File | Reserved for |
|---|---|---|
| **Sunset** | `LycheeTest-01-Sunset.jpg` | Test Album A; develop-edit in 3.1 |
| **Ocean** | `LycheeTest-02-Ocean.jpg` | Test Album A; metadata-only change in 3.2 |
| **Forest** | `LycheeTest-03-Forest.jpg` | Test Album A until 3.5, then free for §6 |
| **Rings** | `LycheeTest-04-Rings.jpg` | Added in 3.4; header photo in 4.11 |
| **Checks** | `LycheeTest-05-Checks.jpg` | Throwaway album for rename/delete (§5) |
| **Tromsø** | `Tromsø Café (2).jpg` | Child Album (§6) — non-ASCII, space, parens |

> **Duplicates behave specifically — verified against 7.7.5.** Lychee deduplicates by
> **checksum** (byte-identical only, not perceptual):
>
> - Same bytes uploaded **to the same album** → silently dropped, no second photo.
> - Same bytes uploaded **to a different album** → **one shared photo row** linked to
>   both albums, with the *same* photo ID.
>
> In practice you will rarely see the shared case when publishing from Lightroom:
> Lightroom embeds title and caption into the exported JPEG, and a metadata-only
> update PATCHes Lychee's database without rewriting the stored file — so the next
> export of the "same" photo has different bytes and becomes a separate row.
>
> Sharing is still possible, which is why removing a photo from one album must send
> `from_id`: otherwise there is no way to say "remove it from *this* album only".
>
> Never substitute copies of one file for "several photos" — §3.4 would look broken.

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

Creates **Test Album A**, the album most later sections build on.

| # | Action | Images | Expected result |
|---|--------|--------|----------------|
| 2.1 | Create Published Collection "Test Album A" | — | No album created in Lychee yet (created on first publish) |
| 2.2 | Add 3 photos, publish | **Sunset, Ocean, Forest** | Album "Test Album A" appears at Lychee root with exactly those 3 |
| 2.3 | Right-click the collection → **Go to Published Collection** | — | Opens `/gallery/<album>`. A Published Album URL is also shown in the collection panel |
| 2.4 | Right-click a published photo → **Go to Published Photo** | — | Browser opens `/gallery/<album>/<photo>` for that photo. **Lightroom shows no photo URL as text** — the menu action is the only surface, so do not look in the Metadata panel |
| 2.5 | Click the Published Album URL | — | Opens the correct Lychee album |

**State after §2:** Test Album A = Sunset, Ocean, Forest.

---

## 3. Photo Publishing — Re-publish Scenarios

All on **Test Album A**. Run in order — 3.4 and 3.5 change the contents.

| # | Action | Images | Expected result |
|---|--------|--------|----------------|
| 3.1 | Develop-edit (e.g. crop or −1 exposure), publish | **Sunset** | Sunset replaced in Lychee; others untouched; URL updated |
| 3.2 | Change title *and* caption, no develop edit, publish | **Ocean** | Not re-uploaded; metadata updated in Lychee; photo count still 3 |
| 3.3 | Publish again with no changes | — | Nothing changes; no errors; **0 uploads** |
| 3.4 | Add a 4th photo, publish | **Rings** | Only Rings uploads; Sunset/Ocean/Forest untouched |
| 3.5 | Remove from Published Collection | **Forest** | Forest deleted from the Lychee album; 3 remain |

**State after §3:** Test Album A = Sunset, Ocean, Rings. **Forest is now free.**

---

## 4. Album Settings

All on **Test Album A**. Open Edit Collection → set value → OK → publish if not yet published.

| # | Setting | Action | Expected result |
|---|---------|--------|----------------|
| 4.1 | Description | Set "My test description" | Lychee album shows description |
| 4.2 | License | Set to "CC BY" | Lychee album license updated |
| 4.3 | Copyright | Set "© Test" | Lychee album copyright updated |
| 4.4 | Photo sort | "Created at, Ascending" | Photos sorted accordingly. (There is no "Upload date" — Lychee calls it `created_at`) |
| 4.5 | Album sort | "Title, Ascending" | Sub-albums sorted accordingly (only visible once §6 creates sub-albums) |
| 4.6 | Photo layout | "Masonry" | Layout updated |
| 4.7 | Visibility — Public | Public = on | Accessible without login |
| 4.8 | Visibility — Private | Public = off | Requires login |
| 4.9 | Visibility — NSFW | NSFW = on | Flagged NSFW |
| 4.10 | Visibility — Password | **Set Public = on first** (4.8 turned it off), then password required + password `testpass` | Album requires the password to view. A private album is unreachable by link, so password protection only means anything on a public album |
| 4.11 | Header photo | Select **Rings** from the dropdown | Lychee album shows Rings as header. Dropdown must list all 3 current photos |
| 4.12 | Header compact | Select "Use compact header" | Compact header shown |
| 4.13 | Settings on **new** album | Create "Test Album Settings" with description + Public **before** first publish, add **Ocean**, publish | Settings applied on first publish, not lost (see R1) |
| 4.14 | Settings on **existing** album | Change description on Test Album A | Applied immediately on OK, no re-publish needed |

> 4.13 puts Ocean in a second album. Expect a **separate photo ID** from Test Album A's
> copy — see the duplicates note in §0: Lightroom embeds metadata in the export, so the
> bytes differ and checksum dedup does not trigger.

---

## 5. Album Rename & Delete

Uses a **throwaway** collection so Test Album A survives for §7.

| # | Action | Images | Expected result |
|---|--------|--------|----------------|
| 5.1 | Create "Test Album Doomed", add 1 photo, publish | **Checks** | Album created with Checks |
| 5.2 | Right-click → Rename to "Test Album Doomed Renamed" | — | Lychee album title updates |
| 5.3 | Right-click → Delete Published Collection, **cancel** | — | Nothing deleted in Lychee |
| 5.4 | Right-click → Delete Published Collection, **confirm** | — | Album and Checks deleted from Lychee |

**State after §5:** Doomed album gone. **Checks is free again.**

---

## 6. Collection Sets (Nested Albums)

| # | Action | Images | Expected result |
|---|--------|--------|----------------|
| 6.1 | Create Published Collection Set "Parent Set" | — | **Nothing in Lychee yet.** A set's album is created lazily — `ensureAncestorAlbums` makes it when a child collection first publishes. Log shows `Stored pending settings in prefs for set "Parent Set"` |
| 6.2 | Create Published Collection "Child Album" inside "Parent Set" | — | "Child Album" created nested under "Parent Set" |
| 6.3 | Add 1 photo to Child Album, publish | **Tromsø** | Photo appears in the nested album. **Also covers 8.5** (non-ASCII + space + parens) |
| 6.4 | Check Child Album's Published Album URL | — | Points at the nested album, not the root |
| 6.5 | Create Set → Set → Collection: "Parent Set" › "Inner Set" › "Deep Album", add 1 photo, publish | **Forest** (freed in 3.5) | Three-level nesting correct in Lychee |
| 6.6 | Rename "Parent Set" to "Parent Set Renamed", then **Mark to Republish** a photo in a collection under it and publish | — | Lightroom never notifies a plugin that a collection *set* was renamed, so it syncs during the next publish of a descendant. A publish with nothing to do does **not** call `processRenderedPhotos`, so it will not sync — Mark to Republish first. Log: `Set name check: ...` then `Collection set renamed in Lightroom: "..." -> "..."`. Children unaffected |
| 6.7 | Open the Edit Collection Set dialog, set a description and licence | — | Panel loads existing settings from Lychee (set equivalent of 4.11), and the new values apply to **the set's own album only — not recursively to child albums**. That is intended: each Lychee album owns its settings, and cascading would clobber deliberate per-album values. **Run before the delete below — that destroys the set** |
| 6.8 | **Do this last, after §7.** Delete "Parent Set Renamed", confirm | — | **Known limitation — nothing is deleted in Lychee.** The set, its child sets, child albums and every photo remain in the gallery. Lightroom has no set-delete callback, and deleting a set does not raise the per-collection delete dialog, so `deletePublishedCollection` never fires for the children either. Clean up by hand |

---

## 7. Moving Albums (Drag & Drop)

Run **before 6.7**, which destroys the set. Test Album A = Sunset, Ocean, Rings.

| # | Action | Images | Expected result |
|---|--------|--------|----------------|
| 7.1 | Drag "Test Album A" (root) into "Parent Set Renamed", publish | — | Album moves to nest under the set in Lychee |
| 7.2 | Drag "Child Album" out of the set to root, publish | — | Child Album moves to root |
| 7.3 | Drag "Test Album A" into "Inner Set", publish | — | Appears under the new parent |
| 7.4 | Verify contents after the moves | **Sunset, Ocean, Rings** | All 3 still present, same photo IDs, no re-upload |

---

## 8. Duplicate / Edge Cases

| # | Action | Images | Expected result |
|---|--------|--------|----------------|
| 8.1 | Publish a collection whose album exists in Lychee but whose remoteId LR has lost | **Sunset** | Plugin finds the album by name and reuses it; no duplicate created |
| 8.2 | Create "Test Album Empty" with no photos | none | **Not reachable — mark N/A.** With `supportsIncrementalPublish = 'only'` an empty collection has nothing to publish, so Lightroom offers no publish action and `processRenderedPhotos` never runs. No Lychee album is created, same as an empty collection set (6.1). Verify only that nothing errors |
| 8.3 | Two collections both named "Dupe" — one at root, one inside a set | root: **Ocean** · set: **Sunset** | Each publishes to its own correctly-scoped album, each with its own photo row |
| 8.4 | Delete a photo manually in the Lychee UI, then re-publish | **Ocean** in Test Album A | Re-uploaded cleanly, no error dialog |
| 8.5 | Special characters in filename | **Tromsø** | Covered by 6.3 — upload succeeds and URL is correct |
| 8.6 | Set gallery_url with a trailing slash, publish | — | URLs correct, no double slash |

---

## 9. Photo Deletion

| # | Action | Images | Expected result |
|---|--------|--------|----------------|
| 9.1 | Select → right-click → Remove from Published Collection | **Rings** in Test Album A | Rings deleted from that Lychee album only; Sunset and Ocean remain |
| 9.2 | Delete a published collection that still has photos, choosing **Delete** in Lightroom's dialog | any published collection | Album and its photos deleted from Lychee. Log: `Deleted album for collection "..."` |
| 9.3 | Same, but choose **leave the photos in their published location** | any published collection | **Album and photos remain in Lychee, by design.** `deletePublishedCollection` is not called at all — nothing is logged. The collection disappears from Lightroom only |

> 9.2 is the direct test of the `from_id` fix. Before it, removing a photo returned
> **422 "The from id field is required."** on Lychee 7.7+.

---

## 10. Regression — Previously Reported Bugs

| # | Bug | Test | Images | Expected result |
|---|-----|------|--------|----------------|
| R1 | Settings lost on first publish | Covered by 4.13 | **Ocean** | Description and Public applied, not blank |
| R2 | `knownPhotoIds` always empty → re-upload loop | Re-publish Test Album A unchanged | **Sunset, Ocean, Rings** | Log: `Starting uploads with 3 known photo IDs`; **0 uploaded** |
| R3 | Published photo URL missing after re-publish | Re-publish unchanged, then right-click each photo → Go to Published Photo | same 3 | Each still opens its own correct photo page (no URL is displayed as text — see 2.4) |
| R4 | **Published album URL missing** | Publish a brand-new collection "Test Album R4" with 1 photo | **Checks** (freed in §5) | URL shown in the LR panel immediately. Log: `Stored remoteId <id> and URL <url> on collection "Test Album R4"` |
| R5 | Album URL for old-code albums | Any album published before the nested-album work | — | Still shows a correct Published Album URL |

> **R4 is the current blocker.** It is the one thing the code fix has not yet been
> observed doing in Lightroom. Run it early.

---

## Suggested Order

State carries between sections, so run: **§1 → §2 → §3 → §10 (R2–R4) → §4 → §5 → §6.1–6.7 → §7 → §6.8 → §8 → §9**.

§10 goes early because R2–R4 are the previously-reported bugs — a failure there stops
the sweep. The set delete is deferred to last because it destroys the set that §7
needs and that 6.7 inspects — and because nothing in Lychee survives it to inspect
afterwards.

---

## Checklist Summary

- [ ] First publish of a root collection (2.2)
- [ ] First publish of a nested collection (6.3)
- [ ] Re-publish with no changes — no re-upload, no errors (3.3, R2)
- [ ] Re-publish after image edit — photo replaced (3.1)
- [ ] Re-publish after metadata-only change — no upload (3.2)
- [ ] Album settings applied on first publish of a new album (4.13, R1)
- [ ] Album settings updated on existing album without re-publish (4.14)
- [ ] Collection renamed → Lychee album renamed (5.2)
- [ ] Collection deleted → Lychee album deleted (5.4)
- [ ] Collection set created → nested Lychee album (6.1, 6.2)
- [ ] Three-level nesting (6.5)
- [ ] Collection dragged into a set → album moves (7.1)
- [ ] Photos preserved across a move (7.4)
- [ ] **Published Album URL shown after publish (2.3, R4)**
- [ ] Published Photo URL shown after publish (2.4, R3)
- [ ] No duplicate albums on second publish (8.1)
- [ ] Removing a photo in LR removes it from that Lychee album (9.1)
- [ ] Deleting a collection removes its Lychee album (9.2), and "leave photos" keeps it (9.3)
- [ ] Special characters in filename (6.3 / 8.5)
