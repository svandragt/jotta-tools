# jotta-canary

Alerts your phone when a machine's Jottacloud sync folder stops moving, plus
[`jotta-buddy`](#jotta-buddy) for checking the state of sync by hand.

Jotta sync wedges silently. `jotta-cli status` keeps reporting `listening to
events` or `Up to date` while the sync loop retries the same fatal error, and
`jotta-cli sync log` only records downloads. Neither tells you whether your
files still reach the server.

This canary checks end to end instead. Every hour it writes a timestamp to a
file in the sync folder, waits, then asks the server for that file's checksum.
If the checksum doesn't match what's on disk, the upload never landed, and you
get a push notification.

## What you need

- `jotta-cli`, logged in, with sync enabled. The folder can be anywhere; both
  scripts ask jottad where it is.
- `curl`, `jq`, `make` and systemd user services.

Examples below write `~/me/sync` for the sync folder. Substitute your own if it
differs; `jotta-buddy` prints it on the `local` row, or ask jottad directly with
`jotta-cli status --json | jq -r .Sync.RootPath`.
- `~/.local/bin` on your `PATH`. That is where the script installs.
- An [ntfy](https://ntfy.sh) topic, subscribed to on your phone.

## Install

Run this on each machine that syncs.

1. Clone the repo:

   ```sh
   git clone https://github.com/svandragt/jotta-canary
   cd jotta-canary
   ```

2. Write your ntfy topic to the config file. Use the same topic on every
   machine so all the alerts arrive in one place:

   ```sh
   mkdir -p ~/.config/jotta-canary
   echo YOUR-TOPIC > ~/.config/jotta-canary/topic
   ```

   The topic is the only thing protecting your alerts, so it stays out of this
   repo. Pick an unguessable one.

3. Install the script and the timer:

   ```sh
   make install
   ```

   Install each machine from its own clone. Overriding `BIN` to a directory
   inside the sync folder turns installing into publishing: every other machine
   gets the script whether you meant it or not, and two machines installing
   different revisions leave you with a conflicted copy. Watch for a `~/bin`
   that is a symlink into the sync folder.

4. Confirm the alert path reaches your phone:

   ```sh
   make test
   ```

To see when the check last ran and whether it passed:

```sh
make status
```

## How it works

`jotta-canary` asks jottad for the sync folder (`.Sync.RootPath` from
`jotta-cli status --json`), writes the current Unix time to
`<root>/.canary-$(hostname)`, sleeps for the upload grace period, then reads
the newest revision's checksum from `jotta-cli ls Sync/.canary-$(hostname)`. A
match means sync is alive. A mismatch, or a missing remote file, sends the
alert and exits non-zero, so the failure also shows up in
`systemctl --user status jotta-canary.service`.

Asking for the path rather than assuming one is what stops the canary watching
a directory nothing syncs, which would pass forever. The same query doubles as
a liveness check: if jottad accepts the connection but never replies, the
canary alerts immediately instead of waiting out the grace period.

The canary is per host. A single shared canary file has as many writers as you
have machines, and Jotta turns that into conflicted copies.

The grace period is `UPLOAD_GRACE_SECONDS` in the script, 10 minutes by
default. Raise it if a machine has a slow uplink or a large backlog. The
service unit allows 20 minutes, so raise `TimeoutStartSec` too if you go above
that.

## jotta-buddy

`make install` also puts `jotta-buddy` on your `PATH`. Where the canary runs
unattended and alerts you about uploads that never land, this one is for the
moment you are already suspicious and want to look:

```
jotta buddy Mon 18:51:04

  daemon    running  pid 4321, up 06:24
  query     responsive

  sync      clean  full-check completed 18:46:18
    state     Idle 12s ago
    local     91234 files  40.2 GiB  /home/user/me/sync
    remote    98765 files  71.5 GiB
    not local 7531 files  31.3 GiB
    transfer  idle

  backup    clean  scan completed 18:44:02 in 21s
    files     1050041 files  200.4 GiB  /home/user

  recent
    18:46:18  * sync full-check completed in 1m32.404821291s
    18:46:19  sync.state [Idle] => [Evaluating] after 501.615159ms
```

Sync and backup get a verdict each because they fail differently. Sync stops its
event loop and goes quiet, so it fails loudly and you notice. Backup keeps
cycling whatever happens, so it fails silently — it can skip a subtree for months
without a word. The one that hides its failures is the one that needs the row.

Run it with no arguments and it refreshes every 30 seconds, because watching a
stall clear is the usual reason you opened it. To print one report and exit:

```sh
jotta-buddy --once
```

Set `JOTTA_BUDDY_INTERVAL` to change the refresh, in seconds. The refresh is
`watch(1)`, and it only kicks in when output is a terminal, so a script or a
timer gets a single report and a usable exit code without asking for `--once`.

The `not local` row counts files the server holds and this machine does not. It
is not a backlog draining: a folder deleted locally but kept remotely sits there
for good, while sync still reports itself up to date.

Read the two verdicts first. Every indented row reports what jottad is *doing*,
and none of them says whether it worked — so a healthy machine and a broken one
both show a list of errors, and there is no telling them apart at a glance. There
are always some errors in a few hours of log. A completed pass is the only
positive evidence:

```
  sync      clean  full-check completed 18:46:18
  sync      event loop stopped 21:45:42, no clean pass since
  backup    clean  scan completed 18:44:02 in 21s
  backup    12 files failed  4.2 MiB last scan
```

The second form of each is the one to act on, whatever the `errors` row says: a
sync stop more recent than the last completion means nothing has synced since,
and a non-zero backup failure count is the only number that distinguishes files
left behind from files merely queued.

Errors are ranked and reported inside each subsystem, under its own verdict, so a
red verdict always comes with a lead:

```
  sync      event loop stopped 00:02:20, no clean pass since
    error     unable to perform local actions upload group failed: sync.uploadF
              at 00:02:20

  backup    clean  scan completed 23:22:23 in 20s
    error     Error deleting /backup/UUID/sander/.config/Slack/IndexedDB/https_
              at 23:23:25
              5x Error deleting /backup/UUID/sander/.config/mozilla/firefox/
```

One shared list ranked across both put backup in a position to hold the only row
going. Backup is far noisier, so a newer backup fault buried the sync fault that
had actually stopped sync — leaving a red verdict and nothing to act on. Sync is
matched first when classifying, because the backup root is the whole home
directory and contains the sync folder inside it.

A fault carrying neither marker goes under `errors  unattributed` rather than
being filed under whichever verdict happened to be nearby. Some continuation lines
land there, since jottad logs the failure class and the offending path on separate
lines and only one of them carries the path.

It adds the two things `jotta-cli status` will not tell you. The first is a
different wedge from the one the canary catches: jottad accepts the connection
and then never answers, so every `jotta-cli` command dies on its own two second
deadline with `Connected but jottad did not respond to query within deadline`.
The daemon looks healthy to systemd, sits at zero CPU, and stops logging. Only
a restart clears it:

```sh
systemctl --user restart jottad
```

The second is errors, because `jotta-cli` does not expose them at all. There is
no error field in `status --json`, `status -v` lists file errors only while
they are current, and `list uploaderrors` demands an `--uploadid` you can only
get from a transfer that is still running. The service log is the only place a
failure survives, so that is where `jotta-buddy` reads.

A worked example, and the reason the `errors` row leads with the fault that
started most recently rather than the most frequent one. Two files whose names
differ only in case sync fine on Linux and collide on the server:

```sh
echo one > ~/me/sync/casetest.txt
echo two > ~/me/sync/CaseTest.txt
echo three > ~/me/sync/after-collision.txt   # written afterwards
```

jottad stops the sync event loop on the collision and retries the same
full-check every 90 seconds, failing the same way each time. Nothing uploads
after that point, including files that have nothing to do with the collision:
`after-collision.txt` never reaches the server. Throughout, `jotta-cli status`
reports `Checking for changes...` and `Mode: listening to events`.

`jotta-buddy` names it, and the path with it:

```
  state     Evaluating 0s ago
  errors    Error syncing /casetest.txt already exists with different case
            23:14:02 - 23:15:32, seen 2x
            54 error lines in 24h
```

The collision logs once and then goes quiet, while routine warnings keep
accumulating, so ranking errors by frequency hides the one that actually
stopped sync. Deleting either side of the pair clears it, and the backlog
drains on the next retry.

Ranking by the newest *line* fails the same way, for a subtler reason. A fault
that retries forever is newest again every time it fires, so it holds the row for
good and nothing new ever gets in — which makes the row worthless precisely when
you need it. First-seen fixes that: a chronic fault gives way as soon as anything
else appears, while a fault that logs once and stops still leads, because it only
just began.

That is what the two times under the message are for. `at 23:06:39` on its own is
a single event. A range with a count, `07:21:19 - 23:05:52, seen 12x`, is
furniture — something that has been failing all day and will keep failing.

A name the server refuses fails the same way, and this one is quieter because it
never stops the loop. A directory whose name contains a newline is legal on
Linux and rejected by the API, so the remote `mkdir` fails on every backup scan
and everything under it is skipped:

```
  errors    error mkdir /backup/UUID/sander/.config/mozilla/firefox/pkQtSp
            seen 6x
```

The journal carries the verdict on the following line, `INVALID_ARGUMENT code:
12`. Sync and the rest of the backup carry on, so nothing looks broken; that
subtree is just never on the server. Find the offending name, and note that `ls`
shows nothing wrong because the newline reads as a line break:

```sh
find ~ -depth -name '*
*' -print0 | xargs -0 -n1 echo
```

Rename or delete what it finds, and the next scan picks the subtree up.

Recent activity is read from the journal too, because the state names (`Idle`,
`Evaluating`, `Working`) only appear there. `SyncState` in the JSON is an
integer with no published mapping, and it disappears from the output entirely
when sync is idle. The `state` row shows the age of the last transition, since
`Working` for eight seconds and `Working` for forty minutes mean opposite
things.

Exit codes are `0` healthy, `1` daemon not running, `2` wedged, so it can gate
a script.

`JOTTA_BUDDY_DEADLINE` (default 15) is how many seconds to wait for jottad
before calling it wedged. `JOTTA_BUDDY_SINCE` (default `-30min`) is how far back
to read the journal for activity. `JOTTA_BUDDY_ERRSINCE` (default `-24h`) is the
window for errors, which is wider on purpose: a loop that started this morning
is still why nothing is moving now.

It is symlinked rather than copied, so edits in the clone take effect straight
away. Do not move it into the sync folder: `~/bin` is a symlink into the synced
folder on some machines, and a tool that reports on sync should not be one of
the things sync can break.

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
