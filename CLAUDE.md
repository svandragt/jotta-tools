# CLAUDE.md

Two tools for one problem: Jottacloud sync stops and says nothing.
`jotta-canary` runs on a timer and alerts when uploads stop landing.
`jotta-buddy` is the by-hand view of what jottad is doing right now.

## Conventions

- POSIX `sh`, tabs, `set -eu`. Comments say *why*, not what.
- `BIN` is `~/.local/bin` and must stay out of the sync folder. On some
  machines `~/bin` is a symlink into `~/me/sync`, which turns installing into
  publishing to every host.
- `jotta-canary` installs as a copy: the timer runs it unattended and must not
  follow a working tree. `jotta-buddy` installs as a symlink: it is read by hand
  and edits should take effect immediately.
- Non-trivial logic leaves one runnable check behind. The wedge branch was
  verified by putting a hanging stub `jotta-cli` on `PATH`, not by assuming.

## Handling a new jottad error

When sync breaks in a way `jotta-buddy` does not already name, follow this.

**Do not add a matcher for one message.** A specific matcher only ever catches
the fault you already survived. The `errors` row exists to surface faults
nobody has seen yet, so a change is worth making only if it would have caught
this one *without knowing its text*.

**Fields that look right and are not.** `status --json` has several, all found the
same way, by checking them while something was actually happening:

- `.State.Uploading` and `.State.Downloading` stay empty objects with thousands of
  files in flight. In-flight figures live in `.Sync.WorkingProgress`, which is
  absent when idle. A row keyed on the former reads `idle` through an 11 GiB upload.
- `.Backup...Backups[].Uploading` reports a *delta*, and goes negative when nothing
  is happening. Only a positive count means anything.
- `.Backup...History` lags by hours. It sat on a 16:07 scan while the log showed one
  from 23:22, so a backup verdict has to come from the log.
- `.Backup...Count` reports a partial total mid-recount. It was seen at 69872 files
  and 3.1 GiB when the real figure was 1057950 and 211.8 GiB, correcting itself
  within a minute. Do not treat a single sample as authoritative.
- `.Sync.RemoteCount` is zero until jottad has listed the server tree, so a fresh
  daemon reports an empty account rather than an unknown one.

**Do not trust `jotta-cli` for any of it.** It has no error surface:
`status --json` has no error field, `status -v` lists file errors only while
they are current, and `list uploaderrors` requires an `--uploadid` that exists
only for a transfer still in flight. During a total stall it still prints
`Checking for changes...` and `Mode: listening to events`. The service log is
the only durable record.

1. **Find it.** `journalctl --user -u jottad --since <when> --no-pager`
   Read the whole burst, not the first matching line. One fault emits several
   lines in the same second carrying different information: usually one names
   the offending path, one the failure class, one whether the event loop
   stopped.

2. **Classify it.** Does the sync event loop stop or keep cycling? Does it
   retry, and at what cadence (look for `sleeping Ns before restarting`)? Does
   it block unrelated files or only the file at fault? Does it clear on its
   own, or need a restart or manual cleanup?

3. **Prove the blast radius against the server**, not the local database.
   Write a marker file *after* the fault begins, then `jotta-cli ls "Sync/<name>"`.
   GOTCHA: that exits 0 even when it finds nothing, printing `nothing found`.
   Test the output, never `$?`. Getting this wrong reports success mid-stall.

4. **Reproduce it deliberately** if you can. A fault you can trigger is a fault
   you can verify a fix against. Clean up after, and confirm sync recovers.

5. **Work out why `jotta-buddy` missed it.** In order of what has actually gone
   wrong before:
   - the include pattern did not match — note that `sync.event.processing.err:`
     does not contain the string `error`;
   - the line matched but lost the ranking — the row leads with the fault that
     *started* most recently, longest line in that burst, because a fault that
     logs once and stops matters more than a warning repeating all day. Ranking
     by newest *line* was the earlier bug: a fault that retries forever is newest
     again every time it fires, so it held the row and nothing new could get in;
   - noise outranked it — lines logged after every real error, such as
     `upload-diagnostics` and `error-reporting`, are excluded for this reason.

6. **Change it generically, or not at all.** Widen a pattern, fix a ranking,
   exclude a noise source. No branch per error string.

7. **Verify while the fault is live**, not after it clears. The row should name
   something actionable, ideally the path. Exit codes still mean: 0 healthy,
   1 daemon not running, 2 wedged.

8. **Record what a person should DO** in `README.md`, beside the case-collision
   example. A row that names a fault without saying how to clear it just
   relocates the confusion.

### Known faults

