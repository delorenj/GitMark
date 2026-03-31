PREFIX ?= $(HOME)/.local
CONFIG_DIR ?= $(HOME)/.config/gittyup
BIN_DIR = $(PREFIX)/bin

SCRIPTS = git-checkpoint git-ai-resolver

.PHONY: install uninstall

install:
	@echo "Installing gittyup..."
	@mkdir -p $(BIN_DIR)
	@mkdir -p $(CONFIG_DIR)
	@for script in $(SCRIPTS); do \
		chmod +x bin/$$script; \
		ln -sf $(CURDIR)/bin/$$script $(BIN_DIR)/$$script; \
		echo "  Linked $(BIN_DIR)/$$script -> $(CURDIR)/bin/$$script"; \
	done
	@if [ ! -f $(CONFIG_DIR)/config.toml ]; then \
		cp config/config.toml.default $(CONFIG_DIR)/config.toml; \
		echo "  Created $(CONFIG_DIR)/config.toml (default config)"; \
	else \
		echo "  Config already exists at $(CONFIG_DIR)/config.toml (skipped)"; \
	fi
	@echo ""
	@echo "Done! Commands available: git-checkpoint, git-ai-resolver"
	@echo "Config: $(CONFIG_DIR)/config.toml"

uninstall:
	@echo "Uninstalling gittyup..."
	@for script in $(SCRIPTS); do \
		rm -f $(BIN_DIR)/$$script; \
		echo "  Removed $(BIN_DIR)/$$script"; \
	done
	@echo "Config preserved at $(CONFIG_DIR)/config.toml"
	@echo "Done."
