SCRIPTS = claude-coffee.sh install.sh uninstall.sh tests/*.sh

.PHONY: test lint
test:  ## run every test; fakes only, never touches your real sleep settings
	sh tests/hook.test.sh
	sh tests/install.test.sh

lint:  ## shellcheck everything (brew install shellcheck)
	shellcheck $(SCRIPTS)
