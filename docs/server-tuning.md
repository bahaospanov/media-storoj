# Server resource tuning

This laptop has only **7.1GB RAM** and runs both a live GNOME desktop session and
the Immich Docker stack. That combination has actually caused a full host crash
once already — see below. These are the current tuned settings and why; don't
treat the numbers as arbitrary if you see them again later.

## Incident: OOM crash during first big SD card import (2026-07-13)

Right after a 1115-asset SD card import finished, all of `immich-go`'s paused
background jobs (thumbnail generation, video transcoding for 54 clips, face
detection, smart search embeddings) resumed simultaneously against the full
backlog. Combined with the desktop session already running, this exceeded
available RAM + swap. The kernel's OOM killer started repeatedly killing
`org.gnome.Shell`, `dbus`, `wireplumber`, and other session processes (forcing
re-logins), and eventually the whole machine became unresponsive and needed a
hard reboot.

Diagnosed via:
```bash
journalctl -b -1 | grep -iE "out of memory|oom.kill|killed process"
```

Side effect: Redis (which holds the in-flight BullMQ job queue in memory, no
persistence configured) lost all queued jobs on the crash/restart. Any asset
mid-processing when it hit had to be found and re-queued manually — checked via:
```bash
docker exec immich_postgres psql -U postgres -d immich -c "
SELECT (SELECT count(*) FROM asset) as total,
       (SELECT count(DISTINCT \"assetId\") FROM asset_file WHERE type='thumbnail') as with_thumbnail;"
```
Any gap between those two numbers means assets exist whose jobs vanished from
the queue — re-trigger with `{"command":"start","force":false}` against the
relevant job (see below), which processes only what's missing, not everything.

## Fixes applied (current state, as of 2026-07-13)

**1. Immich job concurrency** — lowered via `PUT /api/system-config` (`job` key).
Fewer parallel jobs = lower peak memory during a big batch, at the cost of
slower processing:

| Job | Before | Now |
|---|---|---|
| thumbnailGeneration | 3 | 2 |
| metadataExtraction | 5 | 3 |
| faceDetection | 2 | 1 |
| smartSearch | 2 | 1 |
| videoConversion | 1 | 1 (already minimum) |

**2. Docker container memory limits** — tightened in `~/immich/docker-compose.yml`
(`deploy.resources.limits.memory` — this IS enforced locally by Compose v2/the Go
CLI even outside swarm mode, confirmed via `docker inspect <container>
--format '{{.HostConfig.Memory}}'`):

| Container | Before | Now |
|---|---|---|
| immich-server | 2g | 1.5g |
| immich-machine-learning | 1.5g | 1.2g |
| redis | 256m | 256m (unchanged, already lean) |
| postgres | 1g | 1g (unchanged, already lean) |

Total container budget: ~4.75GB → ~3.96GB, freeing headroom for the desktop
session. Apply changes to the compose file with `cd ~/immich && docker compose
up -d` (recreates only the containers whose config changed).

**3. Swap**: doubled from 4GB to 8GB (swapfile at `/swap.img`):
```bash
sudo swapoff /swap.img && sudo fallocate -l 8G /swap.img && sudo chmod 600 /swap.img \
  && sudo mkswap /swap.img && sudo swapon /swap.img && swapon --show
```

None of this fixes the underlying tension (one 7GB machine, two demanding roles)
— it just raises the threshold. A repeat is still possible on an even bigger
batch. If it recurs, the next lever is running big jobs while **not** logged
into the desktop session at all (manage purely over SSH from the Mac, which the
runbook's step 7 already set up for exactly this reason).

## Verified this actually works

Re-ran a full-backlog reprocess afterward (regenerating all 1115 previews at
higher quality, see below) with these settings in place — available memory
never dropped below ~2.9GB the whole time, no OOM. A separate full ML pass
(face detection + recognition + smart search + duplicate detection) afterward
also stayed healthy throughout (available memory bottomed out around 2.9GB).

## Image quality settings (current)

Also tuned via `PUT /api/system-config` (`image` key) — unrelated to the OOM
fix, just recorded here since it's the same API:

| Setting | Before | Now |
|---|---|---|
| preview.size | 1440px | 2048px |
| preview.quality | 80 | 90 |
| thumbnail (grid) | 250px / webp / q80 | unchanged |

`preview` is what you see 95% of the time when opening a photo in the app (not
the tiny grid thumbnail). Changing this only affects new uploads — existing
assets need a forced regeneration to pick up the new settings:
```bash
curl -X PUT "http://localhost:2283/api/jobs/thumbnailGeneration" \
  -H "x-api-key: $API_KEY" -H "Content-Type: application/json" \
  -d '{"command":"start","force":true}'
```
`force:true` reprocesses everything (used when a *setting* changed); `force:false`
processes only assets missing that job's output (used to catch stragglers after
a crash, like the Redis job-loss case above).

## Useful API patterns discovered

- **View/edit any server setting**: `GET /api/system-config` returns the full
  config as JSON; `PUT /api/system-config` with the *entire* modified object
  (not a partial patch) applies changes immediately, no restart needed.
- **Job queue status**: `GET /api/jobs` returns `active`/`waiting`/`completed`
  counts per job type. Note the `completed` counter doesn't reliably accumulate
  (BullMQ prunes completed job records) — track progress via the `waiting`
  count dropping instead.
- **Bulk delete assets**: see the immich-go gotchas section in
  `docs/immich-concepts.md` for the delete-by-checksum-window pattern.
