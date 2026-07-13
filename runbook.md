# Immich home server — step-by-step runbook

Copy/paste guide for executing the plan at `~/.claude/plans/i-have-a-lot-fancy-sutton.md`.
Run everything on the **laptop**, not on your Mac, unless noted.

## Overview

**Goal:** stop paying for iCloud/Google Photos and self-host a private, permanent
family photo/video library instead — own the data, own the storage, no
subscription, no vendor lock-in.

**Architecture, and why each piece:**
- **This laptop, repurposed as an always-on server** (dual-boot preserved, Windows
  kept as fallback rather than wiped) — cheapest path to an always-on Linux box, no
  new hardware needed to start.
- **Immich** — self-hosted, open-source, mobile auto-backup + face recognition + a
  Google-Photos-style timeline, actively maintained, no recurring cost.
- **A single external 4TB HDD**, general-purpose rather than Immich-exclusive
  (Immich gets one subfolder, not the whole drive) — the cheap first step before a
  second drive for redundancy.
- **Tailscale as the only access path — no public internet exposure.** No port
  forwarding, no HTTPS cert to manage, no attack surface. Tradeoff: every device
  that wants access needs Tailscale installed and connected.
- **Two separate Immich accounts (you + your wife) on one shared tailnet** —
  private libraries, shared infrastructure.

**Rollout order:** get the server running → import existing libraries (phone
backup + Google Takeout) → verify it actually works → only then cut over from
iCloud → add redundancy (2nd drive) once the primary copy is proven.

---

## 0. Before you start (on Windows, before the wipe) ✅ DONE (factory reset already happened)

- [x] Note the laptop's Wi-Fi password — you'll need it during Ubuntu install.
- [x] Have a USB stick ≥ 8 GB ready.

## 1. Make the Ubuntu installer ✅ DONE

On macOS:
1. Download Ubuntu Desktop 26.04 LTS ISO: https://ubuntu.com/download/desktop
2. Download balenaEtcher: https://etcher.balena.io
3. Plug in the USB stick. Open Etcher → **Flash from file** → select the ISO → **Select target** → pick the USB stick (double-check size/name) → **Flash!**. ~5 min, auto-verifies after.

