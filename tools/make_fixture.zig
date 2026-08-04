// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");
const fixture = @import("fixture");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2 and args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "usage: make-udmesg-fixture [--benchmark|--partial-failure] OUTPUT\n");
        return error.InvalidArguments;
    }
    if (args.len == 3) {
        if (std.mem.eql(u8, args[1], "--benchmark")) {
            try fixture.writeBenchmark(init.arena.allocator(), init.io, args[2]);
            return;
        }
        if (!std.mem.eql(u8, args[1], "--partial-failure")) return error.InvalidArguments;
    }
    const output_path = args[args.len - 1];
    const built = try fixture.build(init.arena.allocator(), .{
        .invalid_last_text_range = args.len == 3,
    });
    const file = if (std.fs.path.isAbsolute(output_path))
        try std.Io.Dir.createFileAbsolute(init.io, output_path, .{})
    else
        try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, built.bytes);
}
