const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpp_module = b.addModule("zpp", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zpp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zpp", zpp_module);
    b.installArtifact(exe);

    const api_exe = b.addExecutable(.{
        .name = "zpp-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(api_exe);

    const audit_exe = b.addExecutable(.{
        .name = "zpp-audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_audit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    audit_exe.root_module.addImport("zpp", zpp_module);
    b.installArtifact(audit_exe);

    const package_exe = b.addExecutable(.{
        .name = "zpp-package",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_package.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    package_exe.root_module.addImport("zpp", zpp_module);
    b.installArtifact(package_exe);

    const fmt_exe = b.addExecutable(.{
        .name = "zpp-fmt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_fmt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(fmt_exe);

    const doc_exe = b.addExecutable(.{
        .name = "zpp-doc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_doc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(doc_exe);

    const lsp_exe = b.addExecutable(.{
        .name = "zpp-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_lsp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lsp_exe.root_module.addImport("zpp", zpp_module);
    b.installArtifact(lsp_exe);

    const migrate_exe = b.addExecutable(.{
        .name = "zpp-migrate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_migrate.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(migrate_exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zpp frontend");
    run_step.dependOn(&run_cmd.step);

    const run_api = b.addRunArtifact(api_exe);
    if (b.args) |args| {
        run_api.addArgs(args);
    }

    const api_step = b.step("api-zpp", "Generate or check a Zig++ public API manifest");
    api_step.dependOn(&run_api.step);

    const run_audit = b.addRunArtifact(audit_exe);
    if (b.args) |args| {
        run_audit.addArgs(args);
    }

    const audit_step = b.step("audit-zpp", "Audit Zig++ source diagnostics");
    audit_step.dependOn(&run_audit.step);

    const run_package = b.addRunArtifact(package_exe);
    if (b.args) |args| {
        run_package.addArgs(args);
    }

    const package_step = b.step("package-zpp", "Run a Zig++ package manifest command");
    package_step.dependOn(&run_package.step);

    const run_fmt = b.addRunArtifact(fmt_exe);
    if (b.args) |args| {
        run_fmt.addArgs(args);
    }

    const fmt_step = b.step("fmt-zpp", "Format Zig++ source files");
    fmt_step.dependOn(&run_fmt.step);

    const run_doc = b.addRunArtifact(doc_exe);
    if (b.args) |args| {
        run_doc.addArgs(args);
    }

    const doc_step = b.step("doc-zpp", "Generate Zig++ Markdown docs");
    doc_step.dependOn(&run_doc.step);

    const run_lsp = b.addRunArtifact(lsp_exe);
    if (b.args) |args| {
        run_lsp.addArgs(args);
    }

    const lsp_step = b.step("lsp-zpp", "Run the Zig++ language server over stdio");
    lsp_step.dependOn(&run_lsp.step);

    const run_migrate = b.addRunArtifact(migrate_exe);
    if (b.args) |args| {
        run_migrate.addArgs(args);
    }

    const migrate_step = b.step("migrate-zpp", "Migrate conservative Zig ownership patterns to Zig++");
    migrate_step.dependOn(&run_migrate.step);

    const fixture_exe = b.addExecutable(.{
        .name = "zpp-fixture-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_fixture_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fixture_exe.root_module.addImport("zpp", zpp_module);

    const run_fixtures = b.addRunArtifact(fixture_exe);

    const compile_fixture_exe = b.addExecutable(.{
        .name = "zpp-compile-fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_compile_fixtures.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compile_fixture_exe.root_module.addImport("zpp", zpp_module);

    const run_compile_fixtures = b.addRunArtifact(compile_fixture_exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const zpp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zpp_tests.root_module.addImport("zpp", zpp_module);
    const run_zpp_tests = b.addRunArtifact(zpp_tests);

    const audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_audit.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    audit_tests.root_module.addImport("zpp", zpp_module);
    const run_audit_tests = b.addRunArtifact(audit_tests);

    const package_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_package.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    package_tests.root_module.addImport("zpp", zpp_module);
    const run_package_tests = b.addRunArtifact(package_tests);

    const api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_api.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_api_tests = b.addRunArtifact(api_tests);

    const fmt_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_fmt.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_fmt_tests = b.addRunArtifact(fmt_tests);

    const doc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_doc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_doc_tests = b.addRunArtifact(doc_tests);

    const lsp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_lsp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lsp_tests.root_module.addImport("zpp", zpp_module);
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

    const migrate_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/zpp_migrate.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_migrate_tests = b.addRunArtifact(migrate_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_zpp_tests.step);
    test_step.dependOn(&run_audit_tests.step);
    test_step.dependOn(&run_package_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_fmt_tests.step);
    test_step.dependOn(&run_doc_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
    test_step.dependOn(&run_migrate_tests.step);
    test_step.dependOn(&run_fixtures.step);
    test_step.dependOn(&run_compile_fixtures.step);

    const fixture_step = b.step("fixture-test", "Run zpp fixture tests");
    fixture_step.dependOn(&run_fixtures.step);

    const compile_fixture_step = b.step("compile-fixtures", "Compile generated Zig fixture output");
    compile_fixture_step.dependOn(&run_compile_fixtures.step);
}
