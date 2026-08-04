// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

pub const Action = enum { extract, help, version };

pub const Options = struct {
    action: Action = .extract,
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
};

pub fn parse(args: anytype) !Options {
    var result: Options = .{};
    var positional_only = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (!positional_only and std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help"))) {
            if (args.len != 2) return error.HelpWithOtherArguments;
            return .{ .action = .help };
        }
        if (!positional_only and std.mem.eql(u8, arg, "--version")) {
            if (args.len != 2) return error.VersionWithOtherArguments;
            return .{ .action = .version };
        }
        if (!positional_only and (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output"))) {
            if (result.output != null) return error.DuplicateOutput;
            index += 1;
            if (index >= args.len) return error.MissingOutputPath;
            result.output = args[index];
            continue;
        }
        if (!positional_only and std.mem.startsWith(u8, arg, "--output=")) {
            if (result.output != null) return error.DuplicateOutput;
            const value = arg["--output=".len..];
            if (value.len == 0) return error.MissingOutputPath;
            result.output = value;
            continue;
        }
        if (!positional_only and arg.len > 1 and arg[0] == '-') return error.UnknownOption;
        if (result.input != null) return error.TooManyInputs;
        result.input = arg;
    }
    if (result.input == null) return error.MissingInput;
    return result;
}

test "CLI accepts stdout and output paths" {
    const default = try parse(&[_][]const u8{ "udmesg", "core" });
    try std.testing.expectEqualStrings("core", default.input.?);
    try std.testing.expect(default.output == null);

    const explicit = try parse(&[_][]const u8{ "udmesg", "--output=log", "core" });
    try std.testing.expectEqualStrings("log", explicit.output.?);

    const dashed = try parse(&[_][]const u8{ "udmesg", "--", "-core" });
    try std.testing.expectEqualStrings("-core", dashed.input.?);
}

test "CLI rejects ambiguous arguments" {
    try std.testing.expectError(error.MissingInput, parse(&[_][]const u8{"udmesg"}));
    try std.testing.expectError(error.DuplicateOutput, parse(&[_][]const u8{ "udmesg", "-o", "a", "-o", "b", "core" }));
    try std.testing.expectError(error.UnknownOption, parse(&[_][]const u8{ "udmesg", "--wat", "core" }));
}