| Fault | Loop | Retry | Blocks | Clears by |
|---|---|---|---|---|
| `Case Collision in tree` | stops | ~90s, identical | everything queued after it | delete either side of the pair |
| jottad unresponsive | no reply at all, but the journal may keep filling | n/a | everything | `systemctl --user restart jottad` |
| `Allocate failed: DeadlineExceeded` | usually cycles, but stops the loop if it hits the canary upload | bursts 0-10s apart, 30s after a loop stop | transfers in that burst | cleared on its own |
| `jottad.auth.err ... lookup id.jottacloud.com` | stops, restarts itself | 30s | everything until DNS answers | logs `=> RESOLVED` when it clears |
| `Missing events. Restart sync please` | restarts itself | 20s | briefly | self-healing unless it wedges |
| 421 `CorruptUploadOpenApiException` on a file under `Sync` | stops | 30s, then the retry lands | everything queued | self-healing, confirmed 2026-08-18 00:02:20 on `/.canary-<host>` |
| `error mkdir /backup/<uuid>/...` + `INVALID_ARGUMENT code: 12` | keeps cycling | every backup scan, ~hourly | that subtree only, silently | rename the local directory. Do **not** delete it: see below |
| `Error deleting /backup/<uuid>/...` + `InvalidArgument` | keeps cycling | every backup scan | nothing, but permanently | nothing known. Reported as [jotta-cli-issues#228](https://github.com/jotta/jotta-cli-issues/issues/228) |
| `Error syncing failed to list tree` (after `remote.cursor.get`/`GetCustomer` deadlines) | parks in `[Evaluating]` for 13-15 min, then gives up | restarts 30s later; the next full-check completes in ~45s | every upload for the duration | on its own. Do not act, and do not shorten the canary's confirm deadline below it |

### Rename a name the server rejects, never delete it

Deleting the offending directory does not clear the fault, it converts it into a
worse one. jottad sees the local directory go, tries to delete the matching remote
folder, and the server rejects the *name* on delete exactly as it did on mkdir:

```
Deleting remote folder: /backup/<uuid>/user/.config/.../<bad name>
Error deleting /backup/<uuid>/user/.config/.../<bad name>
  rpc error: code = InvalidArgument ... INVALID_ARGUMENT code 12
marked /home/user/.config/.../<bad name> as dirty
```

It then retries on every scan, forever. The local directory is gone, so no local
change can reach it any more. `jotta-cli dump` shows the row that drives it, and
`"files":[]` confirms nothing was ever stored under the name:

```sh
jotta-cli dump | grep '\\n'
```

Renaming avoids all of this: the remote folder never existed, so there is nothing
for jottad to delete, and the new name backs up normally.

Once it has reached this state there is no known way out from the client, and the
fault is filed upstream as
[jotta-cli-issues#228](https://github.com/jotta/jotta-cli-issues/issues/228).
Everything below was tried and ruled out on 2026-08-18, so do not spend the evening
on it again:

- **an ignore rule makes it worse.** jottad reads a newly ignored path as "remove
  from the remote", which is precisely the rejected delete. The rule was added, the
  delete still fired on the next scan, and the rule was removed again.
- **a daemon restart does not help.** The row lives in the local database and
  survives into the new pid.
- **recreating the directory and renaming it does not help.** A rename still has to
  delete the old name remotely, and that is the call being refused.
- **the web interface has nothing to act on.** The `mkdir` never succeeded, so
  `jotta-cli ls Backup/<device>/...` lists only the valid sibling.
- **the trash is a red herring.** `**Trash/**` is ignored already, so a deleted-to-
  trash copy plays no part.

The damage is one log line per scan and no data at risk, so the practical answer is
to leave it. If you do reach for an ignore rule for some other reason, build the
pattern from the *doubled* text rather than a newline, so it stays an ordinary shell
argument, and prove it with `ignores test` first — a pattern that also matches the
real directory silently drops it from backup:

```sh
p='.config/mozilla/firefox/pkQtSp0i.Profile 1*pkQtSp0i.Profile 1'
jotta-cli ignores test -p "$p" --path '.config/mozilla/firefox/pkQtSp0i.Profile 1'
```

That must report `did not match` before you would ever add it.

### The canary alerts, sync is fine when you look

Three alerts, all the same fault: a `failed to list tree` timeout parked the sync
loop in `[Evaluating]` for 13-15 minutes, jottad restarted itself, and the canary
upload landed 11-13 minutes after being written. Measured on 2026-08-19:

| Written | Landed | Delay | `[Evaluating]` spell |
|---|---|---|---|
| Aug 18 09:03:26 | 09:16:30 | 13m04s | 14m03s |
| Aug 19 01:04:20 | 01:15:52 | 11m32s | 13m42s |
| Aug 19 09:03:20 | 09:16:13 | 12m53s | 12m56s |

The canary now looks at 10 minutes and keeps asking to 25 before it will call a
miss, and a miss still has to survive a second run before anyone is woken, so a
stall that clears itself no longer pages anyone. `make check` drives all of it
against stub `jotta-cli`, `date` and `sleep`.

The suspend guard and the confirm loop have to agree on what "too long" means.
It compares elapsed time against the wait the run *asked for*, not against
`UPLOAD_GRACE_SECONDS + 120`: polling to the confirm deadline legitimately
outlasts the grace period by fifteen minutes, so the older formula reads every
deadline-reaching run as a suspend, gives no verdict, and the canary goes
permanently silent on real stalls. `canary-check` covers that specific mistake.

A fourth alert, 2026-08-20 01:05:20, was a different path and a worse one: it
exited **two seconds** in, on the liveness query, saying `jottad did not answer
within 30s. Try: systemctl --user restart jottad`. jottad was fine — same pid for
a day, mid full-check, and the run an hour earlier had queried it happily during
the same kind of full-check — so the advice would have interrupted a healthy
daemon. Two seconds is the tell: a real 30s timeout cannot exit that fast, so the
query answered and simply had no `.Sync.RootPath` in it. The liveness check was
the last path still judging on a single look, and it now asks `QUERY_ATTEMPTS`
times and distinguishes silence, which a restart clears, from a reply with no
root, which it does not.

A fifth and sixth alert taught that even `QUERY_ATTEMPTS` looks inside one run
are still one look. Both were the ordinary `failed to list tree` self-heal seen
through the liveness gate rather than the upload loop. On 2026-08-20 09:05 jottad
answered three times with no root through a 15m43s `[Evaluating]` spell; on
2026-08-21 01:04 it did not answer at all through a 15m37s one (`connection
refused` listing the remote tree, status socket silent, journal logging nothing),
and both times it recovered on its own with the same pid. So a self-clearing
stall shows up at the liveness gate as *either* a rootless reply *or* total
silence, and "silence means wedge, page now" was wrong: the gate must hold both
symptoms to a second run, exactly as an upload miss is held, before paging. Only
the advice still forks — silence that survives a second run is a real wedge and
wants a restart; a rootless reply that survives one does not. `canary-check`
covers both. The lesson generalises: no liveness symptom is a verdict on the
first run, because every stall this daemon has is self-clearing until proven
otherwise across a cadence.

Two things this cost, worth not repeating: `jotta-cli ls` reports `Last
Modified` as the *local* mtime, so its timestamp says 09:03 for a file the
server took at 09:16 and cannot be used to time a landing — only the journal
can. And raising the canary's frequency is the wrong lever: a wedge stays
wedged, so a faster cadence finds nothing the next hour would not, while every
extra run is another chance to sample one of these windows.

### Looks like signal, is not

A long gap since the last full-check (`no full-check in 4h`), because a full-check
is **not periodic**: jottad runs one when the sync loop restarts, so a long gap means
the loop has not had to restart. Measured on a healthy daemon: an 8h gap on
2026-08-18 and 15h45m from 2026-08-19 09:15 to 2026-08-20 01:00, with hourly canary
uploads landing throughout both. `action none` beside it is right, not a contradiction ·
`errors[0 files 0 bytes]` in scan lines (only non-zero matters) ·
`localdb.found <checksum> in file <path>, copied to <root>/.jottaclouddownload/<id>`
(jottad reusing a local file with a matching checksum instead of downloading it, so
purely informational, and about 2400 lines every 4 hours. Only the ones whose path
happens to contain `error` — `ErrorRule.php` was the first — reach the filter, and one
of those took the top sync slot) ·
`Ignored <path> : unsupported file type` (symlinks, intended, and about 130k lines
every 4 hours — jottad used to word this `not regular file`, so match both. Only
the ones whose *path* contains `error`, such as `libgpg-error.so.0`, reach the
error filter at all, which is what makes a stale exclusion here hard to notice) ·
`PhotoFailed` in `hub.OnEvent` DEBUG lines · `Error checking for new versions`
(update check) · `jottad.sync.upload-diagnostics => ...error-reporting-full...`
(logged after every real error, so it masquerades as the newest fault) ·
`CorruptUploadOpenApiException` (421) on a file that rewrites itself mid-upload —
firefox `cookies.sqlite-wal`, `sessionstore-backups/*.jsonlz4`, session JSON —
the checksum stops matching what was allocated, and the retry lands. Common in
the `/home/user` backup set, so it dominates the 4h count without meaning
anything. A 421 on a file under `Sync` is **not** the same thing: it stops the
event loop, and the file it names is usually `/.canary-<host>` simply because the
canary is the only writer in an otherwise idle sync folder, so it is the upload in
flight when a transient server error arrives. Do not "fix" the canary for it · a line ending
`=> RESOLVED`, which is jottad clearing the error it quotes.
