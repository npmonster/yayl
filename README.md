# YAYL — Yet Another YAML Library

> *Because the others eat your comments.*
>
> By **Null Pointer Monster**

`yayl` is a YAML parser and emitter for Zig with full read and write support.
**This project was born from a direct conversion of the battle-tested C
library [libfyaml](https://github.com/pantoniou/libfyaml) to native Zig** —
module by module, behavior first. The goal is a YAML library that follows Zig
community conventions — clear ownership, tagged unions instead of C type tags,
`!T` error unions instead of integer error codes, tests living next to the
code — while keeping libfyaml's observable semantics.

> **Status:** early. A working scanner, parser, document model and emitter are
> in place and round-trip a broad, practical subset of YAML (block and flow
> collections, all scalar styles, anchors/aliases, tags, directives,
> multi-document streams). Full libfyaml feature parity — most notably
> comment-preserving round-trip editing via the CST — is the ongoing target.
> See [AGENTS.md](AGENTS.md) for the conversion roadmap and how to help.

## Credits

yayl stands on the shoulders of **libfyaml**, the feature-complete YAML 1.2
processing library written in C by **Pantelis Antoniou**
([pantoniou/libfyaml](https://github.com/pantoniou/libfyaml)), released under
the MIT license. The architecture, token/event model, and parsing strategy of
this library are a direct port of that work — every intentional deviation is
marked with a `PORT NOTE:` in the source. Huge thanks to the libfyaml project
for producing such a clean, well-structured reference implementation; a
faithful conversion would not be possible without it.

## Requirements

- Zig 0.16.x (developed against 0.16.0, the latest stable release)

## Build and test

```sh
zig build test                  # run all unit tests (Debug)
zig build test -Doptimize=ReleaseSafe
```

The library is exposed as a build module named `yayl`. To depend on it from
another package, add it in your `build.zig.zon` and wire the module in
`build.zig`, then `@import("yayl")`.

## Quick start

```zig
const std = @import("std");
const yaml = @import("yayl");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse the first document in a stream.
    var doc = try yaml.parse(alloc, "name: yayl\nlang: zig\n");
    defer doc.deinit();

    // Read by mapping-key path.
    const name = doc.pathGet(&.{"name"}).?.scalarValue().?;
    std.debug.print("name = {s}\n", .{name});

    // Serialize back to YAML text.
    const text = try doc.write(alloc);
    defer alloc.free(text);
    std.debug.print("{s}", .{text});
}
```

### Parse

- `yaml.parse(alloc, input) !Document` — first document in the stream.
- `yaml.parseAll(alloc, input) !std.ArrayList(Document)` — every document.
  The caller owns the list and must `deinit()` each document and the list.

`Document.parse` returns a tree of `yaml.Node` values. A node is a tagged
union of `scalar`, `mapping`, or `sequence`, so you can `switch` on
`node.data` or use the accessors (`isScalar`, `scalarValue`, `pairs`,
`items`, `lookup`, `byPath`).

### Write

`doc.write(alloc) ![]u8` renders the document back to YAML. The emitter picks
a safe presentation for each scalar (plain, single-quoted, double-quoted, or
literal block) and preserves anchors/aliases and flow vs. block collection
style.

### Build a document programmatically

```zig
var doc = yaml.Document.init(alloc);
defer doc.deinit();

const root = try doc.createMapping();
doc.root = root;
try doc.pathSet(&.{ "server", "host" }, try doc.createScalar("localhost", .plain));
try doc.pathSet(&.{ "server", "port" }, try doc.createScalar("8080", .plain));
```

Mutation helpers on `Document`: `createScalar`, `createMapping`,
`createSequence`, `mappingAppend`, `sequenceAppend`, `sequenceInsert`,
`mappingRemove`, `sequenceRemove`, `pathSet`, `pathDelete`, `pathGet`.

### Typed scalar inspection

`yaml.scalarKind(value, style)` classifies a plain scalar the way the YAML 1.2
core schema resolves it (`null`, `bool`, `int`, `float`, or `str`).

## Module layout

| Module          | libfyaml analogue        | Role                                   |
| --------------- | ------------------------ | -------------------------------------- |
| `pool.zig`      | `fy-pool`                | Arena allocator wrapper                |
| `diag.zig`      | `fy-diag`                | Marks, diagnostics, error set          |
| `utf8.zig`      | `fy-utf8`                | UTF-8 decode/encode/validation         |
| `ctype.zig`     | `fy-ctype`               | Byte-level character classification    |
| `token.zig`     | (token types)            | Token + scalar style definitions       |
| `scanner.zig`   | `fy-scan`                | Tokenizer (indentation, simple keys)   |
| `event.zig`     | `fy-event`               | Event definitions                      |
| `parser.zig`    | `fy-parse`               | Token stream -> event stream           |
| `document.zig`  | `fy-doc`/`fy-node`       | Event stream -> node tree + mutation   |
| `emitter.zig`   | `fy-emit`                | Node tree -> YAML text                 |
| `yaml.zig`      | `libfyaml.h`             | Public entry points                    |

## Errors

Fallible functions return Zig error unions. The shared YAML error surface is
`yaml.YamlError` (`InvalidSyntax`, `InvalidUtf8`, `InvalidEscape`,
`UnknownAlias`, `DuplicateAnchor`, `Unterminated`, and friends) merged with
`std.mem.Allocator.Error` for out-of-memory. Attach a `yaml.Diag` to the
parser to collect human-readable messages with line/column marks.

## License

MIT — chosen to stay compatible with libfyaml, the C library this project is
converted from. See [Credits](#credits).
