SCRIPTS = claude-coffee.sh install.sh uninstall.sh tests/*.sh tests/fixtures/*.sh

.PHONY: test lint
test:  ## every backend's scenarios and installer, on any machine; fakes only, never your real settings
	sh tests/run.sh

lint:  ## shellcheck everything (brew install shellcheck)
	shellcheck $(SCRIPTS)
