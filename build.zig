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
}
