// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");
const cli = @import("cli.zig");
const elf = @import("elf.zig");
const fixture = @import("fixture.zig");
const input = @import("input.zig");
const printk = @import("printk.zig");
const vmcoreinfo = @import("vmcoreinfo.zig");

test {
    _ = elf;
    _ = vmcoreinfo;
    _ = printk;
    _ = cli;
}

const Sink = struct {
    list: *std.ArrayList(u8),

    pub fn writeAll(self: *Sink, bytes: []const u8) !void {
        try self.list.appendSlice(std.testing.allocator, bytes);
    }
};

fn runFixture(options: fixture.Options, live: bool) !std.ArrayList(u8) {
    const built = try fixture.build(std.testing.allocator, options);
    defer built.deinit(std.testing.allocator);
    return extractBytes(built.bytes, live);
}

fn extractBytes(bytes: []const u8, live: bool) !std.ArrayList(u8) {
    var reader: input.MemoryReader = .{ .bytes = bytes };
    const image = try elf.Image.parse(&reader);
    const note = try image.findVmcoreInfo(&reader);
    const metadata = try vmcoreinfo.parse(&reader, note.offset, note.size);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };
    try printk.extract(std.testing.allocator, &reader, &sink, image, metadata, live);
    return output;
}

fn putLe16(bytes: []u8, offset: u64, value: u16) void {
    bytes[@intCast(offset)] = @truncate(value);
    bytes[@intCast(offset + 1)] = @truncate(value >> 8);
}

fn putLe32(bytes: []u8, offset: u64, value: u32) void {
    for (0..4) |i| bytes[@intCast(offset + i)] = @truncate(value >> @intCast(i * 8));
}

fn putLe64(bytes: []u8, offset: u64, value: u64) void {
    for (0..8) |i| bytes[@intCast(offset + i)] = @truncate(value >> @intCast(i * 8));
}

test "end-to-end output matches vmcore-dmesg for every ELF class and byte order" {
    const expected = "[    1.234567] hello\n[    2.000000] \n[   12.034567] b\\x01\n\n";
    const classes = [_]elf.Class{ .elf32, .elf64 };
    const orders = [_]elf.ByteOrder{ .little, .big };
    for (classes) |class| for (orders) |order| {
        var output = try runFixture(.{ .class = class, .order = order }, false);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(expected, output.items);
    };
}

test "direct-map fallback resolves ring memory" {
    var output = try runFixture(.{ .direct_map_fallback = true }, false);
    defer output.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, output.items, "[    1.234567] hello\n"));
}

test "/proc/kcore physical-address sentinels do not block virtual mappings" {
    const expected = "[    1.234567] hello\n[    2.000000] \n[   12.034567] b\\x01\n\n";
    const classes = [_]elf.Class{ .elf32, .elf64 };
    const orders = [_]elf.ByteOrder{ .little, .big };
    for (classes) |class| for (orders) |order| {
        var output = try runFixture(.{
            .class = class,
            .order = order,
            .unavailable_physical_address = true,
        }, false);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(expected, output.items);
    };
}

test "text length is truncated to the descriptor block" {
    const expected = "[    1.234567] hello\n[    2.000000] \n[   12.034567] b\\x01\n\n";
    const built = try fixture.build(std.testing.allocator, .{});
    defer built.deinit(std.testing.allocator);
    putLe16(built.bytes, built.info_file_offset + 16, 100);
    var output = try extractBytes(built.bytes, false);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, output.items);
}

test "extended program-header counts are accepted" {
    var output = try runFixture(.{ .extended_program_header_count = true }, false);
    defer output.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, output.items, "[    1.234567] hello\n"));
}

test "descriptor IDs wrap at the target word width" {
    const expected = "[    1.000000] a\n[    2.000000] b\n[    3.000000] c\n[    4.000000] d\n";
    const classes = [_]elf.Class{ .elf32, .elf64 };
    for (classes) |class| {
        var output = try runFixture(.{ .class = class, .wrap_ids = true }, false);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(expected, output.items);
    }
}

test "live input excludes committed records" {
    const expected = "[    2.000000] \n[   12.034567] b\\x01\n\n";
    var output = try runFixture(.{}, true);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, output.items);
}

