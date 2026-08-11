//! Signal-name parsing for the --pdeathsig flag. Accepts the common POSIX
//! names (with or without a SIG prefix) or a raw number. Kept in its own file
//! so it carries unit tests without dragging exec-heavy main.zig into `zig
//! build test`.

const std = @import("std");

pub const ParseError = error{UnknownSignal};

/// "TERM" | "SIGTERM" | "15" -> 15. Case-insensitive. Numbers are accepted in
/// 1..64 (the portable-ish real-time ceiling); 0 is refused — signal 0 is a
/// liveness probe, never a disposition.
pub fn parse(name: []const u8) ParseError!u8 {
    const stripped = if (std.ascii.startsWithIgnoreCase(name, "SIG")) name[3..] else name;

    if (std.fmt.parseInt(u8, stripped, 10)) |n| {
        if (n == 0 or n > 64) return ParseError.UnknownSignal;
        return n;
    } else |_| {}

    const table = [_]struct { name: []const u8, num: u8 }{
        .{ .name = "HUP", .num = 1 },
        .{ .name = "INT", .num = 2 },
        .{ .name = "QUIT", .num = 3 },
        .{ .name = "KILL", .num = 9 },
        .{ .name = "USR1", .num = 10 },
        .{ .name = "USR2", .num = 12 },
        .{ .name = "TERM", .num = 15 },
    };
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(stripped, e.name)) return e.num;
    }
    return ParseError.UnknownSignal;
}

test "names, prefixes, case, numbers" {
    try std.testing.expectEqual(@as(u8, 15), try parse("TERM"));
    try std.testing.expectEqual(@as(u8, 15), try parse("SIGTERM"));
    try std.testing.expectEqual(@as(u8, 15), try parse("term"));
    try std.testing.expectEqual(@as(u8, 9), try parse("kill"));
    try std.testing.expectEqual(@as(u8, 9), try parse("9"));
    try std.testing.expectEqual(@as(u8, 1), try parse("SIGHUP"));
}

test "refusals" {
    try std.testing.expectError(ParseError.UnknownSignal, parse("0"));
    try std.testing.expectError(ParseError.UnknownSignal, parse("65"));
    try std.testing.expectError(ParseError.UnknownSignal, parse("BOGUS"));
    try std.testing.expectError(ParseError.UnknownSignal, parse(""));
}
