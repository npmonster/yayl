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
zig fetch --save git+https://github.com/npmonster/yayl#v0.10.0
```

That records the resolved commit and a content hash in your `build.zig.zon`, so your build stays reproducible even if the tag later moves or disappears. Leave off `#v0.10.0` and you pin whatever `main` happens to be at that moment, which is rarely what you want.

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
var d: yaml.Diag = .{ .allocator = alloc };
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
- `yaml.resolveCoreTag(value, style)` resolves a plain scalar to its core-schema tag

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

- `yaml.value`: tagged semantic `Value` trees, node conversion, and Zig-native `toZig`/`fromZig` for supported scalars, structs, optionals, enums, arrays, and slices. Use `Document` when YAML presentation matters.
- `yaml.schema`: opt-in validation descriptors (types, ranges, enums, required keys) with structured violations.
- `yaml.file`: bounded file reads and atomic replacement (sibling temp file, file sync, rename). This prevents torn writes, not every form of power-loss data loss.

## Ownership

- Allocating APIs either accept an allocator directly or use one retained by their owning object.
- `Document.deinit()` releases all document-owned storage, including nodes, strings, anchors, tags, and copied source bytes.
- The caller owns buffers returned by `doc.write()`, `Diag.render()`, and `yaml.file.readFile()`; free them with the same allocator.
- `parseToValue`, `nodeToValue`, and `fromZig` return owned trees; release them with `yaml.value.freeValue()`. Release `toZig` results with `yaml.value.deinitZig()`.
- Release schema violations with `yaml.schema.freeViolations()`.
- `Scanner` borrows its input and owns transient token payloads. `Parser` owns its scanner and transient event payloads. Copy data that must outlive them into a document or caller-owned storage.

## Road to 1.0

0.9 is the hardening release: the feature set is complete and gated (conformance, byte-faithful round trips, differential parity, allocation-failure injection). 1.0 waits on real-world use, so run your workload against it and tell us what breaks. Streaming input chunking and a parse cache are deliberate non-goals for now.

## Current limitations

Deliberate for v1:

- Input has to fit in memory. Byte-faithful re-emission works by slicing the original bytes, so a document keeps a copy of its whole source; chunked input would trade that guarantee away rather than merely complicate it. The parser streams *events* (pull-based), and that layer is chunk-ready. See the note in `src/file.zig`.
- Modified subtrees normalize their internal layout when they re-emit. A multi-line flow *mapping* keeps its layout when you change a value, but adding or removing a flow entry, or replacing an item of a flow *sequence*, still collapses the collection to one line. Untouched bytes are always exact.
- Subtrees the emitter owns — brand-new ones, and moved ones — get block layout at the file's own indent width, but not the original's internal detail: a moved subtree keeps its structure and values, not the comments and blank lines that were inside it.
- No parse cache. A `Document` is mutable, so a cache would have to hand out deep clones, which is not clearly cheaper than re-parsing. See the note in `src/file.zig`.

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

The gates: 351/351 yaml-test-suite conformance with zero skips, 265/269 byte-faithful corpus round trips (4 skips: streams containing no document, so there is nothing to re-emit) plus real-world fixtures, 269/269 event-tree parity against vendored libfyaml, allocation-failure injection with zero leaks, in both Debug and ReleaseSafe.

## License

MIT. See [LICENSE](LICENSE).
