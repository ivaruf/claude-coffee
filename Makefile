SCRIPTS = claude-coffee.sh install.sh uninstall.sh tests/*.sh tests/fixtures/*.sh
OSES = darwin

.PHONY: test lint
test:  ## every backend's scenarios and installer, on any machine; fakes only, never your real settings
	@for os in $(OSES); do sh tests/hook.test.sh $$os && sh tests/install-$$os.test.sh || exit 1; done

lint:  ## shellcheck everything (brew install shellcheck)
	shellcheck $(SCRIPTS)
