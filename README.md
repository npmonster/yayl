# yayl

A native Zig YAML parser, document model, and emitter. yayl follows the architecture and observable behavior of [libfyaml](https://github.com/pantoniou/libfyaml), using Zig allocators, error unions, and tagged unions.

> **Status: 0.9 — feature-complete, public hardening release.** The scanner, parser, CST-backed document model, and emitter pass the full yaml-test-suite corpus (351/351), produce **byte-faithful round trips** — comments, blank lines, quoting, key order, indentation — and ship an editing API, a generic value runtime, optional schema validation, and bounded file I/O. `make verify` gates all of it.

> **Developed by agents.** Written end-to-end by AI coding agents under human direction — see the [full disclosure](#ai-development-disclosure) below.

See the [usage guide](docs/USAGE.md) for library examples and API patterns.

## AI development disclosure

yayl is developed end-to-end by AI coding agents — several of them, powered by different large language models over the course of the project — with humans leading the ideas, the review, and the release decisions. Agents plan the work on an evidence-logged card board, write the code and tests, run the quality gates, debug what fails, and review each other's output. People decide what gets built, judge every plan and result, and own what ships. Every change reaches `main` through the same gates: corpus conformance, byte-faithful round trips, differential parity against libfyaml, allocation-failure injection, and independent review passes recorded on each card.

We say this openly because it shaped how the project was built. The playbook the agents follow lives in [AGENTS.md](AGENTS.md), and the audit trail of every card is committed with the source. If AI-developed code is a dealbreaker for you, this library is not for you — no hard feelings.

### Acknowledgements — libfyaml

yayl neither links nor embeds [libfyaml](https://github.com/pantoniou/libfyaml), but it exists thanks to the path that project opened. libfyaml's architecture is the blueprint this port follows — the scanner → parser → document model → emitter layering, the event model, and round-trip-faithful emission backed by source spans — and its observable behavior is the specification yayl is tested against: a vendored libfyaml (development environments only) powers the differential gate that compares event streams across the whole yaml-test-suite corpus. We are thankful and indebted to libfyaml and its contributors.

## Requirements

- Zig 0.16.0 or later in the 0.16 series

## Install

Add the package, pinned to a release:

```sh
zig fetch --save git+https://github.com/npmonster/yayl#v0.9.0
```

This records the resolved commit and a content hash in your
`build.zig.zon`, so the build is reproducible even if the tag later
moves or disappears. Omitting `#v0.9.0` pins whatever `main` happens to
be at that moment, which is rarely what you want.

Import its module in your `build.zig`:

```zig
const yayl_dep = b.dependency("yayl", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("yayl", yayl_dep.module("yayl"));
```

Then import it in Zig source:

```zig
const yaml = @import("yayl");
```

## Quick start

```zig
const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    var doc = try yaml.parse(alloc, "name: yayl\nlang: zig\n");
    defer doc.deinit();

    const name = doc.pathGet(&.{"name"}).?.scalarValue().?;
    std.debug.print("name = {s}\n", .{name});

    const output = try doc.write(alloc);
    defer alloc.free(output);
    std.debug.print("{s}", .{output});
}
```

## Parse

`yaml.parse(allocator, input) !Document` reads the first document in a YAML stream.

`yaml.parseAll(allocator, input) !std.ArrayList(Document)` reads every document. Deinitialize each document, then the list:

```zig
var docs = try yaml.parseAll(alloc, input);
defer {
    for (docs.items) |*doc| doc.deinit();
    docs.deinit(alloc);
}
```

For positioned error messages, attach a `Diag` with `yaml.parseDiag`:

```zig
var d: yaml.Diag = .{ .alloc = alloc };
defer d.deinit();
if (yaml.parseDiag(alloc, input, &d)) |doc| {
    var document = doc;
    defer document.deinit();
    // ...
} else |err| {
    const report = try d.render(alloc); // "2:4: error: ..."
    defer alloc.free(report);
    std.debug.print("{s}", .{report});
    return err;
}
```

The root node is `doc.root`. Nodes are scalars, mappings, or sequences; use accessors to inspect them safely:

```zig
const root = doc.root orelse return error.EmptyDocument;
const enabled = root.lookup("enabled").?.scalarValue().?;
const items = root.lookup("items").?.items().?;
_ = enabled;
_ = items;
```

Useful node APIs:

- `scalarValue()`, `pairs()`, `items()`
- `lookup(key)` and `byPath(path)`
- `yaml.scalarKind(value, style)` for YAML core-schema classification

## Build and modify documents

A `Document` owns its nodes and strings. Create nodes through the document, then attach them with its mutation APIs:

```zig
var doc = yaml.Document.init(alloc);
defer doc.deinit();

const root = try doc.createMapping();
doc.root = root;

try doc.pathSet(
    &.{ "server", "host" },
    try doc.createScalar("localhost", .plain),
);
try doc.pathSet(
    &.{ "server", "port" },
    try doc.createScalar("8080", .plain),
);
```

Available mutation APIs: `createScalar`, `createMapping`, `createSequence`, `mappingAppend`, `mappingRemove`, `sequenceAppend`, `sequenceInsert`, `sequenceRemove`, `pathSet`, and `pathDelete`.

## Write — byte-faithful round trips

`doc.write(allocator) ![]u8` serializes a document. For documents produced by `parse`/`parseAll`, untouched parts re-emit **byte for byte**: comments, blank lines, quoting, key order, indentation, anchors/aliases, tags, directives, document markers, block scalar chomping. Modified values re-emit in place, keeping their style when lossless (a folded scalar stays folded, for example).

```zig
var doc = try yaml.parse(alloc, "# config\nport: 8080 # user facing\n");
defer doc.deinit();
try doc.pathSet(&.{"port"}, try doc.createScalar("9090", .plain));
const out = try doc.write(alloc); // "# config\nport: 9090 # user facing\n"
defer alloc.free(out);
```

## Edit with paths, batch atomically

`yaml.edit.Editor` queries with a path grammar (`$.a.b[0]`, `[*]`,
`..name`, `[?key=value]`) and applies edits — set, delete, insert,
append, move — as an atomic batch over a deep clone of the tree:

```zig
var ed = yaml.edit.Editor.init(&doc);
try ed.apply(&.{
    .{ .set = .{ .path = "$.port", .value = try doc.createScalar("9090", .plain) } },
    .{ .delete = "$.legacy" },
});
```

A failed batch leaves the original document byte-identical.

## Values, schemas, files

- `yaml.value` — tagged `Value`, lossless parse-to-value / value-to-node, and Zig-native `toZig`/`fromZig` for structs, optionals, enums, slices.
- `yaml.schema` — optional validation descriptors (types, ranges, enums, required keys) with structured violations.
- `yaml.file` — bounded file reads and atomic writes (temp + fsync + rename).

## Ownership

- Pass an allocator to all allocating operations.
- `Document.deinit()` releases every node, string, anchor, and tag owned by the document.
- Values returned by `doc.write()` and `Diag.render()` must be freed with the allocator supplied to those calls.
- `Scanner` and `Parser` own transient token/event data; copy data that must outlive them into a document.

## Road to 1.0

0.9 is the public hardening release: the feature set is complete and gated (conformance, byte-faithful round trips, differential parity, allocation-failure injection). 1.0 follows real-world use — run your workload against it and tell us what breaks. Streaming input chunking and a parse cache stay deliberate non-goals for now.

## Current limitations (deliberate v1 scope)

- Input must fit in memory; the parser streams *events* (pull-based), not input chunks (documented decision in `src/file.zig`).
- Re-emitted (modified) subtrees normalize their internal layout — e.g. multi-line flow collapses to one line; untouched bytes are exact.
- Moved subtrees re-emit normalized at their destination.
- No parse cache in v1 (documented decision).

## Development

```sh
make verify        # fmt + compile + tests (Debug & ReleaseSafe)
                   #   + corpus conformance (351/351)
                   #   + byte-faithful round-trip gate
make roundtrip     # emit(parse(x)) == x over corpus + fixtures
make differential  # event-stream parity vs libfyaml (needs a C compiler)
zig build examples # compile-checked example programs (zig-out/bin)
zig build bench    # throughput CLI
```

Quality gates: 351/351 yaml-test-suite conformance (zero skips), 265/265 byte-faithful corpus round trips plus real-world fixtures, 269/269 event-tree parity against vendored libfyaml, allocation-failure injection with zero leaks, Debug and ReleaseSafe.

## License

MIT. See [LICENSE](LICENSE).
