// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");
const elf = @import("elf.zig");
const input = @import("input.zig");
const vmcoreinfo = @import("vmcoreinfo.zig");

extern fn udk_open(nfds: c_uint, fds: [*]const c_int) ?*anyopaque;
extern fn udk_close(ctx: *anyopaque) void;
extern fn udk_read(ctx: *anyopaque, address: u64, dest: [*]u8, size: usize, image_offset: u64, linear_offset: u64, has_linear: c_int) c_int;
extern fn udk_vmcoreinfo(ctx: *anyopaque, raw: *?[*:0]u8) c_int;
extern fn udk_target(ctx: *anyopaque, word_size: *c_uint, big_endian: *c_uint, aarch64: *c_uint) c_int;
extern fn udk_error(ctx: *anyopaque) ?[*:0]const u8;
extern fn udk_release(raw: [*:0]u8) void;

pub const Reader = struct {
    ctx: *anyopaque,
    aarch64: bool = false,
    image_offset: u64 = 0,
    linear_offset: ?u64 = null,

    pub fn open(allocator: std.mem.Allocator, files: []const std.Io.File) !Reader {
        const fds = try allocator.alloc(c_int, files.len);
        defer allocator.free(fds);
        for (files, fds) |file, *fd| fd.* = @intCast(file.handle);
        return .{ .ctx = udk_open(@intCast(fds.len), fds.ptr) orelse return error.KdumpOpenFailed };
    }

    pub fn close(self: *Reader) void {
        udk_close(self.ctx);
    }

    pub fn readAt(self: *Reader, address: u64, dest: []u8) !void {
        if (udk_read(self.ctx, address, dest.ptr, dest.len, self.image_offset, self.linear_offset orelse 0, @intFromBool(self.linear_offset != null)) == 0) {
            std.debug.print("udmesg-kdump: cannot read address 0x{x}\n", .{address});
            return self.fail(error.KdumpReadFailed);
        }
    }

    pub fn image(self: *Reader) !Image {
        var word_size: c_uint = undefined;
        var big_endian: c_uint = undefined;
        var aarch64: c_uint = undefined;
        if (udk_target(self.ctx, &word_size, &big_endian, &aarch64) == 0) return self.fail(error.KdumpTargetFailed);
        self.aarch64 = aarch64 != 0;
        return .{ .target_layout = .{
            .class = if (word_size == 4) .elf32 else .elf64,
            .order = if (big_endian == 0) .little else .big,
        } };
    }

    pub fn metadata(self: *Reader) !vmcoreinfo.Metadata {
        var raw: ?[*:0]u8 = null;
        if (udk_vmcoreinfo(self.ctx, &raw) == 0) return self.fail(error.MissingVmcoreInfo);
        defer udk_release(raw.?);
        const text = std.mem.span(raw.?);
        var reader: input.MemoryReader = .{ .bytes = text };
        const parsed = try vmcoreinfo.parse(&reader, 0, text.len);
        self.image_offset = if (self.aarch64) parsed.kimage_voffset orelse 0 else 0;
        if (self.aarch64 and parsed.va_bits != null and parsed.phys_offset != null) {
            const va_bits = parsed.va_bits.?;
            if (va_bits >= 32 and va_bits < 64) {
                const page_offset = @as(u64, 0) -% (@as(u64, 1) << @intCast(va_bits));
                // Filtered ARM64 dumps may omit page-table pages; VMCOREINFO
                // still provides the kernel's direct-map offsets.
                self.linear_offset = parsed.phys_offset.? -% page_offset;
            }
        }
        return parsed;
    }

    fn fail(self: *Reader, err: anyerror) anyerror {
        if (udk_error(self.ctx)) |message| std.debug.print("udmesg-kdump: {s}\n", .{std.mem.span(message)});
        return err;
    }
};

pub const Image = struct {
    target_layout: elf.Layout,

    pub fn layout(self: Image) elf.Layout {
        return self.target_layout;
    }

    pub fn resolveRegion(
        _: Image,
        _: anytype,
        address: u64,
        size: u64,
        _: ?u64,
        _: ?u64,
    ) !elf.Region {
        if (size == 0) return error.InvalidMemoryRegion;
        _ = try elf.add(address, size);
        return .{ .offset = address, .size = size };
    }
};
