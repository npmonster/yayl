# yayl

A native Zig YAML parser, document model, and emitter. yayl follows the architecture and observable behavior of [libfyaml](https://github.com/pantoniou/libfyaml), using Zig allocators, error unions, and tagged unions.

> **Status: early release.** The scanner, parser, document API, and emitter support practical YAML 1.2 inputs. Output is semantic, not byte-preserving: comments, whitespace, and original formatting are normalized.

See the [usage guide](docs/USAGE.md) for library examples and API patterns.

## Requirements

- Zig 0.16.0 or later in the 0.16 series

## Install

Add the package:

```sh
zig fetch --save git+https://github.com/npmonster/yayl
```

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

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

## Write

`doc.write(allocator) ![]u8` serializes a document. The returned buffer belongs to the allocator and must be freed by the caller.

The emitter preserves document markers, tags, anchors, aliases, and flow versus block collection style. It chooses a safe scalar presentation when needed.

## Ownership

- Pass an allocator to all allocating operations.
- `Document.deinit()` releases every node, string, anchor, and tag owned by the document.
- Values returned by `doc.write()` and `Diag.render()` must be freed with the allocator supplied to those calls.
- `Scanner` and `Parser` own transient token/event data; copy data that must outlive them into a document.

## Current limitations

- Input must fit in memory; streaming input is not implemented.
- Formatting is normalized. Comments, blank lines, indentation width, and other source layout are not preserved.
- Round-trip editing is semantic: `write(parse(input))` can differ textually from `input`.
- Full libfyaml parity is still in progress.

## Development

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseSafe
make verify
```

`make verify` is the project quality gate: formatting, library compilation, and Debug and ReleaseSafe tests.

## License

MIT. See [LICENSE](LICENSE).
