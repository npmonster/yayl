# yayl

A YAML parser, document model, and emitter for Zig. Parse a config, change one value, write it back, and every byte you didn't touch comes out exactly as it went in: comments, blank lines, quoting, key order, indentation.

Most YAML libraries parse into a plain map and drop everything else, so writing the file back reformats it and your comments are gone. yayl keeps the source layout in the tree and re-emits from it.

> **Status: feature complete.** Scanner, parser, a document model that keeps source spans, and an emitter. Passes the full yaml-test-suite corpus, does byte-faithful round trips, and ships an editing API, a value runtime, optional schema validation, and bounded file I/O. `make verify` gates all of it; the numbers are under [Development](#development).

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

Zig 0.16.x is supported; `build.zig.zon` sets 0.16.0 as the minimum, and CI pins 0.16.0 exactly.

## Install

Add the package, pinned to a release:

```sh
zig fetch --save git+https://github.com/npmonster/yayl#v0.15.0
```

That records the resolved commit and a content hash in your `build.zig.zon`, so your build stays reproducible even if the tag later moves or disappears. Leave off `#v0.15.0` and you pin whatever `main` happens to be at that moment, which is rarely what you want.

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

For positioned error messages, attach a `Diag` and use `yaml.parseDiag`:

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

### Untrusted input

The defaults are sized for a config file you control. For YAML that arrives from somewhere else, set the bounds explicitly with `yaml.parseOpts` (or `parseAllOpts`):

```zig
var doc = try yaml.parseOpts(alloc, payload, null, .{
    .max_input_bytes = 1 << 20, // default 64 MiB
    .max_nesting = 32,          // default 200, flow levels plus block indents
});
defer doc.deinit();
```

Oversized input fails with `error.InputTooLarge` before anything is scanned, and a nesting bomb with `error.NestingTooDeep`. A NUL byte is rejected as `error.InvalidSyntax`, since YAML 1.2 does not admit one; pass `.embedded_nul = .truncate` for libyaml's cut-off-at-the-NUL behaviour, remembering it discards everything after it.

Two other bounds matter once you go past the tree: `value.Limits` and `schema.Limits` bound alias expansion (those layers expand by copying, so output is not bounded by input size), and `Emitter.max_depth` bounds emission of documents you built yourself rather than parsed.

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

For a whole stream use `yaml.writeAll(allocator, docs)`, the counterpart to `parseAll`:

```zig
const out = try yaml.writeAll(alloc, docs.items);
defer alloc.free(out);
```

`writeAll(parseAll(input))` reproduces `input` byte for byte. Do not concatenate `doc.write()` yourself: documents with no `---` between them — two separately parsed strings, or two you built — merge into a single document, so two mappings silently become one mapping with duplicate keys. `writeAll` inserts a marker exactly where one is required and absent, and nothing where a boundary is already there.

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

- `yaml.value`: tagged semantic `Value` trees, node conversion, and Zig-native `toZig`/`fromZig` for scalars, structs, optionals, enums, arrays, slices, pointers, tagged unions, and string-keyed maps for mappings whose keys are the data. Use `Document` when YAML presentation matters.
- `yaml.schema`: opt-in validation descriptors (types, numeric and length ranges, enums, required keys, `nullable`, and `allOf`/`anyOf`/`oneOf`) with structured violations.
- `yaml.file`: bounded file reads and atomic replacement (sibling temp file, file sync, rename). This prevents torn writes, not every form of power-loss data loss.

## Ownership

- Allocating APIs either accept an allocator directly or use one retained by their owning object.
- `Document.deinit()` releases all document-owned storage, including nodes, strings, anchors, tags, and copied source bytes.
- The caller owns buffers returned by `doc.write()`, `Diag.render()`, and `yaml.file.readFile()`; free them with the same allocator.
- `parseToValue`, `nodeToValue`, and `fromZig` return owned trees; release them with `yaml.value.freeValue()`. Release `toZig` results with `yaml.value.deinitZig()`.
- Release schema violations with `yaml.schema.freeViolations()`.
- `Scanner` borrows its input and owns transient token payloads. `Parser` owns its scanner and transient event payloads. Copy data that must outlive them into a document or caller-owned storage.

## Road to 1.0

The feature set is complete and gated. 1.0 waits on real-world use: run your workload against it and tell us what breaks. Streaming input chunking and a parse cache are deliberate non-goals for now.

## Current limitations

Deliberate for v1:

- Input has to fit in memory. Byte-faithful re-emission works by slicing the original bytes, so a document keeps a copy of its whole source; chunked input would trade that guarantee away rather than merely complicate it. The parser streams *events* (pull-based), and that layer is chunk-ready. See the note in `src/file.zig`.
- Modified subtrees normalize their internal layout when they re-emit. Replacing a value keeps the layout of a multi-line flow collection, mapping or sequence alike. Adding or removing a flow entry still collapses the collection to one line. Untouched bytes are always exact.
- Subtrees the emitter owns — brand-new ones, and moved ones — get block layout at the file's own indent width, but not the original's internal detail: a moved subtree keeps its structure and values, not the comments and blank lines that were inside it.
- No parse cache. A `Document` is mutable, so a cache would have to hand out deep clones, which is not clearly cheaper than re-parsing. See the note in `src/file.zig`.
- Emission buffers the whole output; there is no writer-based sink. This is not an oversight to be tidied up later: byte-faithful emission needs random access to what it has already written — it inserts separators and newlines behind the cursor — so a forward-only writer cannot express it. `doc.write` and `yaml.writeAll` return an owned slice, and `yaml.file.writeFile` puts it on disk atomically.
- Duplicate mapping keys are kept, not rejected. YAML 1.2 §3.2.1.1 requires keys to be unique, but real-world files carry duplicates and dropping one silently is worse than surfacing it. Both entries survive a round trip; `lookup` and path reads return the first.
- Merge keys (`<<: *base`) are not resolved. `<<` parses as an ordinary key whose value is an alias, which is correct for YAML 1.2 — merge keys are a 1.1-era extension — but it will surprise anyone arriving from Kubernetes or GitLab configs, so it is called out rather than left to be discovered.
- `yaml.value` and `yaml.schema` bound alias expansion. They expand aliases by copying, so output is a function of the expanded tree rather than the input; both cap that by default and return `error.LimitExceeded` past it. See the memory notes in [docs/USAGE.md](docs/USAGE.md).

## Development

```sh
make verify        # every gate below except differential
make conformance   # yaml-test-suite corpus
make roundtrip     # emit(parse(x)) == x over corpus + fixtures
make preservation  # an edit changes only the lines it should (fixtures only)
make consume       # build a package against the packaged library (.paths check)
make differential  # event-stream parity vs libfyaml (needs a C compiler)
make examples      # compile-checked example programs (zig-out/bin)
zig build bench    # throughput CLI (scripts/bench-corpus.sh: fixtures + corpus)
zig build fuzz     # deterministic long-run fuzz harness (smoke runs in `test`)
```

The gates, in both Debug and ReleaseSafe:

| Gate | Result |
| --- | --- |
| yaml-test-suite conformance | 351/351, zero skips |
| byte-faithful round trips | 265/269 (4 skips: streams containing no document, so there is nothing to re-emit) plus real-world fixtures |
| edit preservation | every addressable edit position across the real-world fixtures |
| event-tree parity vs libfyaml | 269/269 compared, zero mismatches |
| allocation-failure injection | zero leaks |

## License

MIT. See [LICENSE](LICENSE).
