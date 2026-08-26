# yayl — Yet Another YAML Library (native Zig conversion of libfyaml)
#
# Thin convenience wrapper around `zig build`; requires Zig >= 0.16
# (see build.zig.zon). Run `make help` for the target list.

ZIG ?= zig

.DEFAULT_GOAL := help
.MAIN: help

.PHONY: help all build test test-release fmt fmt-write docs clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' Makefile

all: build test ## Validate the build system and run the full test suite

build: ## Run the build system (the library is a module; validates build.zig)
	$(ZIG) build

test: ## Run unit tests in Debug (leak-checked via std.testing.allocator)
	$(ZIG) build test

test-release: ## Run unit tests under ReleaseSafe (no Debug-only assumptions)
	$(ZIG) build test -Doptimize=ReleaseSafe

fmt: ## Check formatting of build.zig and src/ without modifying anything
	$(ZIG) fmt --check build.zig src

fmt-write: ## Apply zig fmt to build.zig and src/
	$(ZIG) fmt build.zig src

docs: ## Generate HTML documentation into zig-out/docs/
	@mkdir -p zig-out
	$(ZIG) build-lib src/yaml.zig -fno-emit-bin -femit-docs=zig-out/docs
	@echo "docs: zig-out/docs/index.html"

clean: ## Remove build artifacts (zig-out/) and the incremental cache
	rm -rf zig-cache zig-out
