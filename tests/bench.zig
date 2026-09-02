//! Benchmark CLI: parse / edit / write throughput over a YAML
//! file. Reports wall-clock throughput so the docs can quote measured
//! numbers instead of claims.
//!
//! Usage: bench <file.yaml> [iterations]
//!        bench --machine <file.yaml> [iterations]
//!
//! `--machine` prints one stable line per hot path
//! (`yayl_bench op=... file=... mib_per_s=... ms_per_op=...`), which is
//! what `scripts/bench-corpus.sh` and the non-gating CI job consume.

const std = @import("std");
const yaml = @import("yayl");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const clock: std.Io.Clock = .awake;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    var machine = false;
    var first: ?[:0]const u8 = it.next();
    if (first) |a| {
        if (std.mem.eql(u8, a, "--machine")) {
            machine = true;
            first = it.next();
        }
    }
    const path = first orelse {
        std.debug.print("usage: bench [--machine] <file.yaml> [iterations]\n", .{});
        return error.Usage;
    };
    const iterations_text = it.next() orelse "20";
    const iterations: usize = @intCast(try std.fmt.parseInt(usize, iterations_text, 10));

    const input = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20));
    if (!machine) {
        std.debug.print("input: {s} ({d} bytes, {d} iterations)\n", .{ path, input.len, iterations });
    }

    // Warm up.
    {
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        const out = try doc.write(allocator);
        allocator.free(out);
    }

    var total_parsed: usize = 0;
    const t0 = std.Io.Timestamp.now(io, clock);
    for (0..iterations) |_| {
        var doc = try yaml.parse(allocator, input);
        defer doc.deinit();
        total_parsed += input.len;
    }
    const t1 = std.Io.Timestamp.now(io, clock);
    const parse_ns: u64 = @intCast(@min(t1.nanoseconds - t0.nanoseconds, std.math.maxInt(u64)));

    var doc = try yaml.parse(allocator, input);
    defer doc.deinit();
    const t2 = std.Io.Timestamp.now(io, clock);
    const total_written: usize = input.len * iterations;
    for (0..iterations) |_| {
        const out = try doc.write(allocator);
        allocator.free(out);
    }
    const t3 = std.Io.Timestamp.now(io, clock);
    const write_ns: u64 = @intCast(@min(t3.nanoseconds - t2.nanoseconds, std.math.maxInt(u64)));

    // Round trip (parse+write) and a targeted edit+write.
    const t4 = std.Io.Timestamp.now(io, clock);
    for (0..iterations) |_| {
        var d = try yaml.parse(allocator, input);
        defer d.deinit();
        const out = try d.write(allocator);
        allocator.free(out);
    }
    const t5 = std.Io.Timestamp.now(io, clock);
    const roundtrip_ns: u64 = @intCast(@min(t5.nanoseconds - t4.nanoseconds, std.math.maxInt(u64)));

    const t6 = std.Io.Timestamp.now(io, clock);
    for (0..iterations) |_| {
        var d = try yaml.parse(allocator, input);
        defer d.deinit();
        var ed = yaml.edit.Editor.init(&d);
        if (d.root) |r| {
            if (r.pairs().?.len > 0) {
                try ed.set("$.zzz_bench", try d.createScalar("1", .plain));
            }
        }
        const out = try d.write(allocator);
        allocator.free(out);
    }
    const t7 = std.Io.Timestamp.now(io, clock);
    const edit_ns: u64 = @intCast(@min(t7.nanoseconds - t6.nanoseconds, std.math.maxInt(u64)));

    _ = &total_parsed;
    const p = std.debug.print;
    if (machine) {
        // Stable, machine-readable lines (the non-gating CI job and
        // scripts/bench-corpus.sh parse these).
        p("yayl_bench op=parse file={s} mib_per_s={d:.1} ms_per_op={d:.3}\n", .{ path, mibPerS(total_parsed, parse_ns), ms(parse_ns, iterations) });
        p("yayl_bench op=write file={s} mib_per_s={d:.1} ms_per_op={d:.3}\n", .{ path, mibPerS(total_written, write_ns), ms(write_ns, iterations) });
        p("yayl_bench op=round_trip file={s} ms_per_op={d:.3}\n", .{ path, ms(roundtrip_ns, iterations) });
        p("yayl_bench op=edit_write file={s} ms_per_op={d:.3}\n", .{ path, ms(edit_ns, iterations) });
        return;
    }
    p("parse:      {d:>6.1} MiB/s ({d:.1} ms/op)\n", .{
        mibPerS(total_parsed, parse_ns), ms(parse_ns, iterations),
    });
    p("write:      {d:>6.1} MiB/s ({d:.1} ms/op)\n", .{
        mibPerS(total_written, write_ns), ms(write_ns, iterations),
    });
    p("round trip: {d:>6.1} ms/op\n", .{ms(roundtrip_ns, iterations)});
    p("edit+write: {d:>6.1} ms/op\n", .{ms(edit_ns, iterations)});
}

fn mibPerS(bytes: usize, ns: u64) f64 {
    const mib = @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
    const seconds = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
    if (seconds == 0) return 0;
    return mib / seconds;
}

fn ms(ns: u64, iterations: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms / @as(f64, @floatFromInt(iterations));
}
