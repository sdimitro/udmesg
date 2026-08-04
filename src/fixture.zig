// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");
const elf = @import("elf.zig");

pub const Options = struct {
    class: elf.Class = .elf64,
    order: elf.ByteOrder = .little,
    direct_map_fallback: bool = false,
    extended_program_header_count: bool = false,
    wrap_ids: bool = false,
    invalid_last_text_range: bool = false,
    unavailable_physical_address: bool = false,
};

pub const Built = struct {
    bytes: []u8,
    desc_file_offset: u64,
    info_file_offset: u64,
    desc_size: u64,
    prb_file_offset: u64,
    word_size: u64,

    pub fn deinit(self: Built, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

const note_offset = 0x200;
const load_offset = 0x1000;
const load_size = 0x5000;
const prb_relative = 0x100;
const desc_relative = 0x1000;
const info_relative = 0x2000;
const text_relative = 0x3000;
const desc_size = 24;
const info_size = 112;
pub const benchmark_record_count = 100_000;
pub const benchmark_text_ring_size = 64 * 1024 * 1024;

pub fn build(allocator: std.mem.Allocator, options: Options) !Built {
    const bytes = try allocator.alloc(u8, load_offset + load_size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    const word_size: u64 = if (options.class == .elf32) 4 else 8;
    const vbase: u64 = if (options.class == .elf32) 0xc0000000 else 0xffff000000000000;
    const pbase: u64 = 0x80000000;
    const machine: u16 = if (options.class == .elf32) 3 else 183;

    var metadata_buffer: [4096]u8 = undefined;
    const metadata = try std.fmt.bufPrint(&metadata_buffer,
        \\SYMBOL(prb)={x}
        \\SIZE(printk_ringbuffer)=88
        \\SIZE(prb_desc)=24
        \\SIZE(printk_info)=112
        \\OFFSET(printk_ringbuffer.desc_ring)=0
        \\OFFSET(printk_ringbuffer.text_data_ring)=48
        \\OFFSET(prb_desc_ring.count_bits)=0
        \\OFFSET(prb_desc_ring.descs)=8
        \\OFFSET(prb_desc_ring.infos)=16
        \\OFFSET(prb_desc_ring.head_id)=24
        \\OFFSET(prb_desc_ring.tail_id)=32
        \\OFFSET(prb_data_ring.size_bits)=0
        \\OFFSET(prb_data_ring.data)=8
        \\OFFSET(atomic_long_t.counter)=0
        \\OFFSET(prb_desc.state_var)=0
        \\OFFSET(prb_desc.text_blk_lpos)=8
        \\OFFSET(prb_data_blk_lpos.begin)=0
        \\OFFSET(prb_data_blk_lpos.next)=8
        \\OFFSET(printk_info.ts_nsec)=8
        \\OFFSET(printk_info.text_len)=16
        \\NUMBER(PHYS_OFFSET)=0x{x}
        \\NUMBER(PAGE_OFFSET)={x}
        \\
    , .{ vbase, pbase, vbase });

    bytes[0] = 0x7f;
    @memcpy(bytes[1..4], "ELF");
    bytes[4] = if (options.class == .elf32) 1 else 2;
    bytes[5] = if (options.order == .little) 1 else 2;
    bytes[6] = 1;
    putU16(bytes, 16, 4, options.order);
    putU16(bytes, 18, machine, options.order);
    putU32(bytes, 20, 1, options.order);

    const header_size: u64 = if (options.class == .elf32) 52 else 64;
    const phentsize: u16 = if (options.class == .elf32) 32 else 56;
    if (options.class == .elf32) {
        putU32(bytes, 28, @intCast(header_size), options.order);
        putU16(bytes, 40, @intCast(header_size), options.order);
        putU16(bytes, 42, phentsize, options.order);
        putU16(bytes, 44, if (options.extended_program_header_count) 0xffff else 2, options.order);
        putU16(bytes, 46, 40, options.order);
        if (options.extended_program_header_count) {
            putU32(bytes, 32, 0x180, options.order);
            putU32(bytes, 0x180 + 28, 2, options.order);
        }
    } else {
        putU64(bytes, 32, header_size, options.order);
        putU16(bytes, 52, @intCast(header_size), options.order);
        putU16(bytes, 54, phentsize, options.order);
        putU16(bytes, 56, if (options.extended_program_header_count) 0xffff else 2, options.order);
        putU16(bytes, 58, 64, options.order);
        if (options.extended_program_header_count) {
            putU64(bytes, 40, 0x180, options.order);
            putU32(bytes, 0x180 + 44, 2, options.order);
        }
    }

    const name = "VMCOREINFO\x00";
    const desc_offset = note_offset + 12 + align4(name.len);
    const note_size = 12 + align4(name.len) + align4(metadata.len);
    putU32(bytes, note_offset, name.len, options.order);
    putU32(bytes, note_offset + 4, metadata.len, options.order);
    putU32(bytes, note_offset + 8, 0, options.order);
    @memcpy(bytes[note_offset + 12 ..][0..name.len], name);
    @memcpy(bytes[desc_offset..][0..metadata.len], metadata);

    writePhdr(bytes, header_size, options.class, options.order, .{
        .kind = 4,
        .offset = note_offset,
        .vaddr = 0,
        .paddr = 0,
        .filesz = note_size,
        .memsz = note_size,
    });
    writePhdr(bytes, header_size + phentsize, options.class, options.order, .{
        .kind = 1,
        .offset = load_offset,
        .vaddr = if (options.direct_map_fallback) 0 else vbase,
        .paddr = if (options.unavailable_physical_address)
            (if (options.class == .elf32) std.math.maxInt(u32) else std.math.maxInt(u64))
        else
            pbase,
        .filesz = load_size,
        .memsz = load_size,
    });

    const load = bytes[load_offset .. load_offset + load_size];
    putWord(load, 0, vbase + prb_relative, word_size, options.order);
    const prb = load[prb_relative .. prb_relative + 88];
    putU32(prb, 0, 2, options.order);
    putWord(prb, 8, vbase + desc_relative, word_size, options.order);
    putWord(prb, 16, vbase + info_relative, word_size, options.order);
    const id_mask: u64 = if (word_size == 4) 0x3fffffff else 0x3fffffffffffffff;
    putWord(prb, 24, if (options.wrap_ids) 1 else 3, word_size, options.order);
    putWord(prb, 32, if (options.wrap_ids) id_mask - 1 else 0, word_size, options.order);
    putU32(prb, 48, 8, options.order);
    putWord(prb, 56, vbase + text_relative, word_size, options.order);

    if (options.wrap_ids) {
        setRecord(load, options, word_size, id_mask - 1, 2, 16, 16 + word_size + 1, 1_000_000_000, "a");
        setRecord(load, options, word_size, id_mask, 2, 32, 32 + word_size + 1, 2_000_000_000, "b");
        setRecord(load, options, word_size, 0, 2, 48, 48 + word_size + 1, 3_000_000_000, "c");
        setRecord(load, options, word_size, 1, 2, 64, 64 + word_size + 1, 4_000_000_000, "d");
    } else {
        setRecord(load, options, word_size, 0, 1, 16, 16 + word_size + 5, 1_234_567_890, "hello");
        setRecord(load, options, word_size, 1, 2, 64, 64, 2_000_000_000, "");
        setRecord(load, options, word_size, 2, 0, 96, 96 + word_size + 7, 3_000_000_000, "ignored");
        if (options.invalid_last_text_range)
            setRecord(load, options, word_size, 3, 2, 100, 104, 12_034_567_890, "")
        else
            setRecord(load, options, word_size, 3, 2, 250, word_size + 3, 12_034_567_890, &.{ 'b', 1, '\n' });
    }

    return .{
        .bytes = bytes,
        .desc_file_offset = load_offset + desc_relative,
        .info_file_offset = load_offset + info_relative,
        .desc_size = desc_size,
        .prb_file_offset = load_offset + prb_relative,
        .word_size = word_size,
    };
}

pub fn writeBenchmark(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const built = try build(allocator, .{});
    defer built.deinit(allocator);

    const desc_count: u64 = 1 << 17;
    const bench_info_relative = alignTo(desc_relative + desc_count * desc_size, 4096);
    const bench_text_relative = alignTo(bench_info_relative + desc_count * info_size, 4096);
    const bench_load_size = bench_text_relative + benchmark_text_ring_size;
    const vbase: u64 = 0xffff000000000000;

    const phdr1 = 64 + 56;
    putU64(built.bytes, phdr1 + 32, bench_load_size, .little);
    putU64(built.bytes, phdr1 + 40, bench_load_size, .little);
    const prb = built.bytes[@intCast(built.prb_file_offset)..][0..88];
    putU32(prb, 0, 17, .little);
    putWord(prb, 8, vbase + desc_relative, 8, .little);
    putWord(prb, 16, vbase + bench_info_relative, 8, .little);
    putWord(prb, 24, benchmark_record_count - 1, 8, .little);
    putWord(prb, 32, 0, 8, .little);
    putU32(prb, 48, 26, .little);
    putWord(prb, 56, vbase + bench_text_relative, 8, .little);

    const descriptors = try allocator.alloc(u8, @intCast(desc_count * desc_size));
    defer allocator.free(descriptors);
    @memset(descriptors, 0);
    const infos = try allocator.alloc(u8, @intCast(desc_count * info_size));
    defer allocator.free(infos);
    @memset(infos, 0);
    const text_bytes_used: u64 = benchmark_record_count * 16;
    const texts = try allocator.alloc(u8, @intCast(text_bytes_used));
    defer allocator.free(texts);
    @memset(texts, 0);

    var id: u64 = 0;
    while (id < benchmark_record_count) : (id += 1) {
        const desc = descriptors[id * desc_size ..][0..desc_size];
        const begin = id * 16;
        putWord(desc, 0, (@as(u64, 2) << 62) | id, 8, .little);
        putWord(desc, 8, begin, 8, .little);
        putWord(desc, 16, begin + 9, 8, .little);

        const record_info = infos[id * info_size ..][0..info_size];
        putU64(record_info, 8, id * 1_000_000, .little);
        putU16(record_info, 16, 1, .little);
        texts[begin + 8] = 'x';
    }

    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.createFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.setLength(io, load_offset + bench_load_size);
    try file.writePositionalAll(io, built.bytes, 0);
    try file.writePositionalAll(io, descriptors, load_offset + desc_relative);
    try file.writePositionalAll(io, infos, load_offset + bench_info_relative);
    try file.writePositionalAll(io, texts, load_offset + bench_text_relative);
}

fn setRecord(
    load: []u8,
    options: Options,
    word_size: u64,
    id: u64,
    state: u2,
    begin: u64,
    next: u64,
    timestamp: u64,
    message: []const u8,
) void {
    const slot = id % 4;
    const desc = load[desc_relative + slot * desc_size ..][0..desc_size];
    const shift: u6 = if (word_size == 4) 30 else 62;
    putWord(desc, 0, (@as(u64, state) << shift) | id, word_size, options.order);
    putWord(desc, 8, begin, word_size, options.order);
    putWord(desc, 16, next, word_size, options.order);

    const record_info = load[info_relative + slot * info_size ..][0..info_size];
    putU64(record_info, 8, timestamp, options.order);
    putU16(record_info, 16, @intCast(message.len), options.order);

    if (message.len != 0) {
        const data_offset: u64 = if (begin > next) word_size else begin + word_size;
        @memcpy(load[text_relative + data_offset ..][0..message.len], message);
    }
}

fn writePhdr(bytes: []u8, offset: u64, class: elf.Class, order: elf.ByteOrder, ph: elf.ProgramHeader) void {
    const base: usize = @intCast(offset);
    if (class == .elf32) {
        putU32(bytes, base, ph.kind, order);
        putU32(bytes, base + 4, @intCast(ph.offset), order);
        putU32(bytes, base + 8, @intCast(ph.vaddr), order);
        putU32(bytes, base + 12, @intCast(ph.paddr), order);
        putU32(bytes, base + 16, @intCast(ph.filesz), order);
        putU32(bytes, base + 20, @intCast(ph.memsz), order);
    } else {
        putU32(bytes, base, ph.kind, order);
        putU64(bytes, base + 8, ph.offset, order);
        putU64(bytes, base + 16, ph.vaddr, order);
        putU64(bytes, base + 24, ph.paddr, order);
        putU64(bytes, base + 32, ph.filesz, order);
        putU64(bytes, base + 40, ph.memsz, order);
    }
}

fn putWord(bytes: []u8, offset: u64, value: u64, size: u64, order: elf.ByteOrder) void {
    if (size == 4) putU32(bytes, @intCast(offset), @intCast(value), order) else putU64(bytes, @intCast(offset), value, order);
}

fn putU16(bytes: []u8, offset: usize, value: u64, order: elf.ByteOrder) void {
    putInteger(bytes[offset..][0..2], value, order);
}

fn putU32(bytes: []u8, offset: usize, value: u64, order: elf.ByteOrder) void {
    putInteger(bytes[offset..][0..4], value, order);
}

fn putU64(bytes: []u8, offset: usize, value: u64, order: elf.ByteOrder) void {
    putInteger(bytes[offset..][0..8], value, order);
}

fn putInteger(dest: []u8, value: u64, order: elf.ByteOrder) void {
    for (dest, 0..) |*byte, i| {
        const shift = if (order == .little) i * 8 else (dest.len - 1 - i) * 8;
        byte.* = @truncate(value >> @intCast(shift));
    }
}

fn align4(value: usize) usize {
    return (value + 3) & ~@as(usize, 3);
}

fn alignTo(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}
