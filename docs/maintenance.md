# Maintenance procedures

## Safely detaching the 4TB drive (`/mnt/media`)

Order matters — Immich actively reads/writes `/mnt/media/immich` (originals,
thumbnails, video transcoding) while running, so stop it before touching the drive.

```bash
# 1. Stop Immich — its DB lives at ~/immich/postgres on the internal disk, unaffected
cd ~/immich && docker compose down

# 2. Unmount
sudo umount /mnt/media

# 3. Power off the USB device (spins it down, cuts power — safe to unplug after this)
udisksctl power off -b /dev/sdb
```

Then physically unplug.

**To reconnect:**
```bash
# Plug it back in — /etc/fstab has `nofail`, so systemd should auto-mount within a
# few seconds. Verify:
df -h /mnt/media
# If it didn't auto-mount:
sudo mount -a

# Bring Immich back up
cd ~/immich && docker compose up -d
```

Because of `nofail` in the fstab entry, the laptop will also boot fine even if the
drive isn't plugged in at all — Immich will just fail to start properly (or error)
until the drive's back and `docker compose up -d` is rerun.

## What `lost+found` in `/mnt/media` is

Standard, automatically created by `mkfs.ext4` at format time on every ext4
filesystem. Reserved for `fsck` to place recovered/orphaned file fragments into if
the filesystem ever needs repair after an unclean shutdown. Expected to be empty in
normal operation — leave it alone, don't delete it.
