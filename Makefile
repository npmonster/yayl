# yayl — Yet Another YAML Library (native Zig conversion of libfyaml)
#
# Thin convenience wrapper around `zig build`; uses the pinned Zig version
# (see build.zig.zon). Run `make help` for the target list.

ifndef ZIG
ZIG := $(shell sh scripts/zig-path.sh)
endif
ifeq ($(strip $(ZIG)),)
$(error Zig 0.16.0 is required; set ZIG to its executable path)
endif
export ZIG

.DEFAULT_GOAL := help
.MAIN: help

.PHONY: help all build check test test-release examples fmt fmt-write docs corpus libfyaml conformance roundtrip preservation randedit differential emission-oracle consume libyaml-compat mutation-smoke merge-differential verify clean

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

# The sweep checks exact edit boundaries, including authorized leading-tab
# replacements beside edited values; semantic-only cases are reported.
preservation: ## Edit-preservation sweeps over fixtures and corpus (edits change only what they should)
	$(ZIG) build preservation --summary all

# Random edit sequences, each written and read back; RANDEDIT_ARGS is
# `seed iterations steps` (the default matches CI; release reviews run
# additional seeds).
RANDEDIT_ARGS ?= 1 20 4
randedit: corpus ## Randomized edit differential: random edits written and read back (RANDEDIT_ARGS="seed iterations steps")
	$(ZIG) build randedit -- $(RANDEDIT_ARGS)

differential: corpus libfyaml ## Compare yayl vs libfyaml event streams over the corpus (needs a C compiler)
	sh scripts/differential.sh

emission-oracle: corpus libfyaml ## Assert libfyaml can parse every document yayl emits (needs a C compiler)
	sh scripts/emission-oracle.sh

# The emission oracle proves libfyaml can PARSE what yayl emits after
# merge resolution. It cannot prove the resolved VALUES agree -- a merge
# that picked the wrong source still emits valid YAML. This is that gate.
merge-differential: libfyaml ## Compare yayl vs libfyaml RESOLVED merge-key values (needs a C compiler)
	sh scripts/merge-differential.sh

# The only gate that consumes the library the way a dependent does:
# `zig fetch` applies `.paths` from build.zig.zon, so a source file
# missing there keeps every other gate green while every dependent
# fails to build.
consume: ## Build a throwaway package against the packaged library (catches .paths omissions)
	sh scripts/consumer-smoke.sh

libyaml-compat: ## Check edited documents with independent libyaml (needs libyaml and pkg-config)
	sh scripts/libyaml-compat.sh

mutation-smoke: ## Recheck 16 selected mutations in isolated source copies (needs Python 3)
	python3 scripts/mutation-smoke.py

verify: fmt check test test-release examples conformance roundtrip preservation consume differential merge-differential emission-oracle libyaml-compat randedit mutation-smoke ## All correctness gates, including independent parsers, random edits and targeted mutations

clean: ## Remove build artifacts (zig-out/) and the incremental cache
	rm -rf zig-cache .zig-cache-global zig-out
