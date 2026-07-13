# media-storoj

Self-hosted [Immich](https://immich.app) photo/video server, running on a
repurposed laptop instead of a cloud subscription. No public internet exposure —
access is entirely over [Tailscale](https://tailscale.com).

## Start here

- **`runbook.md`** — step-by-step setup guide, from a fresh Ubuntu install
  through Docker, Tailscale, deploying Immich, and importing existing libraries.
  Read the Overview section at the top first for the why behind the design.
- **`docs/`** — deeper notes on how things actually work and what went wrong
  along the way:
  - [`docs/immich-concepts.md`](docs/immich-concepts.md) — the access model,
    how storage/albums actually work on disk, ways to get files into Immich,
    and `immich-go` bulk-import gotchas
  - [`docs/troubleshooting.md`](docs/troubleshooting.md) — real problems hit
    during setup and how they were diagnosed
  - [`docs/server-tuning.md`](docs/server-tuning.md) — memory/concurrency
    tuning after an OOM incident, current job/image-quality settings and why
  - [`docs/maintenance.md`](docs/maintenance.md) — safely detaching the
    storage drive, routine upkeep

## Scripts

### `scripts/backup-sd-card.sh`

Bulk-imports photos/videos from a camera SD card into Immich via
[`immich-go`](https://github.com/simulot/immich-go), with the RAW-file and
junk-thumbnail exclusions, error handling, and concurrency limits already
tuned in (see the script's own header comment, and
[`docs/immich-concepts.md`](docs/immich-concepts.md) for why each flag is there).

Requires:
- `immich-go` installed at `~/.local/bin/immich-go`
  ([releases](https://github.com/simulot/immich-go/releases))
- an Immich API key saved in a `.env` file at the repo root (gitignored):
  ```
  API_key='your-api-key-here'
  ```
  Generate one in Immich: profile icon → Account Settings → API Keys → New API Key.

**Examples:**

```bash
# Auto-detect the card by label (defaults to a card labeled "Sony",
# mounted at /run/media/$USER/Sony) and import with the built-in defaults
scripts/backup-sd-card.sh

# Explicit path instead of auto-detection
scripts/backup-sd-card.sh /run/media/$USER/EOS_DIGITAL

# Different camera/card label, same script, no editing required
SD_CARD_LABEL=Canon5D scripts/backup-sd-card.sh

# Talking to a remote Immich server instead of localhost
IMMICH_SERVER=http://<laptop-hostname>:2283 scripts/backup-sd-card.sh

# Raise concurrency back up (e.g. on a machine with more RAM than 7GB)
CONCURRENT_TASKS=8 scripts/backup-sd-card.sh

# Keep RAW files instead of skipping them, by passing your own flags through
# (anything after the path is passed straight to immich-go, overriding the
# script's defaults)
scripts/backup-sd-card.sh /path/to/card --include-extensions .ARW,.jpg
```

If no path is given and nothing is mounted at the expected label, the script
prints what's actually mounted under `/run/media/$USER/` instead of failing silently.