test "malformed ELF and missing lockless metadata fail cleanly" {
    var bad_magic: [64]u8 = @splat(0);
    var reader: input.MemoryReader = .{ .bytes = &bad_magic };
    try std.testing.expectError(error.NotElf, elf.Image.parse(&reader));

    const text = "OSRELEASE=example\n";
    var info_reader: input.MemoryReader = .{ .bytes = text };
    const metadata = try vmcoreinfo.parse(&info_reader, 0, text.len);
    try std.testing.expect(metadata.prb_vaddr == null);

    const built = try fixture.build(std.testing.allocator, .{});
    defer built.deinit(std.testing.allocator);
    var core_reader: input.MemoryReader = .{ .bytes = built.bytes };
    const image = try elf.Image.parse(&core_reader);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };
    try std.testing.expectError(
        error.UnsupportedPrintkFormat,
        printk.extract(std.testing.allocator, &core_reader, &sink, image, metadata, false),
    );
}

test "malformed note geometry and ELF arithmetic overflow are rejected" {
    const malformed_note = try fixture.build(std.testing.allocator, .{});
    defer malformed_note.deinit(std.testing.allocator);
    // ELF64's first program header starts at 64 and p_filesz is at +32.
    putLe64(malformed_note.bytes, 96, 13);
    var note_reader: input.MemoryReader = .{ .bytes = malformed_note.bytes };
    const note_image = try elf.Image.parse(&note_reader);
    try std.testing.expectError(error.MalformedElfNote, note_image.findVmcoreInfo(&note_reader));

    const overflow = try fixture.build(std.testing.allocator, .{});
    defer overflow.deinit(std.testing.allocator);
    // ELF64 e_phoff.
    putLe64(overflow.bytes, 32, std.math.maxInt(u64));
    var overflow_reader: input.MemoryReader = .{ .bytes = overflow.bytes };
    try std.testing.expectError(error.IntegerOverflow, elf.Image.parse(&overflow_reader));
}

test "missing and oversized printk metadata are rejected" {
    const built = try fixture.build(std.testing.allocator, .{});
    defer built.deinit(std.testing.allocator);
    var reader: input.MemoryReader = .{ .bytes = built.bytes };
    const image = try elf.Image.parse(&reader);
    const note = try image.findVmcoreInfo(&reader);
    const parsed = try vmcoreinfo.parse(&reader, note.offset, note.size);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };

    var missing = parsed;
    missing.printk_info_size = null;
    try std.testing.expectError(
        error.MissingPrintkMetadata,
        printk.extract(std.testing.allocator, &reader, &sink, image, missing, false),
    );

    var oversized = parsed;
    oversized.printk_ringbuffer_size = 64 * 1024 + 1;
    try std.testing.expectError(
        error.InvalidPrintkStructureSize,
        printk.extract(std.testing.allocator, &reader, &sink, image, oversized, false),
    );
}

test "invalid ring geometry is rejected" {
    const built = try fixture.build(std.testing.allocator, .{});
    defer built.deinit(std.testing.allocator);
    built.bytes[@intCast(built.prb_file_offset)] = 64;

    var reader: input.MemoryReader = .{ .bytes = built.bytes };
    const image = try elf.Image.parse(&reader);
    const note = try image.findVmcoreInfo(&reader);
    const metadata = try vmcoreinfo.parse(&reader, note.offset, note.size);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };
    try std.testing.expectError(
        error.InvalidDescriptorCountBits,
        printk.extract(std.testing.allocator, &reader, &sink, image, metadata, false),
    );
}

