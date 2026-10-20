// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

pub const Metadata = struct {
    prb_vaddr: ?u64 = null,
    printk_ringbuffer_size: ?u64 = null,
    prb_desc_size: ?u64 = null,
    printk_info_size: ?u64 = null,

    printk_ringbuffer_desc_ring: ?u64 = null,
    printk_ringbuffer_text_data_ring: ?u64 = null,
    prb_desc_ring_count_bits: ?u64 = null,
    prb_desc_ring_descs: ?u64 = null,
    prb_desc_ring_infos: ?u64 = null,
    prb_desc_ring_head_id: ?u64 = null,
    prb_desc_ring_tail_id: ?u64 = null,
    prb_data_ring_size_bits: ?u64 = null,
    prb_data_ring_data: ?u64 = null,
    atomic_long_counter: ?u64 = null,
    prb_desc_state_var: ?u64 = null,
    prb_desc_text_blk_lpos: ?u64 = null,
    prb_data_blk_lpos_begin: ?u64 = null,
    prb_data_blk_lpos_next: ?u64 = null,
    printk_info_ts_nsec: ?u64 = null,
    printk_info_text_len: ?u64 = null,

    phys_offset: ?u64 = null,
    phys_ram_base: ?u64 = null,
    page_offset: ?u64 = null,
    kimage_voffset: ?u64 = null,
    va_bits: ?u64 = null,

    pub fn effectivePhysOffset(self: Metadata) ?u64 {
        return self.phys_offset orelse self.phys_ram_base;
    }
};

const max_line = 4096;

pub fn parse(reader: anytype, offset: u64, size: u64) !Metadata {
    if (size == 0) return error.EmptyVmcoreInfo;
    var result: Metadata = .{};
    var chunk: [4096]u8 = undefined;
    var line: [max_line]u8 = undefined;
    var line_len: usize = 0;
    var cursor: u64 = 0;

    while (cursor < size) {
        const remaining = size - cursor;
        const count: usize = @intCast(@min(remaining, chunk.len));
        try reader.readAt(try checkedAdd(offset, cursor), chunk[0..count]);
        for (chunk[0..count]) |byte| {
            if (byte == '\n') {
                try parseLine(&result, line[0..line_len]);
                line_len = 0;
            } else {
                if (line_len == line.len) return error.VmcoreInfoLineTooLong;
                line[line_len] = byte;
                line_len += 1;
            }
        }
        cursor += count;
    }
    if (line_len != 0) try parseLine(&result, line[0..line_len]);
    return result;
}

fn parseLine(meta: *Metadata, line: []const u8) !void {
    if (line.len == 0) return;
    try setHex(line, "SYMBOL(prb)=", &meta.prb_vaddr);

    try setDecimal(line, "SIZE(printk_ringbuffer)=", &meta.printk_ringbuffer_size);
    try setDecimal(line, "SIZE(prb_desc)=", &meta.prb_desc_size);
    try setDecimal(line, "SIZE(printk_info)=", &meta.printk_info_size);

    try setDecimal(line, "OFFSET(printk_ringbuffer.desc_ring)=", &meta.printk_ringbuffer_desc_ring);
    try setDecimal(line, "OFFSET(printk_ringbuffer.text_data_ring)=", &meta.printk_ringbuffer_text_data_ring);
    try setDecimal(line, "OFFSET(prb_desc_ring.count_bits)=", &meta.prb_desc_ring_count_bits);
    try setDecimal(line, "OFFSET(prb_desc_ring.descs)=", &meta.prb_desc_ring_descs);
    try setDecimal(line, "OFFSET(prb_desc_ring.infos)=", &meta.prb_desc_ring_infos);
    try setDecimal(line, "OFFSET(prb_desc_ring.head_id)=", &meta.prb_desc_ring_head_id);
    try setDecimal(line, "OFFSET(prb_desc_ring.tail_id)=", &meta.prb_desc_ring_tail_id);
    try setDecimal(line, "OFFSET(prb_data_ring.size_bits)=", &meta.prb_data_ring_size_bits);
    try setDecimal(line, "OFFSET(prb_data_ring.data)=", &meta.prb_data_ring_data);
    try setDecimal(line, "OFFSET(atomic_long_t.counter)=", &meta.atomic_long_counter);
    try setDecimal(line, "OFFSET(prb_desc.state_var)=", &meta.prb_desc_state_var);
    try setDecimal(line, "OFFSET(prb_desc.text_blk_lpos)=", &meta.prb_desc_text_blk_lpos);
    try setDecimal(line, "OFFSET(prb_data_blk_lpos.begin)=", &meta.prb_data_blk_lpos_begin);
    try setDecimal(line, "OFFSET(prb_data_blk_lpos.next)=", &meta.prb_data_blk_lpos_next);
    try setDecimal(line, "OFFSET(printk_info.ts_nsec)=", &meta.printk_info_ts_nsec);
    try setDecimal(line, "OFFSET(printk_info.text_len)=", &meta.printk_info_text_len);

    try setAuto(line, "NUMBER(PHYS_OFFSET)=", &meta.phys_offset);
    try setAuto(line, "NUMBER(phys_ram_base)=", &meta.phys_ram_base);
    try setHex(line, "NUMBER(PAGE_OFFSET)=", &meta.page_offset);
    try setHex(line, "NUMBER(kimage_voffset)=", &meta.kimage_voffset);
    try setDecimal(line, "NUMBER(VA_BITS)=", &meta.va_bits);
}

