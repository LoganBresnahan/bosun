const std = @import("std");

// The release matrix. Linux targets use musl so the binary is fully static —
// it must work in minimal containers (alpine, distroless) where the whole
// point is that nothing else is installed. macOS links libSystem (the only
// supported interface there); Zig provides the stubs, so every target
// cross-compiles from any host.
const release_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    // `zig build` -> zig-out/bin/bosun for the host, for local dev + smoke tests.
    const host = b.addExecutable(.{
        .name = "bosun",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = optimize,
        }),
    });
    host.linkLibC();
    b.installArtifact(host);

    // `zig build release` -> zig-out/release/bosun-<arch>-<os> for every target.
    const release = b.step("release", "Cross-compile all distribution targets");
    for (release_targets) |q| {
        const resolved = b.resolveTargetQuery(q);
        const exe = b.addExecutable(.{
            .name = "bosun",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = optimize,
            }),
        });
        exe.linkLibC();
        const t = resolved.result;
        const name = b.fmt("bosun-{s}-{s}", .{ @tagName(t.cpu.arch), @tagName(t.os.tag) });
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .dest_sub_path = name,
        });
        release.dependOn(&install.step);
    }

    // `zig build test` -> unit tests (signal parsing; main is exec-heavy and
    // is covered by test/smoke.sh instead).
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sig.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    // Same libc posture as the shipped binary. Without this, the native test
    // link on newer macOS SDKs fails with `undefined symbol:
    // __availability_version_check` (seen on the macos-latest arm64 runner).
    tests.linkLibC();
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
