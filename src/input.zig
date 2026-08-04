// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

pub const FileReader = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn readAt(self: *const FileReader, offset: u64, dest: []u8) !void {
        const count = try self.file.readPositionalAll(self.io, dest, offset);
        if (count != dest.len) return error.UnexpectedEndOfFile;
    }
};

pub const MemoryReader = struct {
    bytes: []const u8,

    pub fn readAt(self: *const MemoryReader, offset: u64, dest: []u8) !void {
        if (offset > self.bytes.len) return error.UnexpectedEndOfFile;
        const start: usize = @intCast(offset);
        if (dest.len > self.bytes.len - start) return error.UnexpectedEndOfFile;
        @memcpy(dest, self.bytes[start..][0..dest.len]);
    }
};
