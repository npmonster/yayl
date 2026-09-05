# yayl — Yet Another YAML Library (native Zig conversion of libfyaml)
#
# Thin convenience wrapper around `zig build`; requires Zig >= 0.16
# (see build.zig.zon). Run `make help` for the target list.

ZIG ?= zig

.DEFAULT_GOAL := help
.MAIN: help

.PHONY: help all build check test test-release examples fmt fmt-write docs corpus libfyaml conformance roundtrip preservation differential emission-oracle consume verify clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' Makefile

all: build test ## Validate the build system and run the full test suite

build: ## Run the build system (the library is a module; validates build.zig)
	$(ZIG) build

check: ## Compile the library (analyses the whole public root)
	$(ZIG) build check

test: ## Run unit tests in Debug (leak-checked via std.testing.allocator)
	$(ZIG) build test

test-release: ## Run unit tests under ReleaseSafe (no Debug-only assumptions)
	$(ZIG) build test -Doptimize=ReleaseSafe

examples: ## Build the example programs into zig-out/bin
	$(ZIG) build examples

fmt: ## Check formatting of build.zig, build.zig.zon, src/, tests/ and examples/ without modifying anything
	$(ZIG) fmt --check build.zig build.zig.zon src tests examples

fmt-write: ## Apply zig fmt to build.zig, build.zig.zon, src/, tests/ and examples/
	$(ZIG) fmt build.zig build.zig.zon src tests examples

docs: ## Generate HTML documentation into zig-out/docs/
	@mkdir -p zig-out
	$(ZIG) build-lib src/yaml.zig -fno-emit-bin -femit-docs=zig-out/docs
	@echo "docs: zig-out/docs/index.html"

corpus: ## Fetch the pinned YAML Test Suite corpus (gitignored vendor/)
	sh scripts/fetch-corpus.sh

libfyaml: ## Fetch the pinned libfyaml reference for the differential gate (gitignored vendor/)
	sh scripts/fetch-libfyaml.sh

conformance: corpus ## Run the pinned YAML Test Suite corpus through yayl
	$(ZIG) build conformance --summary all

roundtrip: corpus ## Byte-faithful round trip over the corpus and tests/fixtures
	$(ZIG) build roundtrip --summary all

preservation: ## Edit-preservation sweeps over tests/fixtures (edits change only what they should)
	$(ZIG) build preservation --summary all

differential: corpus libfyaml ## Compare yayl vs libfyaml event streams over the corpus (needs a C compiler)
	sh scripts/differential.sh

emission-oracle: corpus libfyaml ## Assert libfyaml can parse every document yayl emits (needs a C compiler)
	sh scripts/emission-oracle.sh

# The only gate that consumes the library the way a dependent does:
# `zig fetch` applies `.paths` from build.zig.zon, so a source file
# missing there keeps every other gate green while every dependent
# fails to build.
consume: ## Build a throwaway package against the packaged library (catches .paths omissions)
	sh scripts/consumer-smoke.sh

# NOTE: the sweep asserts line-level non-interference on every edit
# position in every fixture, plus weak invariants (re-parse, entry gone,
# sentinel present) and semantic value-tree equality on the skip
# categories — a skip is never silent.
verify: fmt check test test-release examples conformance roundtrip preservation consume ## Quality gate minus differential: fmt, compile, tests (Debug + ReleaseSafe), examples, corpus, round trip, edit preservation, packaged-consumer smoke

clean: ## Remove build artifacts (zig-out/) and the incremental cache
	rm -rf zig-cache .zig-cache-global zig-out
