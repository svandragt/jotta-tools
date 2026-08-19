# jotta-canary

Alerts your phone when a machine's Jottacloud sync folder stops moving, plus
[`jotta-buddy`](#jotta-buddy) for checking sync and backup by hand.

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
- `~/.local/bin` on your `PATH`. That is where the script installs.
- An [ntfy](https://ntfy.sh) topic, subscribed to on your phone.

Examples below write `~/me/sync` for the sync folder. Substitute your own if it
differs; `jotta-buddy` prints it on the `local` row, or ask jottad directly with
`jotta-cli status --json | jq -r .Sync.RootPath`.

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
match means sync is alive. A mismatch, or a missing remote file, counts as a
miss and exits non-zero, so the failure shows up in
`systemctl --user status jotta-canary.service`.

A run that spans a suspend gives no verdict at all. The machine wakes with no
network and reads back a checksum from before it slept, which looks exactly like
a stall, so the canary compares the clock instead: a run that outlasted its
grace period by more than two minutes exits without judging anything. The timer
leaves out `Persistent=true` for the same reason, since a catch-up run fires the
moment the machine resumes and reports a miss for a sync that is fine.

A single miss does not alert either. A VPN or a brief server wobble stops
uploads for one run and then clears on its own, so the alert waits for a
second miss in a row, roughly an hour later on the hourly timer. The count lives
in `~/.local/state/jotta-canary/misses` and a successful run deletes it. Set
`MISSES_BEFORE_ALERT=1` in the script if you would rather hear about every
miss.

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
  action    none  faults present are ones jottad retries by itself

  sync      clean  full-check completed 18:46:18
    state     Idle 12s ago
    local     91234 files  40.2 GiB  /home/user/me/sync
    remote    98765 files  71.5 GiB
    not local 7531 files  31.3 GiB
    transfer  up 192/7201 files  727.0 KiB of 6.6 GiB

  backup    clean  scan completed 18:44:02 in 21s
    files     1050041 files  200.4 GiB  /home/user
    transfer  up 7756 files  7.0 GiB
    error     Error uploading [#N] /home/user/.config/Slack/Service
              Worker/CacheStorage/ID/UUID/ID_0 => upload: 421 CorruptUploadOpenApiException
              18:20:14 - 18:44:02, seen 3x, 399 of this kind

  recent
    18:46:18  * sync full-check completed in 1m32.404821291s
    18:46:19  sync.state [Idle] => [Evaluating] after 501.615159ms
```

That is the ordinary healthy shape, errors and all: a few hundred faults on files that
rewrite themselves mid-upload, which jottad retries until they land.

Read the `action` line and stop there if it says `none`. Everything below it is
detail for when it does not. The other form names what to do:

```
  action    sync stopped 22m ago and has not restarted -- systemctl --user restart jottad
```

It cannot be answered by naming faults, because the next fault is always one nobody
has seen. It can be answered by recovery, which splits them cleanly: a 421, a
`DeadlineExceeded` or a DNS timeout stops the event loop and jottad restarts it
within thirty seconds, while a case collision, a name the server refuses, a wedge or
a stopped daemon wait for a person. So the test is not which error but whether the
loop came back — a stop with no restart and no completed check after it, well past
the thirty second retry, is one that is not recovering. A non-zero backup failure
count counts too, since that is jottad reporting files left behind.

Sync and backup get a verdict each because they fail differently. Sync stops its
event loop and goes quiet, so it fails loudly and you notice. Backup keeps
cycling whatever happens, so it fails silently — it can skip a subtree for months
without a word. The one that hides its failures is the one that needs the row.

Run it with no arguments and it refreshes every 30 seconds, because watching a
stall clear is the usual reason you opened it. To print one report and exit:

```sh
jotta-buddy --once
```

The refresh is `watch(1)`, and it only kicks in when output is a terminal, so a
script or a timer gets a single report and a usable exit code without asking for
`--once`. Anything other than `--once` or `--help` is rejected rather than treated
as a cue to start watching.

Colour follows the terminal. To keep it when piping, set `JOTTA_BUDDY_COLOR`:

```sh
JOTTA_BUDDY_COLOR=1 jotta-buddy --once | less -R
```

| Variable | Default | What it does |
|---|---|---|
| `JOTTA_BUDDY_INTERVAL` | `30` | Refresh, in seconds |
| `JOTTA_BUDDY_COLOR` | unset | Any value forces colour off a terminal |
| `JOTTA_BUDDY_SINCE` | `-30min` | Window for the `recent` list |
| `JOTTA_BUDDY_ERRSINCE` | `-4h` | Window for errors and the verdicts |
| `JOTTA_BUDDY_DEADLINE` | `15` | Seconds to wait for jottad before calling it wedged |

Widen `JOTTA_BUDDY_ERRSINCE` to look further back, at about a second of extra
journal reading per additional four hours. It has to stay wider than the slowest
retry that matters, since backup scans are hourly and anything under that makes
hourly furniture read as breaking news.

The `not local` row counts files the server holds and this machine does not. It
is not a backlog draining: a folder deleted locally but kept remotely sits there
for good, while sync still reports itself up to date.

After `action`, the two verdicts. Every indented row reports what jottad is *doing*,
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
    error     Error deleting /backup/UUID/user/.config/Slack/IndexedDB/https_
              at 23:23:25
              5x Error deleting /backup/UUID/user/.config/mozilla/firefox/
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
The daemon looks healthy to systemd and only a restart clears it. Do not wait for
it to go quiet first: caught live on 2026-08-18 it was still writing DEBUG lines
to the journal seconds before the query timed out, so a busy log is no evidence
that queries are being answered.

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
            54 error lines in 4h
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
  errors    error mkdir /backup/UUID/user/.config/mozilla/firefox/pkQtSp
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

Exit codes are `0` healthy, `1` daemon not running, `2` wedged and `64` bad usage,
so it can gate a script.

The environment overrides are listed [above](#jotta-buddy).

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

**Two runs missed but sync is fine now.** The alert names how many runs missed.
Delete `~/.local/state/jotta-canary/misses` to reset the count, or let the next
healthy run clear it.

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

## Licence

[GPL-3.0](LICENSE). If you distribute a modified version, it stays under the same
licence.
