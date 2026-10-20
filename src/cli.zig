// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

pub const Action = enum { extract, help, version };

pub const Options = struct {
    action: Action = .extract,
    inputs: []const []const u8 = &.{},
    output: ?[]const u8 = null,
};

pub fn parse(allocator: std.mem.Allocator, args: anytype, allow_multiple: bool) !Options {
    var result: Options = .{};
    var inputs: std.ArrayList([]const u8) = .empty;
    errdefer inputs.deinit(allocator);
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
        if (!allow_multiple and inputs.items.len != 0) return error.TooManyInputs;
        try inputs.append(allocator, arg);
    }
    if (inputs.items.len == 0) return error.MissingInput;
    result.inputs = try inputs.toOwnedSlice(allocator);
    return result;
}

test "CLI accepts stdout and output paths" {
    const default = try parse(std.testing.allocator, &[_][]const u8{ "udmesg", "core" }, false);
    defer std.testing.allocator.free(default.inputs);
    try std.testing.expectEqualStrings("core", default.inputs[0]);
    try std.testing.expect(default.output == null);

    const explicit = try parse(std.testing.allocator, &[_][]const u8{ "udmesg", "--output=log", "core" }, false);
    defer std.testing.allocator.free(explicit.inputs);
    try std.testing.expectEqualStrings("log", explicit.output.?);

    const dashed = try parse(std.testing.allocator, &[_][]const u8{ "udmesg", "--", "-core" }, false);
    defer std.testing.allocator.free(dashed.inputs);
    try std.testing.expectEqualStrings("-core", dashed.inputs[0]);

    const split = try parse(std.testing.allocator, &[_][]const u8{ "udmesg-kdump", "part1", "-o", "log", "part2" }, true);
    defer std.testing.allocator.free(split.inputs);
    try std.testing.expectEqual(@as(usize, 2), split.inputs.len);
    try std.testing.expectEqualStrings("part2", split.inputs[1]);
}

test "CLI rejects ambiguous arguments" {
    try std.testing.expectError(error.MissingInput, parse(std.testing.allocator, &[_][]const u8{"udmesg"}, false));
    try std.testing.expectError(error.DuplicateOutput, parse(std.testing.allocator, &[_][]const u8{ "udmesg", "-o", "a", "-o", "b", "core" }, false));
    try std.testing.expectError(error.UnknownOption, parse(std.testing.allocator, &[_][]const u8{ "udmesg", "--wat", "core" }, false));
    try std.testing.expectError(error.TooManyInputs, parse(std.testing.allocator, &[_][]const u8{ "udmesg", "part1", "part2" }, false));
}
