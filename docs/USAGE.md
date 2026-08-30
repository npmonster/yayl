# yayl developer guide

This is the developer-facing guide to using yayl in your Zig code.
The [README](../README.md) covers project status and quality gates.

Contents:

1. [Adding yayl to a project](#adding-yayl-to-a-project)
2. [Parse and inspect](#parse-and-inspect)
3. [Build a document](#build-a-document)
4. [Change a parsed document](#change-a-parsed-document)
5. [Byte-faithful round trips](#byte-faithful-round-trips)
6. [Editing: paths, batches, moves](#editing-paths-batches-moves)
7. [Values: schema-free data and Zig conversion](#values-schema-free-data-and-zig-conversion)
8. [Validation: optional schemas](#validation-optional-schemas)
9. [Files](#files)
10. [Events and tokens (lower levels)](#events-and-tokens-lower-levels)
11. [Memory and error model](#memory-and-error-model)
12. [Building and testing from source](#building-and-testing-from-source)

## Adding yayl to a project

yayl is a Zig 0.16 package. Every allocating call takes an allocator
explicitly. A `Document` owns its nodes and all of their strings;
`deinit` releases everything in one shot. Errors are error unions
(`error.InvalidSyntax`, ...) — when a `Diag` is attached, positioned
human-readable messages are collected too (see `yaml.Diag`).

~~~zig
const std = @import("std");
const yaml = @import("yayl");
~~~

## Parse and inspect

`yaml.parse` reads the first document of a stream; `yaml.parseAll`
reads every document (an unmanaged `std.ArrayList(Document)`;
deinitialize every document, then the list).

~~~zig
var doc = try yaml.parse(alloc,
    \\name: yayl
    \\enabled: true
    \\ports: [8080, 8443]
    \\
);
defer doc.deinit();

const root = doc.root orelse return error.EmptyDocument;
const name = root.lookup("name").?.scalarValue().?;
const ports = root.lookup("ports").?.items().?;
~~~

To learn *where* a parse failed, attach a `Diag`:

~~~zig
var d: yaml.Diag = .{ .allocator = alloc };
defer d.deinit();
if (yaml.parseDiag(alloc, input, &d)) |doc| {
    var document = doc;
    defer document.deinit();
    // ...
} else |err| {
    const report = try d.render(alloc); // "2:4: error: bad indentation"
    defer alloc.free(report);
    std.debug.print("{s}", .{report});
    return err;
}
~~~

`parseAllDiag` is the multi-document variant. Without a `Diag` only
the error is returned and nothing is spent on messages.

Nodes are a tagged union (`yaml.Node`): `.scalar`, `.mapping`,
`.sequence` or `.alias`. Accessors forward through aliases, so a
`*ref` behaves like its target:

~~~zig
switch (root.data) {
    .scalar  => |s| std.debug.print("{s}\n", .{s.value}),
    .mapping => |m| for (m.pairs.items) |p| {
        std.debug.print("{s}\n", .{p.key.scalarValue() orelse continue});
    },
    .sequence => |s| for (s.items.items) |item| { _ = item; },
    .alias    => |a| std.debug.print("*{s}\n", .{a.name}),
}
~~~

Nested lookup by key path (`pathGet`), or `node.lookup` for one key:

~~~zig
const port = doc.pathGet(&.{ "server", "port" }) orelse return error.Missing;
~~~

`yaml.resolveCoreTag(value, style)` resolves a plain scalar to its YAML
1.2.2 Core Schema tag (spec 10.3.2). Quoted scalars always resolve to
`str`.

Anchors and aliases are first-class nodes: `- &v 42` followed by
`- *v` produces a distinct alias node resolving to the anchor target
(`node.isAlias()`, `node.resolveAlias()`).

## Build a document

Create a root node, assign it to `doc.root`, then connect children
with the collection helpers. Do not allocate nodes directly;
document constructors establish ownership and parent links.

~~~zig
var doc = yaml.Document.init(alloc);
defer doc.deinit();

const root = try doc.createMapping();
doc.root = root;

const ports = try doc.createSequence();
try doc.mappingAppend(root, try doc.createScalar("ports", .plain), ports);
try doc.sequenceAppend(ports, try doc.createScalar("8080", .plain));
try doc.sequenceAppend(ports, try doc.createScalar("8443", .plain));

const output = try doc.write(alloc);
defer alloc.free(output);
~~~

Programmatically built documents emit normalized YAML.

## Change a parsed document

Create values through the document so the pool owns them, then use
the path helpers or the editor (next section).

~~~zig
var doc = try yaml.parse(alloc, "server:\n  host: localhost\n");
defer doc.deinit();

try doc.pathSet(&.{ "server", "port" }, try doc.createScalar("8080", .plain));
_ = try doc.pathDelete(&.{"legacy"});
~~~

`pathSet` creates missing intermediate mappings; its components are
mapping keys, not sequence indices.

## Byte-faithful round trips

Documents produced by `parse`/`parseAll` remember where every node
came from. `doc.write` re-emits the original bytes exactly — comments,
blank lines, quoting, key order, indentation, block scalar chomping,
anchors/aliases, tags, directives and document markers included —
unless you modified that part of the tree:

~~~zig
var doc = try yaml.parse(alloc,
    \\# service config
    \\name: api
    \\port: 8080   # user facing
    \\
);
defer doc.deinit();

try doc.pathSet(&.{"port"}, try doc.createScalar("9090", .plain));

const out = try doc.write(alloc);
defer alloc.free(out);
// out == "# service config\nname: api\nport: 9090   # user facing\n"
~~~

Modified values keep their scalar style when that is lossless: a
folded (`>`) scalar you replace with a *changed* value re-emits
folded if the content re-folds exactly, falling back to literal
(`|`) or quoted otherwise — a genuinely changed folded value may
legitimately normalize. Setting a scalar to what it already holds
(same value, style, anchor and tag) is a no-op: every source byte
is kept, flow spacing and block scalar indentation included.
Multi-document streams preserve the bytes of *all* documents; editing
one leaves the others byte-identical. Deleting an entry removes its
whole line (leading indent and trailing comment included); appends
use the sibling entries' indentation.

One case is not a plain line removal. When the deleted entry is the
first key of a mapping that is itself a sequence item, its line also
carries the `- ` indicator — and that indicator belongs to the item,
not to the entry, so it stays and the next entry moves up onto it:

~~~yaml
# before                    # after `delete $.steps[0].name`
steps:                      steps:
  - name: checkout            - uses: actions/checkout@v4
    uses: actions/checkout@v4
~~~

If a comment sits between the two entries it cannot be moved, so the
indicator keeps a line of its own instead. Editing an entry inside a
flow collection rewrites only that line, and no edit re-indents a
sibling it did not touch. These are enforced per position by
`make preservation`: every addressable edit position of the
real-world fixtures, a bounded pass over all 269 valid
yaml-test-suite corpus documents, and CRLF, BOM and no-final-newline
variants of every fixture — each output re-parsed and compared as a
semantic value tree, with shapes that legitimately normalize counted
as skips rather than asserted away. The skip summary also names the
shapes the edit path does not yet preserve — flow collections,
explicit-key entries, tagged or empty keys, tab-indented entries, and
new lines inside CRLF documents — so the gap is measured, not hidden.

## Editing: paths, batches, moves

`yaml.edit.Editor` layers a documented path grammar and atomic edits
on the document model:

| Syntax | Meaning |
| --- | --- |
| `$.a.b[0]` | mapping keys and sequence indices (`$` optional) |
| `[*]` | every child, in document order |
| `..name` | recursive descent: every `name` at any depth |
| `[?key=value]` | every child that is a mapping whose `key` equals `value` |
| `["a.b"]` / `['a.b']` | a literal key, for keys the dotted form cannot express |

The dotted form splits on `.` and `[`, so `pymdownx.highlight` reads as
two nested keys and `.defaults` as a recursive descent. Quote the key to
address it literally: `$["pymdownx.highlight"]`, `$[".defaults"]`. Either
quote character works, and a quoted segment is an ordinary key segment,
so it composes with the rest of the grammar:
`$["pymdownx.highlight"].anchor_linenums`. The empty key is addressable
this way too (`$[""]`), since `"": v` is legal YAML.

There is no escaping, so a key containing *both* `"` and `'` still
cannot be written as a path. Reach it by iterating the container's
pairs; note that `Document.pathSet`/`pathDelete` take key components but
walk mapping keys only, so they cannot reach a key nested under a
sequence item.

~~~zig
var ed = yaml.edit.Editor.init(&doc);

// Query: exactly one match, or every match (caller frees the slice).
const first = try ed.one("$.store.book[0].title");
const titles = try ed.all("$.store.book[*].title");

// Edits. `apply` is atomic: edits run on a deep clone of the tree
// (presentation spans included) and swap in only if ALL succeeded.
try ed.apply(&.{
    .{ .set    = .{ .path = "$.port", .value = try doc.createScalar("9090", .plain) } },
    .{ .append = .{ .sequence = "$.items", .value = try doc.createScalar("new", .plain) } },
    .{ .insert = .{ .sequence = "$.items", .position = "$.items[0]",
                   .value = try doc.createScalar("first", .plain), .before = true } },
    .{ .delete = "$.obsolete" },
    .{ .move   = .{ .from = "$.a[1]", .to = "$.b", .key = "moved" } },
});
~~~

`set` auto-creates intermediate mappings only along plain-key paths.
Setting a scalar to an identical one — same value, style, anchor and
tag — is a byte-identical no-op; a different style or tag is a real
edit. A failed batch (unknown path, wrong shape, allocation failure)
leaves the original document byte-identical. A moved node re-emits
in block layout at its destination, indented to match the file's own
convention; its structure and values survive, its internal comments
and blank lines do not. Untouched siblings stay verbatim. Moving a
node into its own subtree is rejected (`error.MoveIntoSubtree`).

## Values: schema-free data and Zig conversion

`yaml.value` is a tagged value for data-oriented work:

~~~zig
const v = try yaml.value.parseToValue(alloc, input);
defer yaml.value.freeValue(alloc, v);

const count = v.get("count").?.int;      // i64
const tags  = v.get("tags").?.sequence;  // []const Value
~~~

Plain scalars use the library's YAML 1.2 core-schema resolver. Quoted
`"42"` stays a string, and integers beyond i64 keep their exact text
(`.bigint`).
`Value` is a semantic data model; it does not retain presentation,
tags, anchors, aliases, or exact float spelling. Use `Document` for
byte-faithful editing.

Convert straight into Zig types and back:

~~~zig
const Config = struct {
    name: []const u8,
    replicas: u8 = 1,          // defaults apply
    enabled: bool,
    mode: enum { fast, slow }, // enums match by name
};

var doc = try yaml.parse(alloc, input);
defer doc.deinit();
const val = try yaml.value.nodeToValue(alloc, doc.root.?);
defer yaml.value.freeValue(alloc, val);
const cfg = try yaml.value.toZig(Config, alloc, val);
defer yaml.value.deinitZig(Config, alloc, cfg);

// Zig values -> YAML. fromZig duplicates all referenced storage:
const v = try yaml.value.fromZig(alloc, cfg);
defer yaml.value.freeValue(alloc, v);
doc.root = try yaml.value.toNode(&doc, v);
~~~

## Validation: optional schemas

`yaml.schema` validates a node against a small descriptor and
produces structured violations (logical path + rule + detail). It is
opt-in: nothing pays for it unless invoked.

~~~zig
const schema = yaml.schema.Schema.map(&.{
    .{ .key = "name", .schema = &yaml.schema.Schema.str, .required = true },
    .{ .key = "port", .schema = &yaml.schema.Schema.intRange(1, 65535), .required = true },
    .{ .key = "mode", .schema = &yaml.schema.Schema.strEnum(&.{ "fast", "slow" }) },
});

const violations = try schema.validate(alloc, doc.root.?, "$");
defer yaml.schema.freeViolations(alloc, violations);
for (violations) |viol| {
    std.debug.print("{s}: {s} ({s})\n", .{ viol.path, viol.rule, viol.detail });
}
~~~

Use `Schema.mapStrict` to also reject undeclared keys.

## Files

`yaml.file` wraps parsing and writing with production safeguards:
reads are bounded (`max_bytes`, so a huge file fails with
`error.StreamTooLong`, not OOM) and writes use atomic replacement (a
sibling temp file with an exclusive name, file sync, then rename): a
crash never exposes torn content. This is torn-write protection, not a
power-loss durability guarantee; sync the containing directory if your
application requires that guarantee.

~~~zig
var threaded: std.Io.Threaded = .init(alloc, .{});
defer threaded.deinit();
const io = threaded.io();

var doc = try yaml.file.parseFile(alloc, io, "config.yaml", yaml.file.max_bytes_default);
defer doc.deinit();

// ... edit ...
try yaml.file.writeFile(&doc, alloc, io, "config.yaml");
~~~

## Events and tokens (lower levels)

The layering mirrors libfyaml and is public:

* `yaml.Scanner` — token stream (`peekToken`/`skipToken`).
* `yaml.Parser` — pull-based event stream (`nextEvent`), suitable for
  processing large multi-document inputs without building trees.
  Streaming *input chunking* is deliberately out of scope in v1 (see
  the decision note in `src/file.zig`'s module docs): the event API
  streams events; the input itself lives in memory.
* `yaml.markup` — the source-span arithmetic behind round trips.
* Nesting is capped (`Scanner.max_nesting`, 200) and simple keys are
  length-capped, so adversarial input is rejected rather than run out
  of memory. Over-deep nesting returns `error.NestingTooDeep`; an
  over-long simple key returns `error.InvalidSyntax`.

## Memory and error model

* Every `Document` owns an arena (`yaml.Pool`); nodes, strings,
  copied source bytes, and edits live until `Document.deinit()`.
* `parseToValue`, `nodeToValue`, and `fromZig` return fully owned
  trees. Release them with `freeValue` and the same allocator.
* `toZig` owns all slice storage in its result, including
  slice-valued defaults. Release it with `deinitZig(T, alloc, value)`.
* `Schema.validate` returns an owned violation slice; release it with
  `freeViolations`. `yaml.file.readFile`, `Document.write`, and
  `Diag.render` return caller-owned buffers.
* `Scanner` borrows its input. Token and event payloads remain valid
  only until their owning scanner or parser is deinitialized.
* Allocating operations are failure-injection tested: an OOM does not
  leak partial results or leave a document half-edited.

## Building and testing from source

~~~sh
make help         # target list
make verify       # the full gate
zig-out/bin/bench tests/fixtures/serde-ci.yml 500   # throughput
~~~

The individual gates and their current numbers are in the
[README](../README.md#development).

Measured throughput (ReleaseFast, small fixtures): ~52-55 MiB/s
parse; writing an unmodified document is a verbatim slice copy.
Reproduce with `bench`; please avoid quoting performance numbers you
did not measure with it.
