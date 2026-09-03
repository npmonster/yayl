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
7. [Comments: read and write](#comments-read-and-write)
8. [Values: schema-free data and Zig conversion](#values-schema-free-data-and-zig-conversion)
9. [Validation: optional schemas](#validation-optional-schemas)
10. [Files](#files)
11. [Events and tokens (lower levels)](#events-and-tokens-lower-levels)
12. [Memory and error model](#memory-and-error-model)
13. [Building and testing from source](#building-and-testing-from-source)

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

**An explicit tag outranks that.** `!!str 42` converts to the string
`"42"` and validates against `Schema.str`; `!!int '7'` converts to the
integer `7` despite the quotes. The tag is an assertion about the value,
so conversion and validation both honour it over the plain resolution.
A tag whose content cannot be read as the type it names (`!!int abc`) is
`error.TypeMismatch`. Non-core tags (`!myapp/thing`) are carried on the
node and preserved on emission, but do not affect resolution.

Anchors and aliases are first-class nodes: `- &v 42` followed by
`- *v` produces a distinct alias node resolving to the anchor target
(`node.isAlias()`, `node.resolveAlias()`).

An alias may name an *enclosing* anchor, which makes the document
cyclic — `&a [*a]` parses. The recursive walks are depth-bounded so this
is `error.NestingTooDeep` rather than a crash, but if you resolve
aliases yourself, do not recurse without your own bound.

Building a cycle through the document API is refused: `sequenceAppend`
and `mappingAppend` return `error.WouldCycle` if the child is the target
or one of its ancestors.

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
shapes the edit path does not yet preserve — flow entry insertion and
removal (replacement is preserved), explicit-key entries, tagged or
empty keys, tab-indented entries, and new lines inside CRLF documents
— so the gap is measured, not hidden.

### Choosing the layout of new content

`doc.write` and `yaml.writeAll` take an options form — `writeOpts` and
`writeAllOpts` — that sets the indent for content the emitter lays out
itself:

~~~zig
const out = try doc.writeOpts(alloc, .{ .indent = 4 });
defer alloc.free(out);
~~~

It applies only where there are no source bytes to copy: a document you
built, or a new subtree inside a parsed one. Bytes that re-emit verbatim
are never touched by it — the round-trip guarantee outranks a layout
preference. A parsed document measures its own convention by default, so
a new subtree matches the file it lands in; set `indent` for documents
built from nothing, where there is nothing to measure. The value is
clamped to 1..8.

`EmitOptions` also carries `max_depth`, the emission depth bound
described under [Untrusted input](#untrusted-input).

### Writing a whole stream

`doc.write` writes one document. For a stream, use `yaml.writeAll`, the
counterpart to `parseAll`:

~~~zig
var docs = try yaml.parseAll(alloc, input);
defer {
    for (docs.items) |*d| d.deinit();
    docs.deinit(alloc);
}
const out = try yaml.writeAll(alloc, docs.items);
defer alloc.free(out);
// out == input, byte for byte
~~~

Do not concatenate `doc.write()` yourself. It happens to work for a
stream that was parsed as one, because the documents' source regions
are contiguous — and it silently corrupts everything else. Two
separately parsed single-document strings, or two documents you built,
carry no `---` between them, so the result re-parses as *one* document
and two mappings become one mapping with duplicate keys: valid YAML,
wrong data, no error. `writeAll` inserts a marker exactly where a
boundary is required and absent, and nothing where one already exists,
which is what keeps the round trip byte-exact.

The round-trip gate runs through `writeAll` over the whole corpus, so
that byte-exactness is checked against 265 real streams rather than a
handful of shapes.

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

To copy a subtree into a *different* document, use
`yaml.edit.cloneTreeInto(&target_doc, node)`: it deep-clones the node
into the target document's pool with presentation spans cleared, so the
copy re-emits normalized there (structure and values survive, internal
layout and comments do not — the moved-subtree contract).
`yaml.edit.cloneTree` is the same-document form used by the editor's
atomic batches; it keeps spans, and attaching its result anywhere but
the source document would make the emitter copy bytes from the wrong
source.

## Comments: read and write

Comments are addressable. Reads are raw: exactly the source bytes, a
`#` included, with no allocation — a slice into the document.

~~~zig
var doc = try yaml.parse(alloc,
    \\# service configuration
    \\name: api   # user facing
    \\port: 8080
    \\
);
defer doc.deinit();

const name = doc.pathGet(&.{"name"}).?;
const tail = name.trailingComment(&doc);   // "# user facing"
const head = name.leadingComments(&doc);   // "# service configuration"
~~~

`leadingComments` returns the own-line comment(s) immediately above the
entry, newline-joined (`"# one\n# two"`). A blank line breaks the
attachment, which is what makes "belongs to this entry" decidable. For a
pair, the value stands in for the entry: an inline value (`host:
localhost`) reads the pair's comments, and a block value (a mapping or
sequence on its own line) reads the comments above it. A container's
trailing comment is the one on its last entry's line, so the collection
and that entry read the same bytes.

Writes take the same raw form and canonicalize only the spacing:

~~~zig
try doc.setTrailingComment(name, "# renamed");
try doc.setLeadingComments(doc.pathGet(&.{"port"}).?, "# rate limit\n# in req/s");
try doc.setTrailingComment(name, null);    // null deletes
~~~

A written trailing comment re-emits as `content # text`; a written
leading block re-emits at the entry's own column, keeping the
document's line-terminator convention (CRLF stays CRLF). Re-setting the
comment a node already has is a no-op — nothing is marked and every
source byte stays — the same guarantee the edit API gives for
unchanged scalars, asserted per position by `make preservation`.
Comments work on brand-new values too: set a value with `pathSet`,
then annotate it.

Rejected with `error.InvalidSyntax`, rather than silently dropped at
emission time: comment text that is not one raw comment (no `#`, or a
line break in a trailing comment), trailing comments on block
collections (address the last entry), on the pair's key (the comment
follows the value), on literal/folded or multi-line scalars (the value
owns its lines), and anything inside a flow collection.

Out of scope, deliberately: free-floating comments — separated from
content by a blank line, or in the document head before `---` — and
comments inside flow collections. They are preserved byte-for-byte
like all source bytes, but no node claims them. The design history is
in [docs/design/comments.md](../docs/design/comments.md).

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

The full set `toZig`/`fromZig` handle: `bool`, every int and float
width, `?T`, enums (by name), `[]const u8`, slices and arrays of a
supported element type, `*T`, structs (by field name, with defaults and
optionals honoured), tagged unions, and string-keyed maps. Anything
else is `error.UnsupportedType`.

**Dynamic mappings.** A `labels:` block whose keys are the data has no
struct to convert into. Use a string-keyed map — any of the four std
spellings works, recognised by shape:

~~~zig
const Labels = std.StringArrayHashMapUnmanaged([]const u8);
var labels = try yaml.value.toZig(Labels, alloc, val.get("labels").?);
defer yaml.value.deinitZig(Labels, alloc, labels);
~~~

Prefer the `ArrayHashMap` spellings: they keep insertion order, which
for YAML is usually the order the author wrote. Where a mapping carries
a duplicate key the **first** wins, matching `Node.lookup` — YAML
permits duplicates and this library keeps them, so a map has to choose,
and choosing the last would disagree with every other read path.

**Tagged unions** are externally tagged, as JSON does it: exactly one
entry, keyed by the active field's name. A `void` field is written as
null. Zero entries or two is `error.TypeMismatch` rather than a guess,
and an untagged union is `error.UnsupportedType` — nothing names the
active field.

~~~zig
const Source = union(enum) { path: []const u8, port: u16, inherit: void };
// port: 8080  ->  Source{ .port = 8080 }
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

The full descriptor set:

| Constructor | Accepts |
| --- | --- |
| `any`, `scalar` | anything; any scalar |
| `str`, `boolean`, `int`, `float` | core-schema types (`float` also accepts an integer) |
| `strEnum(values)` | a string from a fixed set |
| `intRange(min, max)`, `floatRange(min, max)` | a number in an inclusive range |
| `strLen(min, max)` | a string of that many **codepoints** |
| `seq(items)`, `seqLen(items, min, max)` | a sequence, optionally length-bounded |
| `map(fields)`, `mapStrict(fields)` | a mapping; `mapStrict` rejects undeclared keys |
| `nullable(inner)` | null, or `inner` |
| `allOf(b)`, `anyOf(b)`, `oneOf(b)` | every branch, at least one, exactly one |

`nullable` is not the same as a non-required field: `required = false`
lets the key be absent, `nullable` requires the key and lets its value
be null. `anyOf` and `oneOf` report a single violation naming the
composition rather than the failures of every branch, since a branch
that does not apply is not an error; `allOf` reports each failing
branch, because there each one is a real requirement.

There is no regex constraint. Zig's standard library has no regex
engine, and shipping one inside a YAML library to back a single
descriptor is the wrong trade; match the string yourself after
validation if you need it.

Validation resolves aliases and so is bounded by `Limits`, like the
value layer — see [Untrusted input](#untrusted-input) below. Branch
exploration under `anyOf`/`oneOf` shares the enclosing budget, so a
composite cannot multiply the work past the bound.

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

## Untrusted input

Every default here is sized for a config file you control. YAML that
arrives from elsewhere needs four bounds, and they live in three places
because they bound three different kinds of work.

**Parsing** — `ParseOptions`, via `yaml.parseOpts` / `parseAllOpts`:

~~~zig
var doc = try yaml.parseOpts(alloc, payload, null, .{
    .max_input_bytes = 1 << 20, // default 64 MiB
    .max_nesting = 32,          // default 200
});
defer doc.deinit();
~~~

`max_input_bytes` is checked before the input is scanned, so an
oversized stream costs nothing but the length check
(`error.InputTooLarge`). `max_nesting` counts flow levels plus block
indents and yields `error.NestingTooDeep`. Simple keys are separately
capped at 1024 characters (`error.InvalidSyntax`), per spec 7.4.2.

A NUL byte is rejected (`error.InvalidSyntax`), since YAML 1.2 does not
admit one; `.embedded_nul = .truncate` restores libyaml's cut-off-there
behaviour, which discards everything after the byte.

**Converting and validating** — `value.Limits` and `schema.Limits`.
These layers expand aliases *by copying*, so their output is a function
of the expanded tree rather than of the input: N levels each aliasing
the level above M times is M^N, and a 194-byte document reaches ~19.5k
values. Both default to `1 << 20` and return `error.LimitExceeded`:

~~~zig
const v = try yaml.value.parseToValueLimited(alloc, payload, .{ .max_values = 10_000 });
const violations = try schema.validateLimited(alloc, node, "$", .{ .max_nodes = 10_000 });
~~~

`nodeToValueLimited` takes the same bound, and `Limits.unlimited` opts
out — only for input you produced yourself.

Both also carry `max_depth` (1000), because a count of values cannot
stand in for a depth: a linear chain of N nested collections is N values
but N stack frames. Past it they return `error.NestingTooDeep`.

Deeply *built* trees are the obvious way to reach that, but not the only
one. An alias may name an enclosing anchor — `&a [*a]` parses, and
resolving the alias yields the sequence containing it — which is a cycle
of unbounded depth reachable from eight bytes of input. `max_nesting`
does not stop it: that cap is on syntactic nesting, not on the alias
graph. So the depth bound matters for parsed input too, and the same
applies to `$..key` descent, which resolves aliases as it walks
(`edit.max_walk_depth`, also 1000).

`Limits.unlimited` lifts the depth bound too, which re-arms the stack
overflow it prevents; to lift only the value budget, set `max_values`
(or `max_nodes`) and leave `max_depth` alone.

**Emitting** — `Emitter.max_depth` (1000). Parsing cannot produce a tree
deep enough to reach it, since `max_nesting` is lower; this bounds
documents you *built*, through `createSequence`/`sequenceAppend` or
`value.toNode`. Past it, `Document.write` returns `error.NestingTooDeep`
instead of overflowing the stack. Conversion, validation and the edit
walks carry the same default, but the emitter admits two levels fewer:
it charges extra where emission crosses between its faithful, normalized
and flow modes. At default limits a 999-node path converts and validates
and then fails to emit, so treat the bounds as close, not identical.

**Reading files** — `yaml.file` applies its own `max_bytes` (64 MiB) at
read time, before the bytes reach the parser.

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
sh scripts/bench-corpus.sh      # hot paths over fixtures + corpus (machine lines)
zig build fuzz -- 12345 100000  # deterministic long-run fuzz harness
~~~

The fuzz harness also runs as a bounded smoke inside `zig build test`,
so every test run fuzzes something. Its contract: mutated inputs parse
or return a typed error; inputs that parse emit, re-parse, and are
write-idempotent. Failures print the seed and iteration, so any crash
is reproducible by rerunning with the same seed.

The individual gates and their current numbers are in the
[README](../README.md#development).

Measured throughput (ReleaseFast, small fixtures): ~52-55 MiB/s
parse; writing an unmodified document is a verbatim slice copy.
Reproduce with `bench`; please avoid quoting performance numbers you
did not measure with it.
