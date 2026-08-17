# Not ~/bin: that is a symlink into the synced folder on some machines, which
# turns installing into publishing to every host. Keep ExecStart in the service
# unit pointing at the same place if you change this.
BIN := $(HOME)/.local/bin
UNITS := $(HOME)/.config/systemd/user
TOPIC_FILE := $(HOME)/.config/jotta-canary/topic

.PHONY: install uninstall test check status

install: $(TOPIC_FILE)
	install -D -m 755 jotta-canary $(BIN)/jotta-canary
	install -D -m 644 jotta-canary.service jotta-canary.timer -t $(UNITS)
	systemctl --user daemon-reload
	systemctl --user enable --now jotta-canary.timer
	@# Symlinked, not copied: sync-buddy is read by hand, so edits in the clone
	@# should take effect without reinstalling. The timer runs jotta-canary
	@# unattended, which is why that one is a copy the clone cannot change.
	mkdir -p $(BIN)
	ln -sfn $(CURDIR)/sync-buddy $(BIN)/sync-buddy

$(TOPIC_FILE):
	@echo "Missing $@. Write your ntfy topic to it first:"
	@echo "  mkdir -p $(dir $@) && echo YOUR-TOPIC > $@"
	@exit 1

uninstall:
	systemctl --user disable --now jotta-canary.timer
	rm -f $(BIN)/jotta-canary $(BIN)/sync-buddy $(UNITS)/jotta-canary.service $(UNITS)/jotta-canary.timer
	systemctl --user daemon-reload

test:
	$(BIN)/jotta-canary --test

# The refresh loop re-execs sync-buddy under watch(1), which has two ways to go
# wrong that reading the script will not show you: it can recurse, and it can eat
# the exit code the canary gates on. script(1) fakes the terminal the branch turns on.
check:
	@sh -n sync-buddy && echo "ok  syntax"
	@./sync-buddy --once >/dev/null && echo "ok  --once exits 0"
	@test "$$(./sync-buddy | grep -c 'jotta sync buddy')" = 1 && \
		echo "ok  no terminal, one report, no watch"
	@# Generous timeouts: a pass costs a jotta-cli query and four journalctl reads,
	@# so it takes seconds, and the point here is the branch, not the speed.
	@timeout 30 script -qec "./sync-buddy --once" /dev/null 2>/dev/null | \
		grep -qa '\[2J' && { echo "FAIL  --once re-execs watch, so watch recurses"; exit 1; } || \
		echo "ok  --once never re-execs"
	@timeout 30 script -qec "./sync-buddy" /dev/null 2>/dev/null > /tmp/sync-buddy-check; \
	for a in 1m:bold 2m:dim 31m:red 32m:green 33m:yellow; do \
		grep -qa "\[0\?;\?$${a%%:*}" /tmp/sync-buddy-check || \
			{ echo "FAIL  watch -c dropped $${a##*:}"; rm -f /tmp/sync-buddy-check; exit 1; }; \
	done; rm -f /tmp/sync-buddy-check; echo "ok  watch keeps bold, dim and colour"

status:
	systemctl --user list-timers jotta-canary.timer
	@# systemctl status exits 3 when the unit is simply not running.
	-systemctl --user status jotta-canary.service --no-pager
