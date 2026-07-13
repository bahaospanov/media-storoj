# How Immich actually works (concepts)

Notes on the mental model behind this deployment — useful for future decisions about
importing, organizing, or troubleshooting, without re-deriving it from scratch.

## Access is Tailscale-only, not the public internet

Immich is never exposed to the internet — it only listens on the laptop's local
network and Tailscale's private overlay network (`100.x.x.x` addresses). No port
forwarding, no public HTTPS cert, no internet-facing attack surface.

The tradeoff: every device that wants to reach it (phone, Mac, wife's phone) must
have Tailscale installed *and connected* to the same tailnet. No Tailscale
connection = no path to the server at all, by design. See
`docs/troubleshooting.md` for the "server not reachable" checklist this implies.

## Wife's account: Tailscale vs Immich are opposite

- **Tailscale: same account.** She logs into the Tailscale app with the household's
  existing login (Google/GitHub) — that's what lets her device join the tailnet and
  reach `<laptop-hostname>:2283` at all.
- **Immich: separate account.** Admin creates her a distinct user (Administration →
  Users → New User, email + temporary password). She logs into the *Immich app*
  with those credentials, not the admin's.

Result: her library and the admin's library are private from each other inside
Immich (separate, even though both run off the same server/drive). Admin can manage
her account but can't casually browse her library through the normal UI.

## Drive layout: `immich/` is managed, everything else is yours

`/mnt/media` is a general-purpose drive, not Immich-exclusive. Immich only owns its
own subfolder:

```
/mnt/media/
  immich/     <- hands-off, Immich-managed (see storage layout below)
  ...         <- anything else you want to store, entirely your own organization
```

**Rule: never manually drop or reorganize files inside `immich/`.** Immich's
database tracks exact file paths; manual changes there can break references.
Anything you want *in* Immich should go through actual ingestion (phone backup, web
upload, or `immich-go` — see below), not a manual file copy.

`~/immich` (home directory, not `/mnt/media/immich`) is a **different, much smaller
thing**: just the Docker Compose deployment folder (`docker-compose.yml` + `.env`).
It configures and runs the containers; it holds no photo/video data itself. Used for
commands like `cd ~/immich && docker compose logs -f` or version upgrades.

## How uploaded files get physically stored on disk

Immich does **not** preserve your source folder structure. Every uploaded file
(regardless of upload method) gets re-filed under `UPLOAD_LOCATION` using the
**Storage Template** configured in Administration → Settings (this deployment uses
the default `{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}`):

```
/mnt/media/immich/library/<user-id>/{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}
```

The date used is the photo/video's **actual taken-date from EXIF metadata**, not
upload date or original folder name. A photo from an old archive folder and a phone
photo from the same week end up in the exact same `2019/2019-06-12/` folder on
disk — the archive's original folder names (e.g. `Videos/2019-trip/`) don't survive
on disk at all.

**Albums, people, favorites — none of that lives in the folder structure.** They're
rows in the Postgres database (`immich_postgres` container): a many-to-many
relationship between assets and albums/people/tags. A single physical file can
belong to multiple albums or be tagged with multiple people, none of which changes
where it sits on disk. This means: don't try to replicate a folder-based
organization system — do all actual organizing (albums, tags, favorites, search)
inside the Immich UI/database, not the filesystem.

## Ways to get files into Immich

1. **Mobile app auto-backup** — already set up (runbook step 10). Automatic,
   background, no manual action needed once configured.
2. **Web UI upload** — drag-and-drop or the upload button at
   `http://<laptop-hostname>:2283`.
   Fine for occasional individual files.
3. **`immich-go` bulk import** — for importing an existing folder of files (old
   backups, Google Takeout exports). See below.
4. **External Library** (Administration → Libraries → Create Library) — points
   Immich at an existing folder path and indexes it **in place**, without copying.
   Saves disk space vs. `immich-go` (which copies into Immich's managed storage),
   but keeps the files in their original folder layout rather than Immich's.

## What `immich-go` actually does

A third-party CLI (github.com/simulot/immich-go) for bulk-importing into Immich.
Talks to the server over its normal REST API (`--server` + `--api-key`, the latter
generated in Immich: profile icon → Account Settings → API Keys → New API Key) — not
touching the database or disk directly, safe to run against a live server.

1. **Walks the source folder recursively**, finding supported media (JPEG/HEIC/PNG/
   RAW, MP4/MOV, paired Live Photos).
2. **Extracts real metadata per file**: for a plain folder, reads EXIF directly
   (actual date taken, GPS, camera) rather than trusting filesystem mtime. For a
   Google Takeout export specifically, it instead reads the accompanying `.json`
   sidecar files, since Takeout scrambles real EXIF dates.
3. **Deduplicates before uploading**: hashes each file and asks Immich's API
   whether that checksum already exists before sending bytes — anything the phone
   already auto-backed up gets skipped, not duplicated.
4. **Optionally recreates folder structure as albums** — subfolder names become
   Immich albums (a database relationship, not a disk mirror — see above).
5. **Live progress + summary** of uploaded / skipped-as-duplicate / failed. Supports
   `--dry-run` to preview without uploading anything.

Runs fast when source and server are on the same machine (localhost, disk-bound not
network-bound). Command shape:

```bash
immich-go upload from-folder --server http://localhost:2283 --api-key <KEY> /path/to/folder
```

For a repeatable version of this with all the fixes below already baked in, use
`scripts/backup-sd-card.sh <path-to-card>`.

### Gotchas found running this against a real camera SD card (v0.32.0)

- **`--exclude-extensions .ARW` silently does not work** — files get uploaded
  anyway despite the flag being read correctly (confirmed via `--api-trace`/log
  showing the flag set, yet excluded-extension files still appear as "uploaded
  successfully"). Use **`--ban-file '*.ARW'`** instead — a different code path
  that actually excludes at discovery time (confirmed via log showing "discovered
  banned file"). Same applies to any other extension you want to skip.
- **Camera internal thumbnail folders aren't banned by default.** Sony cameras
  keep tiny (~170KB) auto-generated preview JPEGs for video clips under
  `PRIVATE/M4ROOT/THMBNL/` — these get imported as if they were real photos
  unless explicitly excluded: `--ban-file 'THMBNL/'`.
- **`--on-errors` defaults to `stop`**, meaning a single transient error (e.g. one
  server timeout under memory pressure) aborts the *entire remaining batch*,
  not just that one file. Always pass `--on-errors continue` for a large import.
- **If a run gets interrupted** (killed, machine crash, session teardown) and you
  rerun it, expect a slow "server has duplicate" / "metadata updated" pass
  through everything already uploaded before it reaches new files — this is
  `immich-go` re-verifying checksums against the server, not a bug, just slow
  serialized re-checking. It cannot resume from where it left off in a smarter way.
- **Always launch with `nohup ... &> log.out & disown`**, not a bare `&`. A plain
  backgrounded `&` job can get SIGHUP'd and die silently the moment the shell
  that launched it exits — which happens routinely when each command runs in its
  own short-lived shell invocation (e.g. driven by a coding agent, one Bash call
  per command). `nohup` + `disown` survives that.
- **To undo an import mistake** (wrong files uploaded, need to redo with
  different flags): find the asset IDs by `createdAt` timestamp window or
  `originalFileName` pattern in Postgres, then bulk-delete via the API —
  `DELETE /api/assets` with `{"ids": [...], "force": true}` (HTTP 204 on
  success). `force: true` actually purges the files, not just trash. Cheaper and
  more reliable than trying to filter what to (re-)upload.

## Fixing an incorrect photo date

Two approaches depending on timing:

- **After upload, in Immich**: open the photo → info panel → edit the **Date &
  time** field (pencil icon). Can also bulk-select multiple photos and bulk-edit
  date/time at once — useful for a whole batch with the same systematic date
  problem (e.g. a scanned album). Note: this updates Immich's database record (what
  drives the timeline/search), but the **physical file stays in its original
  date-folder on disk** unless you also run the Storage Template Migration job
  (Administration → Jobs) afterward.
- **Before upload, on the raw file**: `exiftool
  "-DateTimeOriginal=2015:06:12 14:30:00" file.jpg` bakes the correct date directly
  into the file's EXIF, permanently, before Immich ever sees it. Preferable for a
  known batch of systematically-wrong dates — no Immich-side edit needed afterward.