(On Windows instead, use Rufus from https://rufus.ie the same way.)

## 2. Install Ubuntu alongside Windows ✅ DONE

1. Restart laptop, press the boot-menu key (usually F12, F2, or Esc — depends on brand) → boot from USB.
2. Choose **Install Ubuntu**.
3. At the disk step, pick **Install Ubuntu alongside Windows Boot Manager**. Give Ubuntu ≥ 80 GB.
4. Create a user. **Pick a strong password** — this is your sudo password and you'll use it constantly.
5. Reboot when prompted. Remove USB. GRUB menu appears — pick Ubuntu.

## 3. Make Ubuntu the default boot OS ✅ DONE

This matters because power outages / reboots must come back into the server, not Windows.

```bash
sudo nano /etc/default/grub
# Set:  GRUB_DEFAULT=0
# Set:  GRUB_TIMEOUT=3
sudo update-grub
```

## 3.5. Install Claude Code on the Ubuntu laptop (optional, to run the rest of this runbook from there)

```bash
curl -fsSL https://claude.ai/install.sh | bash
# open a new terminal (or: source ~/.bashrc) so PATH picks up the install
claude
```

(Alternative via npm if you prefer: `sudo apt install -y nodejs npm && npm install -g @anthropic-ai/claude-code && claude` — needs Node ≥ 18.)

Log in when prompted. From here on you can run `claude` on the laptop itself and hand it this runbook to continue steps 4+.

## 4. Format and mount the 4TB drive

This drive is general-purpose, not Immich-only: it mounts at `/mnt/media` and Immich
gets its own subfolder (`/mnt/media/immich`) in step 8. Anything else you want to store
on the drive lives in sibling folders under `/mnt/media/` — Immich never touches those.

Plug in the 4TB HDD. Identify it:

```bash
lsblk -f
```

Look for the 4TB drive (probably `/dev/sda` or `/dev/sdb`). **Triple-check** the device name — the next step erases it.

```bash
# Replace sdX with the right letter — DO NOT get this wrong
sudo parted /dev/sdX --script mklabel gpt mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L media /dev/sdX1
sudo mkdir -p /mnt/media
```

Get the UUID and add to fstab so it auto-mounts:

```bash
sudo blkid /dev/sdX1
# Copy the UUID="..." value
sudo nano /etc/fstab
# Add line:  UUID=<paste>  /mnt/media  ext4  defaults,nofail  0  2
sudo mount -a
df -h /mnt/media    # should show ~3.6T free
sudo chown -R $USER:$USER /mnt/media
```

## 5. Install Docker (official repo, not Ubuntu's outdated one)

```bash
sudo apt update
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
# Log out and back in (or reboot) so the group change takes effect
```

Verify:

```bash
docker run --rm hello-world
```

## 6. Install Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

It prints a URL — open it on your Mac, log in with Google/GitHub. After auth, the laptop joins your tailnet.

In the Tailscale admin console (https://login.tailscale.com/admin/dns) **enable MagicDNS**. Now the laptop is reachable as `http://<hostname>:2283` from any of your devices.

Note the laptop's Tailscale hostname:

```bash
tailscale status
hostname
```

## 7. Install SSH so you can manage from your Mac

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

From your Mac (Tailscale must be installed on Mac too):
```bash
ssh <linux-username>@<laptop-hostname>
```

Everything from here on can be done over SSH from your Mac. Easier than typing on the laptop.

## 8. Deploy Immich

```bash
mkdir -p ~/immich
cd ~/immich
wget -O docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -O .env https://github.com/immich-app/immich/releases/latest/download/example.env
```

Edit `.env`:

```bash
nano .env
```

Set:
- `UPLOAD_LOCATION=/mnt/media/immich`
- `DB_PASSWORD=<generate a long random string>`  (e.g., `openssl rand -base64 32`)
- Leave the rest at defaults

Start it:

```bash
docker compose up -d
docker compose logs -f    # Ctrl-C when you see "Immich server is listening"
```

## 9. First-time setup in the web UI

From your Mac, open `http://<laptop-hostname>:2283`.

1. Create the **admin account** — this is yours.
2. Settings → Storage Template — turn on the template engine. Use the default `{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}` so files on disk are sorted by date.
3. Administration → Settings → Machine Learning — confirm enabled. Face recognition runs automatically on uploaded photos.

## 10. iPhone setup (yours)

On your iPhone:
1. Install **Tailscale** from App Store. Log in with the same account.
2. Install **Immich** from App Store.
3. Open Immich → server URL: `http://<laptop-hostname>:2283` → log in.
4. Settings → Backup → enable **Foreground** and **Background** backup. Pick "Recents" album.
5. Leave it on Wi-Fi overnight for the initial upload.

## 11. Wife's iPhone setup

1. In Immich web UI (your admin account) → Administration → Users → New User. Email + temporary password.
2. On her phone: install Tailscale, log in with the **same** Tailscale account (so her phone joins the tailnet).
3. Install Immich app, sign in with **her** new credentials.
4. Same backup settings as above.

By default, you cannot see her photos through the app, and she cannot see yours. Admin can manage users but cannot view their libraries through normal UI.

## 12. Google Photos import (per user)

On your Mac:

1. Go to https://takeout.google.com → Deselect all → Select only Google Photos → Next.
2. Format: `.zip`, max size 50 GB. Submit. Wait for the email (a few hours to a day).
3. Download all `.zip` files from the email links to a folder on your Mac, e.g. `~/Downloads/takeout/`. **Do not unzip.**
4. Install immich-go: download the latest release binary from https://github.com/simulot/immich-go/releases for macOS.
5. In Immich web UI → Account Settings → API Keys → New Key. Copy it.
6. Run:

```bash
./immich-go upload from-google-photos \
  --server http://<laptop-hostname>:2283 \
  --api-key <YOUR_API_KEY> \
  ~/Downloads/takeout/*.zip
```

Expect overnight runtime for ~500 GB. It preserves dates from the JSON sidecars, recreates albums, and dedupes against what your phone already uploaded.

Repeat the whole step for your wife using **her** API key and her Takeout export.

## 13. Verification

- [ ] Take a new photo on iPhone. With Immich app open, it appears in web UI within ~1 minute.
- [ ] Turn off Wi-Fi, use cellular only. Open Immich app. Library still loads.
- [ ] Wait a few hours, then check People view. Faces should be grouped. Name a few — it suggests matches.
- [ ] Log in to web UI as wife. Confirm her library shows only her photos.
- [ ] Reboot the laptop (`sudo reboot`). After reboot, confirm Immich auto-started (`docker compose ps` in `~/immich`).

## 14. Once verified, you can turn off iCloud Photos

But not before — keep iCloud as a safety net until you've confirmed the full library is on Immich, AI has finished a pass, and you've tested cellular access.

---

## Common problems

| Symptom | Fix |
|---|---|
| iPhone Immich can't connect | Check Tailscale is connected on phone (toggle icon). Ping the laptop from Mac first to confirm it's reachable. |
| Immich logs "permission denied" on /mnt/media | `sudo chown -R 1000:1000 /mnt/media/immich` (the container runs as UID 1000) |
| Laptop becomes unreachable after closing the lid | Lid-close defaults to "suspend" on Ubuntu, which kills SSH/Tailscale/Immich until someone opens it. Fix: `gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing'` and same for `lid-close-battery-action`. (Already applied on this machine.) |
| Face recognition very slow | Normal on first import. ML container processes a queue — leave it running. ~hundreds of photos/hour on a 2018-era laptop. |
| Laptop suspends and backups stop | Settings → Power → Screen Blank: Never, Automatic Suspend: Off. |
| GRUB boots Windows by default after a Windows update | Re-run `sudo update-grub`, or in BIOS set Ubuntu as primary boot entry. |

## Later: redundancy (2nd drive)

Cheapest path: buy a second 4TB external HDD, plug it in, format ext4, mount at `/mnt/backup`, then:

```bash
# /etc/cron.weekly/photos-backup
rsync -a --delete /mnt/media/ /mnt/backup/
```

That's the minimum. Cloud offsite via rclone+B2 is a separate evening's work — I can write that runbook when you want it.
