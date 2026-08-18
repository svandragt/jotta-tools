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
	@# Symlinked, not copied: jotta-buddy is read by hand, so edits in the clone
	@# should take effect without reinstalling. The timer runs jotta-canary
	@# unattended, which is why that one is a copy the clone cannot change.
	mkdir -p $(BIN)
	ln -sfn $(CURDIR)/jotta-buddy $(BIN)/jotta-buddy

$(TOPIC_FILE):
	@echo "Missing $@. Write your ntfy topic to it first:"
	@echo "  mkdir -p $(dir $@) && echo YOUR-TOPIC > $@"
	@exit 1

uninstall:
	systemctl --user disable --now jotta-canary.timer
	rm -f $(BIN)/jotta-canary $(BIN)/jotta-buddy $(UNITS)/jotta-canary.service $(UNITS)/jotta-canary.timer
	systemctl --user daemon-reload

test:
	$(BIN)/jotta-canary --test

# The refresh loop re-execs jotta-buddy under watch(1), which has two ways to go
# wrong that reading the script will not show you: it can recurse, and it can eat
# the exit code the canary gates on. script(1) fakes the terminal the branch turns on.
check:
	@sh -n jotta-buddy && echo "ok  syntax"
	@./jotta-buddy --once >/dev/null && echo "ok  --once exits 0"
	@test "$$(./jotta-buddy | grep -c 'jotta buddy')" = 1 && \
		echo "ok  no terminal, one report, no watch"
	@# A broken jq path would drop a whole subsystem silently, and a missing verdict
	@# reads as "nothing to report" rather than "never checked".
	@test "$$(./jotta-buddy --once | grep -cE '^  (sync|backup) ')" = 2 && \
		echo "ok  both subsystem verdicts present"
	@# Generous timeouts: a pass costs a jotta-cli query and four journalctl reads,
	@# so it takes seconds, and the point here is the branch, not the speed.
	@timeout 30 script -qec "./jotta-buddy --once" /dev/null 2>/dev/null | \
		grep -qa '\[2J' && { echo "FAIL  --once re-execs watch, so watch recurses"; exit 1; } || \
		echo "ok  --once never re-execs"
	@# Assert only the attributes that are always on screen. Naming all five failed on a
	@# quiet machine, because yellow needs a stall, a transfer or a retry loop. Comparing
	@# a direct run against a watch run failed too, and worse -- two samples taken seconds
	@# apart on a live daemon legitimately differ, so the check went red on a healthy
	@# tool. Bold is the heading and the group labels, dim is every timestamp, and one of
	@# the three colours is always present because query and action are always coloured.
	@timeout 30 script -qec "./jotta-buddy" /dev/null 2>/dev/null > /tmp/jotta-buddy-check; \
	sgr=$$(grep -oa '\[[0-9;]*m' /tmp/jotta-buddy-check | tr -d '[m' | tr ';' '\n' | sort -u); \
	rm -f /tmp/jotta-buddy-check; \
	for want in 1 2; do \
		printf '%s\n' "$$sgr" | grep -qx "$$want" || \
			{ echo "FAIL  watch dropped SGR $$want"; exit 1; }; \
	done; \
	printf '%s\n' "$$sgr" | grep -qxE '31|32|33' || \
		{ echo "FAIL  watch dropped every colour"; exit 1; }; \
	echo "ok  watch keeps bold, dim and colour"

status:
	systemctl --user list-timers jotta-canary.timer
	@# systemctl status exits 3 when the unit is simply not running.
	-systemctl --user status jotta-canary.service --no-pager
