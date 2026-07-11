.DEFAULT_GOAL := run

.PHONY: run build-readme download-test-assets

run:
	@set -eu; \
	found=0; \
	find [0-9][0-9][0-9][0-9] -type d -path '*/.mise/tasks' -prune 2>/dev/null \
	| while IFS= read -r tasks; do \
		found=1; \
		dir=$${tasks%/.mise/tasks}; \
		echo "==> $$dir"; \
		mise -C "$$dir" run; \
	done

build-readme:
	mise run readme:build

download-test-assets:
	mise run test-assets:download -- \
		--output-dir tests/assets v2026.07 labs v1.1.0
