# jotta-canary

Alerts your phone when a machine's Jottacloud sync folder stops moving.

Jotta sync wedges silently. `jotta-cli status` keeps reporting `listening to
events` or `Up to date` while the sync loop retries the same fatal error, and
`jotta-cli sync log` only records downloads. Neither tells you whether your
files still reach the server.

This canary checks end to end instead. Every hour it writes a timestamp to a
file in the sync folder, waits, then asks the server for that file's checksum.
If the checksum doesn't match what's on disk, the upload never landed, and you
get a push notification.

## What you need

- `jotta-cli`, logged in, with a sync folder at `~/me/sync`.
- `curl`, `make` and systemd user services.
- An [ntfy](https://ntfy.sh) topic, subscribed to on your phone.

## Install

Run this on each machine that syncs.

1. Write your ntfy topic to the config file. Use the same topic on every
   machine so all the alerts arrive in one place:

   ```sh
   mkdir -p ~/.config/jotta-canary
   echo YOUR-TOPIC > ~/.config/jotta-canary/topic
   ```

   The topic is the only thing protecting your alerts, so it stays out of this
   repo. Pick an unguessable one.

2. Install the script and the timer:

   ```sh
   make install
   ```

3. Confirm the alert path reaches your phone:

   ```sh
   make test
   ```

To see when the check last ran and whether it passed:

```sh
make status
```

## How it works

`jotta-canary` writes the current Unix time to `~/me/sync/.canary-$(hostname)`,
sleeps for the upload grace period, then reads the newest revision's checksum
from `jotta-cli ls Sync/.canary-$(hostname)`. A match means sync is alive. A
mismatch, or a missing remote file, sends the alert and exits non-zero, so the
failure also shows up in `systemctl --user status jotta-canary.service`.

The canary is per host. A single shared canary file has as many writers as you
have machines, and Jotta turns that into conflicted copies.

The grace period is `UPLOAD_GRACE_SECONDS` in the script, 10 minutes by
default. Raise it if a machine has a slow uplink or a large backlog. The
service unit allows 20 minutes, so raise `TimeoutStartSec` too if you go above
that.

## Uninstall

```sh
make uninstall
```

This leaves your topic file and the canary files in the sync folder. Delete
`~/me/sync/.canary-<hostname>` by hand if you want them gone.

## Troubleshooting

**You get an alert but sync looks fine.** Check the remote revisions directly:

```sh
jotta-cli ls Sync/.canary-$(hostname)
md5sum ~/me/sync/.canary-$(hostname)
```

The top row is the newest revision. If its checksum matches the local file, the
upload did land and the alert was late rather than wrong. Raise
`UPLOAD_GRACE_SECONDS`.

**No alerts at all, ever.** Run `make test`. If nothing arrives, the problem is
the topic or the phone subscription, not sync.

**The service fails immediately.** It probably can't read
`~/.config/jotta-canary/topic`. Check that the file exists and holds one line.

**A machine goes quiet.** The canary only alerts from the machine that is
stuck, so a powered-off or crashed machine reports nothing. Check the file
dates in the sync folder to see which hosts are still writing:

```sh
ls -l ~/me/sync/.canary-*
```
