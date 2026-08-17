# Not ~/bin: that is a symlink into the synced folder on some machines, which
# turns installing into publishing to every host. Keep ExecStart in the service
# unit pointing at the same place if you change this.
BIN := $(HOME)/.local/bin
UNITS := $(HOME)/.config/systemd/user
TOPIC_FILE := $(HOME)/.config/jotta-canary/topic

.PHONY: install uninstall test status

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

status:
	systemctl --user list-timers jotta-canary.timer
	@# systemctl status exits 3 when the unit is simply not running.
	-systemctl --user status jotta-canary.service --no-pager
