#!/bin/sh
# Consume yayl the way a downstream project does.
#
# Scaffolds a throwaway package, fetches this checkout as a dependency,
# and builds a program against the published module. `zig fetch` on a
# directory runs the same packaging path as a git fetch -- it applies
# `.paths` from build.zig.zon and produces a content-hashed tarball --
# so this catches the failure the in-tree suite cannot see: a source
# file missing from `.paths` keeps every local gate green while every
# dependent fails to build.
#
# The program is the README quick start plus an edit round trip, so a
# drift between the documented API and the shipped one fails here too.
set -eu

ZIG="${ZIG:-zig}"
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/src"

cat > "$work/build.zig.zon" <<'ZON'
.{
    .name = .consumer,
    .fingerprint = 0x705b37270c38c9a5,
    .version = "0.0.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{""},
}
ZON

cat > "$work/build.zig" <<'BUILD'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("yayl", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yayl", .module = dep.module("yayl") }},
        }),
    });
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the consumer").dependOn(&run.step);
}
BUILD

cat > "$work/src/main.zig" <<'MAIN'
const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    // README quick start: parse and read a value back.
    var doc = try yaml.parse(alloc, "name: yayl\nlang: zig\n");
    defer doc.deinit();
    const name = doc.pathGet(&.{"name"}).?.scalarValue().?;
    if (!std.mem.eql(u8, name, "yayl")) return error.UnexpectedValue;

    // The headline guarantee, through the packaged artifact: an edit
    // rewrites one value and leaves every other byte alone.
    var edited = try yaml.parse(alloc, "# config\nport: 8080 # user facing\n");
    defer edited.deinit();
    try edited.pathSet(&.{"port"}, try edited.createScalar("9090", .plain));
    const out = try edited.write(alloc);
    defer alloc.free(out);
    if (!std.mem.eql(u8, out, "# config\nport: 9090 # user facing\n")) {
        std.debug.print("round trip drifted:\n{s}", .{out});
        return error.RoundTripDrift;
    }

    std.debug.print("consumer ok: parsed, edited and re-emitted byte-faithfully\n", .{});
}
MAIN

cd "$work"
"$ZIG" fetch --save=yayl "$root"
"$ZIG" build run
