REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PACKAGES := $(REPO_ROOT)/packages

.PHONY: format
format:
	cd "$(PACKAGES)" && uv sync --group dev && uv run ruff format "$(REPO_ROOT)"