test "ring size overflow and invalid text shifts are rejected" {
    const overflow = try fixture.build(std.testing.allocator, .{});
    defer overflow.deinit(std.testing.allocator);
    putLe32(overflow.bytes, overflow.prb_file_offset, 61);
    var overflow_reader: input.MemoryReader = .{ .bytes = overflow.bytes };
    const overflow_image = try elf.Image.parse(&overflow_reader);
    const overflow_note = try overflow_image.findVmcoreInfo(&overflow_reader);
    const overflow_metadata = try vmcoreinfo.parse(&overflow_reader, overflow_note.offset, overflow_note.size);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };
    try std.testing.expectError(
        error.IntegerOverflow,
        printk.extract(std.testing.allocator, &overflow_reader, &sink, overflow_image, overflow_metadata, false),
    );

    const invalid_shift = try fixture.build(std.testing.allocator, .{});
    defer invalid_shift.deinit(std.testing.allocator);
    putLe32(invalid_shift.bytes, invalid_shift.prb_file_offset + 48, 64);
    var shift_reader: input.MemoryReader = .{ .bytes = invalid_shift.bytes };
    const shift_image = try elf.Image.parse(&shift_reader);
    const shift_note = try shift_image.findVmcoreInfo(&shift_reader);
    const shift_metadata = try vmcoreinfo.parse(&shift_reader, shift_note.offset, shift_note.size);
    try std.testing.expectError(
        error.InvalidTextRingSizeBits,
        printk.extract(std.testing.allocator, &shift_reader, &sink, shift_image, shift_metadata, false),
    );
}

test "unmapped regions and short reads fail cleanly" {
    const unmapped = try fixture.build(std.testing.allocator, .{});
    defer unmapped.deinit(std.testing.allocator);
    var unmapped_reader: input.MemoryReader = .{ .bytes = unmapped.bytes };
    const image = try elf.Image.parse(&unmapped_reader);
    const note = try image.findVmcoreInfo(&unmapped_reader);
    var metadata = try vmcoreinfo.parse(&unmapped_reader, note.offset, note.size);
    metadata.prb_vaddr = 0x1000;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };
    try std.testing.expectError(
        error.UnmappedKernelAddress,
        printk.extract(std.testing.allocator, &unmapped_reader, &sink, image, metadata, false),
    );

    const short = try fixture.build(std.testing.allocator, .{});
    defer short.deinit(std.testing.allocator);
    var short_reader: input.MemoryReader = .{
        .bytes = short.bytes[0..@intCast(short.prb_file_offset + 40)],
    };
    const short_image = try elf.Image.parse(&short_reader);
    const short_note = try short_image.findVmcoreInfo(&short_reader);
    const short_metadata = try vmcoreinfo.parse(&short_reader, short_note.offset, short_note.size);
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        printk.extract(std.testing.allocator, &short_reader, &sink, short_image, short_metadata, false),
    );
}

test "tail-to-head traversal cannot exceed the descriptor count" {
    const built = try fixture.build(std.testing.allocator, .{});
    defer built.deinit(std.testing.allocator);
    putLe64(built.bytes, built.prb_file_offset + 24, 4);
    var reader: input.MemoryReader = .{ .bytes = built.bytes };
    const image = try elf.Image.parse(&reader);
    const note = try image.findVmcoreInfo(&reader);
    const metadata = try vmcoreinfo.parse(&reader, note.offset, note.size);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };
    try std.testing.expectError(
        error.DescriptorSpanExceedsRing,
        printk.extract(std.testing.allocator, &reader, &sink, image, metadata, false),
    );
}

test "live records changed between reads are skipped" {
    const built = try fixture.build(std.testing.allocator, .{});
    defer built.deinit(std.testing.allocator);
    const Mutable = struct {
        bytes: []const u8,
        target: u64,
        target_reads: usize = 0,

        pub fn readAt(self: *@This(), offset: u64, dest: []u8) !void {
            if (offset > self.bytes.len) return error.UnexpectedEndOfFile;
            const start: usize = @intCast(offset);
            if (dest.len > self.bytes.len - start) return error.UnexpectedEndOfFile;
            @memcpy(dest, self.bytes[start..][0..dest.len]);
            if (offset == self.target) {
                self.target_reads += 1;
                if (self.target_reads == 2) dest[0] ^= 1;
            }
        }
    };
    var reader: Mutable = .{
        .bytes = built.bytes,
        .target = built.desc_file_offset + built.desc_size,
    };
    const image = try elf.Image.parse(&reader);
    const note = try image.findVmcoreInfo(&reader);
    const metadata = try vmcoreinfo.parse(&reader, note.offset, note.size);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var sink: Sink = .{ .list = &output };
    try printk.extract(std.testing.allocator, &reader, &sink, image, metadata, true);
    try std.testing.expectEqualStrings("[   12.034567] b\\x01\n\n", output.items);
}
