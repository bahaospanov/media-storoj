# Troubleshooting notes

Real problems hit during setup, and how they were diagnosed/fixed. See `runbook.md`
for the step-by-step install; this file is "what went wrong and why."

## Laptop booted Windows instead of Ubuntu by default

Setting `GRUB_DEFAULT=0` in `/etc/default/grub` is **not enough** on a dual-boot UEFI
machine. GRUB only gets to run if the firmware chooses to launch it in the first
place — that choice is a separate, lower-level setting: the UEFI firmware's own
`BootOrder` (NVRAM), which lists boot entries like `Windows Boot Manager` and `ubuntu`
independently of anything GRUB controls.

Windows is known to silently rewrite itself back to the front of this list (during
Windows updates, or via its own fast-startup behavior), which bypasses GRUB — and
your `GRUB_DEFAULT` setting — entirely.

Diagnose:
```bash
efibootmgr
# Look at BootOrder and confirm which entry (Windows Boot Manager vs ubuntu) is first
```

Fix (put `ubuntu`'s boot entry first, keep Windows in the list as a fallback):
```bash
sudo efibootmgr -o <ubuntu-entry-id>,<windows-entry-id>,<...rest of the original order>
```

If it happens again after a Windows boot/update, just rerun the same command.

## Laptop appeared to "shut down"

Investigated via `uptime`, `journalctl --list-boots`, and `journalctl -b 0 | grep -i
suspend`. In this case the system had **not** actually rebooted or crashed — uptime
was continuous and Immich's containers never restarted. Likely just a display blank
or a dropped SSH/Tailscale connection that looked like a shutdown.

While checking, found a real landmine: `lid-close-ac-action` and
`lid-close-battery-action` both defaulted to `suspend`. On a laptop running headless
as a server, closing the lid at any point would suspend it — killing SSH, Tailscale,
and Immich access until someone physically opens the lid again. Fixed with (no sudo
needed, this is a per-user session setting):

```bash
gsettings set org.gnome.settings-daemon.plugins.power lid-close-ac-action 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power lid-close-battery-action 'nothing'
```

Also worth checking if backups seem to silently stop: `Settings → Power → Screen
Blank: Never, Automatic Suspend: Off` (also in `runbook.md`'s Common Problems table).

## Host became unresponsive / GNOME kept crashing, needed a hard reboot

This happened once, right after a big SD card import finished and Immich's paused
background jobs (thumbnails, video transcoding, face detection, smart search) all
resumed at once against the full backlog — combined with the live desktop session,
it exceeded this laptop's 7.1GB RAM + swap and the kernel's OOM killer started
killing GNOME session processes, eventually taking down the whole machine. Full
diagnosis, the fix applied (lower job concurrency, tighter container memory caps,
bigger swap), and the current tuned settings are in `docs/server-tuning.md` — check
there before re-deriving this from scratch.

## Immich web UI said "admin already created"

Not a bug — the admin account had already been created successfully in an earlier
step (confirmed via `curl http://localhost:2283/api/server/config` showing
`isInitialized: true`, and a matching row in the `user` table in Postgres). Just log
in instead of trying to sign up again.

To check whether an admin exists and who it is:
```bash
curl -s http://localhost:2283/api/server/config | python3 -m json.tool
# isInitialized: true means an admin account exists

docker exec immich_postgres psql -U postgres -d immich -c \
  'SELECT id, email, name, "createdAt" FROM "user";'
```

## iPhone Immich app: "server not reachable"

Immich is deliberately **only reachable over Tailscale** (see
`docs/immich-concepts.md`), never the public internet. If the app can't reach
`http://<laptop-hostname>:2283`, the cause is almost always the phone's Tailscale
connection, not the server. Checklist, in order:

1. Confirm the server itself is fine: `tailscale status` on the laptop, and
   `ss -tlnp | grep 2283` should show it listening on `0.0.0.0:2283`.
2. Try the raw Tailscale IP instead of the MagicDNS hostname (e.g.
   `http://100.x.x.x:2283`, from `tailscale ip -4`) to rule out DNS resolution
   issues.
3. On the phone: is Tailscale actually connected (not just logged in)? iOS requires
   accepting a system **VPN Configuration permission prompt** the first time — if
   that got dismissed, the phone can look "logged in" in the app while never
   actually joining the tailnet.
4. Check https://login.tailscale.com/admin/machines from a browser — does the phone
   show up in the device list at all? If not, the VPN permission step above is the
   likely culprit. If it shows up but greyed out / "needs approval," some tailnets
   require manually approving new devices before they can reach peers.
5. Confirm same Tailscale account on both devices, and check
   https://login.tailscale.com/admin/acls hasn't been customized to block traffic
   (default ACL allows all tailnet devices to reach each other).

Once the phone actually appears in `tailscale status` on the laptop as a peer, the
Immich app connects immediately.
