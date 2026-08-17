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
| jottad unresponsive | no reply at all | n/a | everything | `systemctl --user restart jottad` |
| `Allocate failed: DeadlineExceeded` | usually cycles, but stops the loop if it hits the canary upload | bursts 0-10s apart, 30s after a loop stop | transfers in that burst | cleared on its own |
| `jottad.auth.err ... lookup id.jottacloud.com` | stops, restarts itself | 30s | everything until DNS answers | logs `=> RESOLVED` when it clears |
| `Missing events. Restart sync please` | restarts itself | 20s | briefly | self-healing unless it wedges |
| `error mkdir /backup/<uuid>/...` + `INVALID_ARGUMENT code: 12` | keeps cycling | every backup scan, ~hourly | that subtree only, silently | rename the local directory. Do **not** delete it: see below |
| `Error deleting /backup/<uuid>/...` + `InvalidArgument` | keeps cycling | every backup scan | nothing, but permanently | an ignore rule, because no local change can reach it |

### Rename a name the server rejects, never delete it

Deleting the offending directory does not clear the fault, it converts it into a
worse one. jottad sees the local directory go, tries to delete the matching remote
folder, and the server rejects the *name* on delete exactly as it did on mkdir:

```
Deleting remote folder: /backup/<uuid>/sander/.config/.../<bad name>
Error deleting /backup/<uuid>/sander/.config/.../<bad name>
  rpc error: code = InvalidArgument ... INVALID_ARGUMENT code 12
marked /home/sander/.config/.../<bad name> as dirty
```

It then retries on every scan, forever. The local directory is gone, so no local
change can reach it any more. `jotta-cli dump` shows the row that drives it, and
`"files":[]` confirms nothing was ever stored under the name:

```sh
jotta-cli dump | grep '\\n'
```

Renaming avoids all of this: the remote folder never existed, so there is nothing
for jottad to delete, and the new name backs up normally.

To clear one that has already reached this state, add an ignore rule. Build the
pattern out of the *doubled* text rather than a newline, so it stays an ordinary
shell argument, and prove it with `ignores test` before adding it — a pattern that
also matches the real directory silently drops it from backup:

```sh
p='.config/mozilla/firefox/pkQtSp0i.Profile 1*pkQtSp0i.Profile 1'
jotta-cli ignores test -p "$p" --path '.config/mozilla/firefox/pkQtSp0i.Profile 1'
jotta-cli ignores add --pattern "$p" --backup /home/sander
```

The first command must report `did not match`. `jotta-cli ignores rem` undoes it.

### Looks like signal, is not

`errors[0 files 0 bytes]` in scan lines (only non-zero matters) ·
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
the `/home/sander` backup set, so it dominates the 24h count without meaning
anything; a 421 on a file under `Sync` is not the same thing · a line ending
`=> RESOLVED`, which is jottad clearing the error it quotes.
