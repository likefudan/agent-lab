SHELL := /usr/bin/env bash

.PHONY: validate test-static test-smoke test-integration test-offline test

validate:
	@bash scripts/validate-config.sh

test-static:
	@if [[ ! -x tests/static/run.sh ]]; then \
		echo "test-static is not implemented yet: tests/static/run.sh is missing" >&2; \
		exit 69; \
	fi
	@tests/static/run.sh

test-smoke:
	@if [[ ! -x tests/smoke/run.sh ]]; then \
		echo "test-smoke is not implemented yet: tests/smoke/run.sh is missing" >&2; \
		exit 69; \
	fi
	@tests/smoke/run.sh

test-integration:
	@if [[ ! -x tests/integration/run.sh ]]; then \
		echo "test-integration is not implemented yet: tests/integration/run.sh is missing" >&2; \
		exit 69; \
	fi
	@tests/integration/run.sh

test-offline:
	@if [[ ! -x tests/integration/test-offline.sh ]]; then \
		echo "test-offline is not implemented yet: tests/integration/test-offline.sh is missing" >&2; \
		exit 69; \
	fi
	@tests/integration/test-offline.sh

test: test-static test-smoke
