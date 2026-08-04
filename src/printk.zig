// SPDX-License-Identifier: GPL-2.0-or-later
// Lockless printk ring semantics are derived from kexec-tools util_lib/elf_info.c
// and the bounded-memory streaming patch identified in README.md.

const std = @import("std");
const elf = @import("elf.zig");
const vmcoreinfo = @import("vmcoreinfo.zig");

const max_struct_size = 64 * 1024;
const max_text_size = std.math.maxInt(u16);

pub fn extract(
    allocator: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    image: elf.Image,
    info: vmcoreinfo.Metadata,
    live: bool,
) !void {
    const prb_symbol = info.prb_vaddr orelse return error.UnsupportedPrintkFormat;
    const prb_size = try boundedSize(info.printk_ringbuffer_size);
    const desc_size = try boundedSize(info.prb_desc_size);
    const printk_info_size = try boundedSize(info.printk_info_size);
    const word_size: u64 = image.wordSize();

    const desc_ring_offset = try required(info.printk_ringbuffer_desc_ring);
    const text_ring_offset = try required(info.printk_ringbuffer_text_data_ring);
    try validateField(prb_size, desc_ring_offset, 1);
    try validateField(prb_size, text_ring_offset, 1);

    const symbol_region = try image.resolveRegion(reader, prb_symbol, word_size, info.page_offset, info.effectivePhysOffset());
    var pointer_bytes: [8]u8 = undefined;
    try reader.readAt(symbol_region.offset, pointer_bytes[0..image.wordSize()]);
    const prb_vaddr = image.readWord(pointer_bytes[0..image.wordSize()]);
    if (prb_vaddr == 0) return error.InvalidPrintkRingAddress;

    const prb_region = try image.resolveRegion(reader, prb_vaddr, prb_size, info.page_offset, info.effectivePhysOffset());
    const prb = try allocator.alloc(u8, @intCast(prb_size));
    defer allocator.free(prb);
    try reader.readAt(prb_region.offset, prb);

    const desc_ring = prb[@intCast(desc_ring_offset)..];
    const text_ring = prb[@intCast(text_ring_offset)..];
    const atomic_offset = try required(info.atomic_long_counter);

    try validateField(desc_ring.len, try required(info.prb_desc_ring_count_bits), 4);
    try validateField(desc_ring.len, try required(info.prb_desc_ring_descs), word_size);
    try validateField(desc_ring.len, try required(info.prb_desc_ring_infos), word_size);
    try validateNested(desc_ring.len, try required(info.prb_desc_ring_head_id), atomic_offset, word_size);
    try validateNested(desc_ring.len, try required(info.prb_desc_ring_tail_id), atomic_offset, word_size);
    try validateField(text_ring.len, try required(info.prb_data_ring_size_bits), 4);
    try validateField(text_ring.len, try required(info.prb_data_ring_data), word_size);
    try validateNested(desc_size, try required(info.prb_desc_state_var), atomic_offset, word_size);
    try validateNested(desc_size, try required(info.prb_desc_text_blk_lpos), try required(info.prb_data_blk_lpos_begin), word_size);
    try validateNested(desc_size, try required(info.prb_desc_text_blk_lpos), try required(info.prb_data_blk_lpos_next), word_size);
    try validateField(printk_info_size, try required(info.printk_info_ts_nsec), 8);
    try validateField(printk_info_size, try required(info.printk_info_text_len), 2);

    const count_bits = image.readU32(field(desc_ring, try required(info.prb_desc_ring_count_bits), 4));
    if (count_bits >= image.pointerBits() - 2) return error.InvalidDescriptorCountBits;
    const desc_count = @as(u64, 1) << @intCast(count_bits);
    const desc_region_size = try elf.mul(desc_size, desc_count);
    const info_region_size = try elf.mul(printk_info_size, desc_count);

    const desc_vaddr = image.readWord(field(desc_ring, try required(info.prb_desc_ring_descs), word_size));
    const info_vaddr = image.readWord(field(desc_ring, try required(info.prb_desc_ring_infos), word_size));
    if (desc_vaddr == 0 or info_vaddr == 0) return error.InvalidPrintkRingAddress;
    const desc_region = try image.resolveRegion(reader, desc_vaddr, desc_region_size, info.page_offset, info.effectivePhysOffset());
    const info_region = try image.resolveRegion(reader, info_vaddr, info_region_size, info.page_offset, info.effectivePhysOffset());

    const text_bits = image.readU32(field(text_ring, try required(info.prb_data_ring_size_bits), 4));
    if (text_bits >= image.pointerBits()) return error.InvalidTextRingSizeBits;
    const text_size = @as(u64, 1) << @intCast(text_bits);
    const text_vaddr = image.readWord(field(text_ring, try required(info.prb_data_ring_data), word_size));
    if (text_vaddr == 0) return error.InvalidPrintkRingAddress;
    const text_region = try image.resolveRegion(reader, text_vaddr, text_size, info.page_offset, info.effectivePhysOffset());

    const tail_offset = try elf.add(try required(info.prb_desc_ring_tail_id), atomic_offset);
    const head_offset = try elf.add(try required(info.prb_desc_ring_head_id), atomic_offset);
    const tail_id = image.readWord(field(desc_ring, tail_offset, word_size));
    const head_id = image.readWord(field(desc_ring, head_offset, word_size));
    const id_mask: u64 = if (image.pointerBits() == 32) 0x3fffffff else 0x3fffffffffffffff;
    if ((tail_id & ~id_mask) != 0 or (head_id & ~id_mask) != 0) return error.InvalidDescriptorIds;

    const desc = try allocator.alloc(u8, @intCast(desc_size));
    defer allocator.free(desc);
    const verify = try allocator.alloc(u8, @intCast(desc_size));
    defer allocator.free(verify);
    const record_info = try allocator.alloc(u8, @intCast(printk_info_size));
    defer allocator.free(record_info);
    const text = try allocator.alloc(u8, max_text_size);
    defer allocator.free(text);

    var id = tail_id;
    var visited: u64 = 0;
    while (true) {
        if (visited >= desc_count) return error.DescriptorSpanExceedsRing;
        visited += 1;
        try dumpRecord(reader, writer, image, info, live, id, desc_count, desc_region, info_region, text_region, text_size, desc, verify, record_info, text);
        if (id == head_id) break;
        id = (id +% 1) & id_mask;
    }
}