fn setDecimal(line: []const u8, prefix: []const u8, field: *?u64) !void {
    if (!std.mem.startsWith(u8, line, prefix)) return;
    field.* = try parseInteger(line[prefix.len..], 10, false);
}

fn setHex(line: []const u8, prefix: []const u8, field: *?u64) !void {
    if (!std.mem.startsWith(u8, line, prefix)) return;
    field.* = try parseInteger(line[prefix.len..], 16, true);
}

fn setAuto(line: []const u8, prefix: []const u8, field: *?u64) !void {
    if (!std.mem.startsWith(u8, line, prefix)) return;
    const value = line[prefix.len..];
    field.* = parseInteger(value, 10, false) catch try parseInteger(value, 16, true);
}

fn parseInteger(raw: []const u8, base: u8, allow_prefix: bool) !u64 {
    var text = raw;
    if (allow_prefix and text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) text = text[2..];
    if (text.len == 0) return error.InvalidVmcoreInfoValue;
    var value: u64 = 0;
    for (text) |byte| {
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => return error.InvalidVmcoreInfoValue,
        };
        if (digit >= base) return error.InvalidVmcoreInfoValue;
        if (value > (std.math.maxInt(u64) - @as(u64, digit)) / @as(u64, base)) return error.IntegerOverflow;
        value = value * @as(u64, base) + digit;
    }
    return value;
}

fn checkedAdd(a: u64, b: u64) !u64 {
    if (a > std.math.maxInt(u64) - b) return error.IntegerOverflow;
    return a + b;
}

test "VMCOREINFO parses required decimal and hexadecimal fields" {
    const input = @import("input.zig");
    const text =
        "SYMBOL(prb)=ffff000012340000\n" ++
        "SIZE(printk_ringbuffer)=88\n" ++
        "OFFSET(prb_desc.state_var)=0\n" ++
        "NUMBER(PHYS_OFFSET)=0x80000000\n" ++
        "NUMBER(PAGE_OFFSET)=ffff000000000000";
    var reader: input.MemoryReader = .{ .bytes = text };
    const info = try parse(&reader, 0, text.len);
    try std.testing.expectEqual(@as(?u64, 0xffff000012340000), info.prb_vaddr);
    try std.testing.expectEqual(@as(?u64, 88), info.printk_ringbuffer_size);
    try std.testing.expectEqual(@as(?u64, 0), info.prb_desc_state_var);
    try std.testing.expectEqual(@as(?u64, 0x80000000), info.phys_offset);
    try std.testing.expectEqual(@as(?u64, 0xffff000000000000), info.page_offset);
}
