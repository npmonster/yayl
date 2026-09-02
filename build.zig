const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, importable by dependents as @import("yayl").
    // addModule registers it and returns the instance the compile steps
    // below share.
    const module = b.addModule("yayl", .{
        .root_source_file = b.path("src/yaml.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Compile the library so a plain `zig build` analyses the whole
    // public root; registering the module alone is lazy and would not
    // catch a broken public declaration.
    const lib = b.addLibrary(.{
        .name = "yayl",
        .root_module = module,
        .linkage = .static,
    });
    const check_step = b.step("check", "Compile the library (analyse the public root)");
    check_step.dependOn(&lib.step);
    b.getInstallStep().dependOn(check_step);

    // Unit tests live next to the implementation (Zig convention); the
    // root module's test block pulls every module's tests into the graph.
    const unit_tests = b.addTest(.{ .root_module = module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Conformance: the pinned YAML Test Suite corpus (fetch with
    // `make corpus`). Kept separate from the unit suite so it can run
    // against a vendored checkout without blocking quick test cycles.
    const conformance_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yayl", .module = module }},
        }),
    });
    const run_conformance = b.addRunArtifact(conformance_tests);
    const conformance_step = b.step("conformance", "Run the pinned YAML Test Suite corpus");
    conformance_step.dependOn(&run_conformance.step);

    // Byte-faithful round trip: emit(parseAll(input)) == input over the
    // corpus and the real-world fixtures (PLAN-4 presentation layer).
    const roundtrip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yayl", .module = module }},
        }),
    });
    const run_roundtrip = b.addRunArtifact(roundtrip_tests);
    const roundtrip_step = b.step("roundtrip", "Byte-faithful round trip over corpus and fixtures");
    roundtrip_step.dependOn(&run_roundtrip.step);

    // Edit-preservation sweeps: for every manipulation position in
    // every real-world fixture, an edit must change only the intended
    // lines (line-level non-interference assertions).
    const preservation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/preservation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yayl", .module = module }},
        }),
    });
    const run_preservation = b.addRunArtifact(preservation_tests);
    const preservation_step = b.step("preservation", "Edit-preservation sweeps over real-world fixtures");
    preservation_step.dependOn(&run_preservation.step);

    // Event-tree dump CLI for the libfyaml differential harness
    // (scripts/differential.sh compiles the C reference with the
    // system compiler and compares its event trees against ours).
    const dump_exe = b.addExecutable(.{
        .name = "dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yayl", .module = module }},
        }),
    });
    // Depend on the install, not the compile: scripts/differential.sh runs
    // `zig build dump` and then executes zig-out/bin/dump, and compiling
    // alone leaves the binary in the cache.
    const dump_install = b.addInstallArtifact(dump_exe, .{});
    const dump_step = b.step("dump", "Build the event-tree dump CLI");
    dump_step.dependOn(&dump_install.step);
    b.getInstallStep().dependOn(&dump_install.step);

    // Throughput benchmark CLI (PLAN-8): measured numbers for the docs.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "yayl", .module = module }},
        }),
    });
    const bench_install = b.addInstallArtifact(bench_exe, .{});
    const bench_step = b.step("bench", "Build the throughput benchmark CLI");
    bench_step.dependOn(&bench_install.step);
    b.getInstallStep().dependOn(&bench_install.step);

    // Examples: small compile-checked programs (see examples/). yq_lite is
    // the dogfood consumer (PLAN-12 workstream A): `zig build examples` not
    // only compiles it but RUNS its full-surface demo against a real
    // fixture, so the public API stays end-to-end usable in CI forever.
    const examples_step = b.step("examples", "Build (and exercise) the example programs");
    inline for (.{ "parse", "edit", "yq_lite" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "yayl", .module = module }},
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);
        if (comptime std.mem.eql(u8, name, "yq_lite")) {
            var run = b.addRunArtifact(exe);
            run.addArgs(&.{ "demo", "tests/fixtures/markdownlint.yaml", "zig-out/yq-lite-demo.yaml" });
            run.step.dependOn(&install.step);
            examples_step.dependOn(&run.step);
        }
    }
}
