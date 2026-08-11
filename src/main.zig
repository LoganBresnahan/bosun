//! bosun — a process-attribute launcher: the ~30 lines that must run INSIDE
//! the child, between fork and exec, which managed runtimes (.NET, BEAM, JVM)
//! cannot reach from their spawn APIs.
//!
//!   bosun [--pdeathsig <SIG>] [--pdeathsig-soft <SIG>] [--parent <pid>]
//!         [--no-setsid] -- <command> [args...]
//!
//! What it does, in order, then EXECS the command in place (same pid):
//!   1. setsid()            — the child becomes session + process-group leader,
//!                            so pgid == pid and kill(-pid) reaches every
//!                            descendant, including reparented grandchildren a
//!                            tree-walk cannot see. On by default; --no-setsid
//!                            opts out.
//!   2. PR_SET_PDEATHSIG    — (Linux only) the kernel delivers <SIG> to this
//!                            process when the spawning THREAD of the parent
//!                            dies — however it dies, SIGKILL and OOM included.
//!      --pdeathsig errors where unsupported (macOS): silent capability loss
//!      is exactly the failure mode this tool exists to end. --pdeathsig-soft
//!      is the documented best-effort form for callers that prefer degrade.
//!   3. --parent <pid>      — closes the fork-to-prctl race: if the parent
//!                            already died before prctl took effect, the
//!                            death signal will never fire, so we detect the
//!                            reparent (getppid() != pid) and deliver the
//!                            signal to ourselves immediately.
//!
//! Exit codes (env(1)/nohup(1) conventions):
//!   125  bosun itself failed (bad flags, setsid/prctl failure)
//!   126  command found but could not be executed
//!   127  command not found
//!   otherwise: the command's own exit status (exec replaces us).
//!
//! Sharp edge, documented not hidden: pdeathsig fires when the parent's
//! forking THREAD exits, not the parent process. Parents with pooled threads
//! (.NET) should spawn from a long-lived thread; --parent narrows but cannot
//! close that hazard.

const std = @import("std");
const builtin = @import("builtin");
const sig = @import("sig.zig");

// libc is linked on every target (musl static on Linux, libSystem on macOS),
// so the portable surface is plain externs.
extern "c" fn setsid() std.c.pid_t;
extern "c" fn getppid() std.c.pid_t;
extern "c" fn raise(signum: c_int) c_int;

const usage =
    \\usage: bosun [--pdeathsig <SIG>] [--pdeathsig-soft <SIG>] [--parent <pid>]
    \\             [--no-setsid] -- <command> [args...]
    \\
;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bosun: " ++ fmt ++ "\n", args);
    std.process.exit(125);
}

pub fn main() noreturn {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();

    const argv = std.process.argsAlloc(arena) catch fail("out of memory", .{});

    var do_setsid = true;
    var death_sig: ?u8 = null;
    var death_required = false; // --pdeathsig (hard) vs --pdeathsig-soft
    var expected_parent: ?std.c.pid_t = null;
    var cmd_start: ?usize = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--")) {
            cmd_start = i + 1;
            break;
        } else if (std.mem.eql(u8, a, "--no-setsid")) {
            do_setsid = false;
        } else if (std.mem.eql(u8, a, "--pdeathsig") or std.mem.eql(u8, a, "--pdeathsig-soft")) {
            i += 1;
            if (i >= argv.len) fail("{s} needs a signal argument", .{a});
            death_sig = sig.parse(argv[i]) catch fail("unknown signal '{s}'", .{argv[i]});
            death_required = std.mem.eql(u8, a, "--pdeathsig");
        } else if (std.mem.eql(u8, a, "--parent")) {
            i += 1;
            if (i >= argv.len) fail("--parent needs a pid argument", .{});
            expected_parent = std.fmt.parseInt(std.c.pid_t, argv[i], 10) catch
                fail("bad --parent pid '{s}'", .{argv[i]});
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else {
            fail("unknown flag '{s}'\n{s}", .{ a, usage });
        }
    }

    const start = cmd_start orelse fail("missing '--' before the command\n{s}", .{usage});
    if (start >= argv.len) fail("no command after '--'\n{s}", .{usage});

    // 1. Own session + process group. A freshly spawned child never leads a
    // group, so this cannot fail with EPERM in practice; treat failure as
    // fatal rather than degrading silently (the pgroup=false lesson).
    if (do_setsid) {
        if (setsid() == -1) fail("setsid failed (already a session leader?)", .{});
    }

    // 2. Die-with-parent, where the kernel offers it.
    if (death_sig) |s| {
        if (builtin.os.tag == .linux) {
            const rc = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_PDEATHSIG), @as(usize, s), 0, 0, 0);
            if (std.os.linux.E.init(rc) != .SUCCESS) fail("prctl(PR_SET_PDEATHSIG) failed", .{});
            // 3. The fork-to-prctl race: if the intended parent is already
            // gone we were reparented, and the death signal will never fire.
            // Deliver it to ourselves now, as if it had.
            if (expected_parent) |pp| {
                if (getppid() != pp) {
                    _ = raise(@intCast(s));
                    std.process.exit(125); // unreachable for fatal signals
                }
            }
        } else if (death_required) {
            fail("--pdeathsig is not supported on {s} (no PR_SET_PDEATHSIG equivalent); " ++
                "use --pdeathsig-soft to degrade explicitly", .{@tagName(builtin.os.tag)});
        }
        // soft form on non-Linux: documented no-op, chosen by the caller.
    }

    // Exec in place — same pid, so the spawner's Process handle IS the
    // payload, and pgid == sid == pid.
    const child_argv = argv[start..];
    const err = std.process.execv(arena, child_argv);
    const code: u8 = switch (err) {
        error.FileNotFound => 127,
        error.AccessDenied => 126,
        else => 126,
    };
    std.debug.print("bosun: exec '{s}': {s}\n", .{ child_argv[0], @errorName(err) });
    std.process.exit(code);
}