fn dumpRecord(
    reader: anytype,
    writer: anytype,
    image: elf.Image,
    info: vmcoreinfo.Metadata,
    live: bool,
    id: u64,
    desc_count: u64,
    desc_region: elf.Region,
    info_region: elf.Region,
    text_region: elf.Region,
    text_ring_size: u64,
    desc: []u8,
    verify: []u8,
    record_info: []u8,
    text: []u8,
) !void {
    const slot = id % desc_count;
    const desc_offset = try elf.mul(slot, desc.len);
    const info_offset = try elf.mul(slot, record_info.len);
    try readRegion(reader, desc_region, desc_offset, desc);

    const state_offset = try elf.add(try required(info.prb_desc_state_var), try required(info.atomic_long_counter));
    const state = image.readWord(field(desc, state_offset, image.wordSize()));
    if (!recordReadable(image.pointerBits(), id, state, live)) return;

    try readRegion(reader, info_region, info_offset, record_info);
    const begin_offset = try elf.add(try required(info.prb_desc_text_blk_lpos), try required(info.prb_data_blk_lpos_begin));
    const next_offset = try elf.add(try required(info.prb_desc_text_blk_lpos), try required(info.prb_data_blk_lpos_next));
    var begin = image.readWord(field(desc, begin_offset, image.wordSize())) % text_ring_size;
    const next = image.readWord(field(desc, next_offset, image.wordSize())) % text_ring_size;
    var text_len: u64 = 0;

    if (begin != next) {
        text_len = image.readU16(field(record_info, try required(info.printk_info_text_len), 2));
        if (begin > next) begin = 0;
        begin = try elf.add(begin, image.wordSize());
        if (begin > next) return error.InvalidTextBlockRange;
        text_len = @min(text_len, next - begin);
        try readRegion(reader, text_region, begin, text[0..@intCast(text_len)]);
    }

    if (live) {
        try readRegion(reader, desc_region, desc_offset, verify);
        if (!std.mem.eql(u8, desc, verify)) return;
    }

    const timestamp = image.readU64(field(record_info, try required(info.printk_info_ts_nsec), 8));
    try writeRecord(writer, timestamp, text[0..@intCast(text_len)]);
}

fn recordReadable(pointer_bits: u7, id: u64, state_value: u64, live: bool) bool {
    const shift: u6 = if (pointer_bits == 32) 30 else 62;
    const mask: u64 = if (pointer_bits == 32) 0x3fffffff else 0x3fffffffffffffff;
    if ((state_value & mask) != id) return false;
    const state = (state_value >> shift) & 3;
    if (state == 2) return true;
    return !live and state == 1;
}

