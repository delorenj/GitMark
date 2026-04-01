PREFIX ?= $(HOME)/.local
CONFIG_DIR ?= $(HOME)/.config/GitMark
BIN_DIR = $(PREFIX)/bin

SCRIPTS = git-checkpoint git-ai-resolver

.PHONY: install uninstall install-lefthook

install:
	@echo "Installing GitMark..."
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
	@$(MAKE) install-lefthook
	@echo ""
	@echo "Done! Commands available: git-checkpoint, git-ai-resolver"
	@echo "Config: $(CONFIG_DIR)/config.toml"

uninstall:
	@echo "Uninstalling GitMark..."
	@for script in $(SCRIPTS); do \
		rm -f $(BIN_DIR)/$$script; \
		echo "  Removed $(BIN_DIR)/$$script"; \
	done
	@echo "Config preserved at $(CONFIG_DIR)/config.toml"
	@echo "Done."

install-lefthook:
	@echo "Setting up lefthook pre-commit hooks..."
	@if command -v lefthook >/dev/null 2>&1; then \
		lefthook install; \
		echo "  ✓ Lefthook hooks installed"; \
	else \
		echo "  ⚠️  lefthook not found. Install it to enable pre-commit hooks:"; \
		echo "     curl -1sLf 'https://dl.cloudsmith.io/public/evilmartians/lefthook/setup.deb.sh' | sudo -E bash"; \
		echo "     sudo apt install lefthook"; \
		echo "     # Or via npm: npm install -g @evilmartians/lefthook"; \
		echo "     # Or via brew: brew install lefthook"; \
	fi
