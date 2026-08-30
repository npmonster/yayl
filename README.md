# yayl

A YAML parser, document model, and emitter for Zig. Parse a config, change one value, write it back, and every byte you didn't touch comes out exactly as it went in: comments, blank lines, quoting, key order, indentation.

That last part is the point. Most YAML libraries parse into a plain map and drop everything else, so writing the file back reformats it and your comments are gone. yayl keeps the source layout in the tree and re-emits from it.

> **Status: 0.9, feature complete.** Scanner, parser, CST-backed document model, and emitter. Passes the full yaml-test-suite corpus (351/351), does byte-faithful round trips, and ships an editing API, a value runtime, optional schema validation, and bounded file I/O. `make verify` gates all of it.

> **Written by AI agents** under human direction. See the [disclosure](#ai-development-disclosure) below.

See the [usage guide](docs/USAGE.md) for more examples and API patterns.

## AI development disclosure

Every line of yayl was written by AI coding agents. Several of them, on different models, over the life of the project. Humans decided what to build, reviewed every plan and every result, and own what ships.

In practice: agents plan the work on a card board, write the code and tests, run the quality gates, debug what breaks, and review each other's output. Nothing lands on `main` without passing corpus conformance, byte-faithful round trips, differential parity against libfyaml, and allocation-failure injection. Every card keeps its audit trail, committed next to the source. The playbook the agents follow is in [AGENTS.md](AGENTS.md).

We put this up front so you can decide how you feel about it. If AI-written code is a dealbreaker for you, this library isn't for you. No hard feelings.

### Acknowledgements: libfyaml

yayl started life as a port of [libfyaml](https://github.com/pantoniou/libfyaml) and owes that project the design. The layering (scanner, parser, document model, emitter), the event model, and round-trip-faithful emission backed by source spans all came from there. Without it this library would not exist.

It has since grown its own editing API, value runtime, schema layer, and file I/O, and libfyaml's role today is the reference we test against. A vendored checkout (development only) drives the differential gate that compares event streams across the whole corpus. yayl neither links nor embeds it, and nothing from it ships in the package. Thanks to libfyaml and its contributors.

## Requirements

Zig 0.16.0 or later in the 0.16 series.

## Install

Add the package, pinned to a release:

```sh
zig fetch --save git+https://github.com/npmonster/yayl#v0.9.0
```

That records the resolved commit and a content hash in your `build.zig.zon`, so your build stays reproducible even if the tag later moves or disappears. Leave off `#v0.9.0` and you pin whatever `main` happens to be at that moment, which is rarely what you want.

Wire the module into your `build.zig`:

```zig
const yayl_dep = b.dependency("yayl", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("yayl", yayl_dep.module("yayl"));
```

Then import it:

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

`yaml.parse(allocator, input) !Document` reads the first document in a stream.

`yaml.parseAll(allocator, input) !std.ArrayList(Document)` reads every document. Deinit each document, then the list:

```zig
var docs = try yaml.parseAll(alloc, input);
defer {
    for (docs.items) |*doc| doc.deinit();
    docs.deinit(alloc);
}
```

Want positioned error messages? Attach a `Diag` and use `yaml.parseDiag`:

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

The root node is `doc.root`. Nodes are scalars, mappings, or sequences. Use the accessors to inspect them safely:

```zig
const root = doc.root orelse return error.EmptyDocument;
const enabled = root.lookup("enabled").?.scalarValue().?;
const items = root.lookup("items").?.items().?;
_ = enabled;
_ = items;
```

The node APIs you'll reach for most:

- `scalarValue()`, `pairs()`, `items()`
- `lookup(key)` and `byPath(path)`
- `yaml.scalarKind(value, style)` for YAML core-schema classification

## Build and modify documents

A `Document` owns its nodes and strings. Create nodes through the document, then attach them:

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

The full set: `createScalar`, `createMapping`, `createSequence`, `mappingAppend`, `mappingRemove`, `sequenceAppend`, `sequenceInsert`, `sequenceRemove`, `pathSet`, `pathDelete`.

## Write: byte-faithful round trips

`doc.write(allocator) ![]u8` serializes a document. For anything that came out of `parse` or `parseAll`, the parts you didn't touch re-emit **byte for byte**: comments, blank lines, quoting, key order, indentation, anchors and aliases, tags, directives, document markers, block scalar chomping. Values you did change re-emit in place and keep their style where that's lossless, so a folded scalar stays folded.

```zig
var doc = try yaml.parse(alloc, "# config\nport: 8080 # user facing\n");
defer doc.deinit();
try doc.pathSet(&.{"port"}, try doc.createScalar("9090", .plain));
const out = try doc.write(alloc); // "# config\nport: 9090 # user facing\n"
defer alloc.free(out);
```

## Edit with paths, batch atomically

`yaml.edit.Editor` queries with a path grammar (`$.a.b[0]`, `[*]`, `..name`, `[?key=value]`) and applies edits (set, delete, insert, append, move) as an atomic batch over a deep clone of the tree:

```zig
var ed = yaml.edit.Editor.init(&doc);
try ed.apply(&.{
    .{ .set = .{ .path = "$.port", .value = try doc.createScalar("9090", .plain) } },
    .{ .delete = "$.legacy" },
});
```

If a batch fails, the original document is left byte-identical.

## Values, schemas, files

- `yaml.value`: tagged `Value`, lossless parse-to-value and value-to-node, plus Zig-native `toZig` and `fromZig` for structs, optionals, enums, and slices.
- `yaml.schema`: optional validation descriptors (types, ranges, enums, required keys) with structured violations.
- `yaml.file`: bounded file reads and atomic writes (temp, fsync, rename).

## Ownership

- Pass an allocator to every allocating operation.
- `Document.deinit()` releases every node, string, anchor, and tag the document owns.
- Free what `doc.write()` and `Diag.render()` hand back, using the allocator you passed them.
- `Scanner` and `Parser` own transient token and event data. Copy anything that needs to outlive them into a document.

## Road to 1.0

0.9 is the hardening release: the feature set is complete and gated (conformance, byte-faithful round trips, differential parity, allocation-failure injection). 1.0 waits on real-world use, so run your workload against it and tell us what breaks. Streaming input chunking and a parse cache are deliberate non-goals for now.

## Current limitations

Deliberate for v1:

- Input has to fit in memory. The parser streams *events* (pull-based), not input chunks. See the note in `src/file.zig`.
- Modified subtrees normalize their internal layout when they re-emit. Multi-line flow collapses to one line, for example. Untouched bytes are still exact.
- Moved subtrees re-emit normalized at their destination.
- No parse cache.

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

The gates: 351/351 yaml-test-suite conformance with zero skips, 265/265 byte-faithful corpus round trips plus real-world fixtures, 269/269 event-tree parity against vendored libfyaml, allocation-failure injection with zero leaks, in both Debug and ReleaseSafe.

## License

MIT. See [LICENSE](LICENSE).
