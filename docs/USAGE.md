# Using yayl

This guide covers the public document API. Start with [README](../README.md) for installation and project status.

~~~zig
const std = @import("std");
const yaml = @import("yayl");
~~~

Every allocating call receives an allocator. A Document owns its nodes and strings; call deinit once when finished.

## Parse a document

yaml.parse reads the first document in a stream.

~~~zig
var doc = try yaml.parse(
    alloc,
    \\name: yayl
    \\enabled: true
    \\ports: [8080, 8443]
    \\,
);
defer doc.deinit();

const root = doc.root orelse return error.EmptyDocument;
const name = root.lookup("name").?.scalarValue().?;
std.debug.print("{s}\n", .{name});
~~~

A node is a scalar, mapping, or sequence. Use the optional accessors when the expected shape is known:

~~~zig
const enabled = root.lookup("enabled").?.scalarValue().?;
const ports = root.lookup("ports").?.items().?;

for (ports) |port| {
    std.debug.print("port: {s}\n", .{port.scalarValue().?});
}
_ = enabled;
~~~

Use lookup for one mapping key and byPath or Document.pathGet for nested mapping keys:

~~~zig
const port = doc.pathGet(&.{ "server", "port" }) orelse return error.MissingPort;
const value = port.scalarValue().?;
_ = value;
~~~

## Inspect node types

Use nodeType for a quick check, or switch on node.data when behavior depends on the payload.

~~~zig
switch (root.data) {
    .scalar => |scalar| std.debug.print("scalar: {s}\n", .{scalar.value}),
    .mapping => |mapping| {
        for (mapping.pairs.items) |pair| {
            const key = pair.key.scalarValue() orelse continue;
            std.debug.print("key: {s}\n", .{key});
        }
    },
    .sequence => |sequence| {
        std.debug.print("{} items\n", .{sequence.items.items.len});
    },
}
~~~

yaml.scalarKind(value, style) classifies a scalar according to the YAML core schema. It only resolves plain scalars; quoted values remain strings.

~~~zig
const kind = yaml.scalarKind("42", .plain); // .int
_ = kind;
~~~

## Change a parsed document

Create values through the document so they are owned by its pool, then use path helpers to replace or add values.

~~~zig
var doc = try yaml.parse(alloc, "server:\n  host: localhost\n");
defer doc.deinit();

try doc.pathSet(
    &.{ "server", "port" },
    try doc.createScalar("8080", .plain),
);

const removed = try doc.pathDelete(&.{"legacy"});
_ = removed;

const output = try doc.write(alloc);
defer alloc.free(output);
~~~

pathSet creates missing intermediate mappings. Its path components are mapping keys, not sequence indices.

## Build a document

Create a root node, assign it to doc.root, then connect children with the collection helpers.

~~~zig
var doc = yaml.Document.init(alloc);
defer doc.deinit();

const root = try doc.createMapping();
doc.root = root;

const ports = try doc.createSequence();
try doc.mappingAppend(
    root,
    try doc.createScalar("ports", .plain),
    ports,
);
try doc.sequenceAppend(ports, try doc.createScalar("8080", .plain));
try doc.sequenceAppend(ports, try doc.createScalar("8443", .plain));

const output = try doc.write(alloc);
defer alloc.free(output);
~~~

Use mappingAppend, mappingRemove, sequenceAppend, sequenceInsert, and sequenceRemove for collection changes. Do not allocate nodes directly; document constructors establish the required ownership and parent links.

## Read a multi-document stream

yaml.parseAll returns an unmanaged std.ArrayList(Document). Deinitialize every document before the list.

~~~zig
var docs = try yaml.parseAll(alloc, "---\nname: first\n---\nname: second\n");
defer {
    for (docs.items) |*doc| doc.deinit();
    docs.deinit(alloc);
}

for (docs.items) |*doc| {
    const name = doc.pathGet(&.{"name"}).?.scalarValue().?;
    std.debug.print("{s}\n", .{name});
}
~~~

## Write YAML

Document.write allocates the result with the allocator you pass. Free that result with the same allocator.

~~~zig
const output = try doc.write(alloc);
defer alloc.free(output);
std.debug.print("{s}", .{output});
~~~

The emitter retains document markers, tags, anchors, aliases, and flow versus block collection style. It may choose a different safe scalar style. It does not preserve comments, blank lines, or original whitespace.

## Parser events and diagnostics

Most programs should use yaml.parse. Use Parser when you need the event stream or positioned diagnostics.

~~~zig
var diag = yaml.Diag{ .alloc = alloc };
defer diag.deinit();

var parser = try yaml.Parser.init(alloc, &diag, input);
defer parser.deinit();

while (try parser.nextEvent()) |_| {}

const report = try diag.render(alloc);
defer alloc.free(report);
~~~

The parser and scanner own event/token payloads. Copy values into a Document if they must outlive the parser.

## Errors and limits

Public operations return Zig error unions. YAML-specific failures are exposed through yaml.YamlError; allocation failures use std.mem.Allocator.Error.

The scanner limits collection nesting to 200 levels by default and returns error.NestingTooDeep for deeper input. Input is currently read from an in-memory byte slice; streaming is not available.