fn writeRecord(writer: anytype, timestamp_ns: u64, text: []const u8) !void {
    var prefix: [64]u8 = undefined;
    var used: usize = 0;
    prefix[used] = '[';
    used += 1;
    const seconds = timestamp_ns / 1_000_000_000;
    const micros = (timestamp_ns % 1_000_000_000) / 1_000;
    used += writePaddedDecimal(prefix[used..], seconds, 5, ' ');
    prefix[used] = '.';
    used += 1;
    used += writePaddedDecimal(prefix[used..], micros, 6, '0');
    @memcpy(prefix[used..][0..2], "] ");
    used += 2;
    try writer.writeAll(prefix[0..used]);

    var escaped: [4096]u8 = undefined;
    var escaped_len: usize = 0;
    for (text) |byte| {
        const pass = (byte >= 0x20 and byte <= 0x7e) or switch (byte) {
            '\t', '\n', '\x0b', '\x0c', '\r' => true,
            else => false,
        };
        const needed: usize = if (pass) 1 else 4;
        if (escaped.len - escaped_len < needed) {
            try writer.writeAll(escaped[0..escaped_len]);
            escaped_len = 0;
        }
        if (pass) {
            escaped[escaped_len] = byte;
            escaped_len += 1;
        } else {
            escaped[escaped_len] = '\\';
            escaped[escaped_len + 1] = 'x';
            escaped[escaped_len + 2] = hex(byte >> 4);
            escaped[escaped_len + 3] = hex(byte & 0xf);
            escaped_len += 4;
        }
    }
    if (escaped_len != 0) try writer.writeAll(escaped[0..escaped_len]);
    try writer.writeAll("\n");
}

fn writePaddedDecimal(dest: []u8, value: u64, minimum: usize, pad: u8) usize {
    var reversed: [20]u8 = undefined;
    var number = value;
    var digits: usize = 0;
    while (true) {
        reversed[digits] = @intCast('0' + number % 10);
        digits += 1;
        number /= 10;
        if (number == 0) break;
    }
    const width = @max(minimum, digits);
    @memset(dest[0 .. width - digits], pad);
    for (0..digits) |i| dest[width - 1 - i] = reversed[i];
    return width;
}

fn hex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

fn boundedSize(value: ?u64) !u64 {
    const size = try required(value);
    if (size == 0 or size > max_struct_size) return error.InvalidPrintkStructureSize;
    return size;
}

fn required(value: ?u64) !u64 {
    return value orelse error.MissingPrintkMetadata;
}

fn validateField(struct_size: u64, offset: u64, field_size: u64) !void {
    if (offset > struct_size or field_size > struct_size - offset) return error.InvalidPrintkFieldOffset;
}

fn validateNested(struct_size: u64, outer: u64, inner: u64, field_size: u64) !void {
    try validateField(struct_size, try elf.add(outer, inner), field_size);
}

fn field(bytes: []const u8, offset: u64, size: u64) []const u8 {
    const start: usize = @intCast(offset);
    const count: usize = @intCast(size);
    return bytes[start..][0..count];
}

fn readRegion(reader: anytype, region: elf.Region, relative: u64, dest: []u8) !void {
    if (relative > region.size or dest.len > region.size - relative) return error.ReadOutsideMemoryRegion;
    try reader.readAt(try elf.add(region.offset, relative), dest);
}

test "record state policy matches dump and live semantics" {
    const id: u64 = 17;
    try std.testing.expect(recordReadable(64, id, (@as(u64, 2) << 62) | id, true));
    try std.testing.expect(recordReadable(64, id, (@as(u64, 1) << 62) | id, false));
    try std.testing.expect(!recordReadable(64, id, (@as(u64, 1) << 62) | id, true));
    try std.testing.expect(!recordReadable(64, id + 1, (@as(u64, 2) << 62) | id, false));
}

test "timestamp and escaping match vmcore-dmesg" {
    const Buffer = struct {
        list: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.allocator, bytes);
        }
    };
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var sink: Buffer = .{ .list = &list, .allocator = std.testing.allocator };
    try writeRecord(&sink, 12_034_567_890, &.{ 'o', 'k', 1, '\n' });
    try std.testing.expectEqualStrings("[   12.034567] ok\\x01\n\n", list.items);
}
