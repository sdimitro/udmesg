// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

pub const Class = enum { elf32, elf64 };
pub const ByteOrder = enum { little, big };

pub const Region = struct {
    offset: u64,
    size: u64,
};

pub const ProgramHeader = struct {
    kind: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
};

pub const Image = struct {
    class: Class,
    order: ByteOrder,
    machine: u16,
    phoff: u64,
    phentsize: u16,
    phnum: u64,
    shoff: u64,
    shentsize: u16,

    pub fn parse(reader: anytype) !Image {
        var ident: [16]u8 = undefined;
        try reader.readAt(0, &ident);
        if (!std.mem.eql(u8, ident[0..4], "\x7fELF")) return error.NotElf;
        if (ident[6] != 1) return error.UnsupportedElfVersion;

        const class: Class = switch (ident[4]) {
            1 => .elf32,
            2 => .elf64,
            else => return error.UnsupportedElfClass,
        };
        const order: ByteOrder = switch (ident[5]) {
            1 => .little,
            2 => .big,
            else => return error.UnsupportedElfByteOrder,
        };

        var raw: [64]u8 = undefined;
        const header_size: usize = if (class == .elf32) 52 else 64;
        try reader.readAt(0, raw[0..header_size]);
        if (u16At(order, raw[16..18]) != 4) return error.NotElfCore;
        if (u32At(order, raw[20..24]) != 1) return error.UnsupportedElfVersion;

        var image: Image = if (class == .elf32) .{
            .class = class,
            .order = order,
            .machine = u16At(order, raw[18..20]),
            .phoff = u32At(order, raw[28..32]),
            .shoff = u32At(order, raw[32..36]),
            .phentsize = u16At(order, raw[42..44]),
            .phnum = u16At(order, raw[44..46]),
            .shentsize = u16At(order, raw[46..48]),
        } else .{
            .class = class,
            .order = order,
            .machine = u16At(order, raw[18..20]),
            .phoff = u64At(order, raw[32..40]),
            .shoff = u64At(order, raw[40..48]),
            .phentsize = u16At(order, raw[54..56]),
            .phnum = u16At(order, raw[56..58]),
            .shentsize = u16At(order, raw[58..60]),
        };

        const expected_phentsize: u16 = if (class == .elf32) 32 else 56;
        if (image.phentsize != expected_phentsize) return error.InvalidProgramHeaderSize;
        if (image.phnum == 0xffff) {
            const expected_shentsize: u16 = if (class == .elf32) 40 else 64;
            if (image.shoff == 0 or image.shentsize != expected_shentsize) return error.InvalidExtendedProgramHeaderCount;
            var shdr: [64]u8 = undefined;
            try reader.readAt(image.shoff, shdr[0..expected_shentsize]);
            image.phnum = if (class == .elf32)
                u32At(order, shdr[28..32])
            else
                u32At(order, shdr[44..48]);
        }
        if (image.phnum == 0 or image.phnum > 1_000_000) return error.InvalidProgramHeaderCount;
        _ = try rangeEnd(image.phoff, try mul(image.phnum, image.phentsize));
        return image;
    }

    pub fn pointerBits(self: Image) u7 {
        return if (self.class == .elf32) 32 else 64;
    }

    pub fn wordSize(self: Image) u8 {
        return if (self.class == .elf32) 4 else 8;
    }

    pub fn programHeader(self: Image, reader: anytype, index: u64) !ProgramHeader {
        if (index >= self.phnum) return error.InvalidProgramHeaderIndex;
        const offset = try add(self.phoff, try mul(index, self.phentsize));
        var raw: [56]u8 = undefined;
        try reader.readAt(offset, raw[0..self.phentsize]);
        const ph: ProgramHeader = if (self.class == .elf32) .{
            .kind = u32At(self.order, raw[0..4]),
            .offset = u32At(self.order, raw[4..8]),
            .vaddr = u32At(self.order, raw[8..12]),
            .paddr = u32At(self.order, raw[12..16]),
            .filesz = u32At(self.order, raw[16..20]),
            .memsz = u32At(self.order, raw[20..24]),
        } else .{
            .kind = u32At(self.order, raw[0..4]),
            .offset = u64At(self.order, raw[8..16]),
            .vaddr = u64At(self.order, raw[16..24]),
            .paddr = u64At(self.order, raw[24..32]),
            .filesz = u64At(self.order, raw[32..40]),
            .memsz = u64At(self.order, raw[40..48]),
        };
        _ = try rangeEnd(ph.offset, ph.filesz);
        _ = try rangeEnd(ph.vaddr, ph.memsz);
        // /proc/kcore uses an all-ones p_paddr for mappings that have no
        // meaningful physical address. The virtual mapping remains valid.
        if (!self.physicalAddressUnavailable(ph.paddr))
            _ = try rangeEnd(ph.paddr, ph.memsz);
        return ph;
    }

    pub fn findVmcoreInfo(self: Image, reader: anytype) !Region {
        var i: u64 = 0;
        while (i < self.phnum) : (i += 1) {
            const ph = try self.programHeader(reader, i);
            if (ph.kind != 4) continue;
            if (try self.findVmcoreInfoInNotes(reader, .{ .offset = ph.offset, .size = ph.filesz })) |region|
                return region;
        }
        return error.MissingVmcoreInfo;
    }

    fn findVmcoreInfoInNotes(self: Image, reader: anytype, notes: Region) !?Region {
        const notes_end = try rangeEnd(notes.offset, notes.size);
        var cursor = notes.offset;
        while (cursor < notes_end) {
            if (notes_end - cursor < 12) return error.MalformedElfNote;
            var header: [12]u8 = undefined;
            try reader.readAt(cursor, &header);
            const name_size: u64 = u32At(self.order, header[0..4]);
            const desc_size: u64 = u32At(self.order, header[4..8]);
            const note_type = u32At(self.order, header[8..12]);
            const name_offset = try add(cursor, 12);
            const desc_offset = try add(name_offset, try align4(name_size));
            const next = try add(desc_offset, try align4(desc_size));
            if (next > notes_end) return error.MalformedElfNote;

            if (name_size >= 11 and note_type == 0) {
                var name: [11]u8 = undefined;
                try reader.readAt(name_offset, &name);
                if (std.mem.eql(u8, &name, "VMCOREINFO\x00"))
                    return .{ .offset = desc_offset, .size = desc_size };
            }
            cursor = next;
        }
        return null;
    }

    pub fn resolveRegion(
        self: Image,
        reader: anytype,
        vaddr: u64,
        size: u64,
        page_offset: ?u64,
        phys_offset: ?u64,
    ) !Region {
        if (size == 0) return error.InvalidMemoryRegion;
        const vend = try rangeEnd(vaddr, size);
        var i: u64 = 0;
        while (i < self.phnum) : (i += 1) {
            const ph = try self.programHeader(reader, i);
            if (ph.kind != 1 or vaddr < ph.vaddr) continue;
            const file_vend = try rangeEnd(ph.vaddr, ph.filesz);
            if (vend > file_vend) continue;
            return .{ .offset = try add(ph.offset, vaddr - ph.vaddr), .size = size };
        }

        if (page_offset) |page| if (phys_offset) |phys| {
            const delta = if (page >= phys) page - phys else return error.InvalidDirectMap;
            if (vaddr < delta) return error.UnmappedKernelAddress;
            const paddr = vaddr - delta;
            const pend = try rangeEnd(paddr, size);
            i = 0;
            while (i < self.phnum) : (i += 1) {
                const ph = try self.programHeader(reader, i);
                if (ph.kind != 1 or self.physicalAddressUnavailable(ph.paddr) or paddr < ph.paddr) continue;
                const file_pend = try rangeEnd(ph.paddr, ph.filesz);
                if (pend > file_pend) continue;
                return .{ .offset = try add(ph.offset, paddr - ph.paddr), .size = size };
            }
        };
        return error.UnmappedKernelAddress;
    }

    fn physicalAddressUnavailable(self: Image, paddr: u64) bool {
        const unavailable: u64 = if (self.class == .elf32) std.math.maxInt(u32) else std.math.maxInt(u64);
        return paddr == unavailable;
    }

    pub fn readWord(self: Image, bytes: []const u8) u64 {
        return if (self.class == .elf32) u32At(self.order, bytes[0..4]) else u64At(self.order, bytes[0..8]);
    }

    pub fn readU16(self: Image, bytes: []const u8) u16 {
        return u16At(self.order, bytes[0..2]);
    }

    pub fn readU32(self: Image, bytes: []const u8) u32 {
        return u32At(self.order, bytes[0..4]);
    }

    pub fn readU64(self: Image, bytes: []const u8) u64 {
        return u64At(self.order, bytes[0..8]);
    }
};

fn u16At(order: ByteOrder, bytes: []const u8) u16 {
    return switch (order) {
        .little => @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8),
        .big => (@as(u16, bytes[0]) << 8) | bytes[1],
    };
}

fn u32At(order: ByteOrder, bytes: []const u8) u32 {
    var value: u32 = 0;
    switch (order) {
        .little => {
            for (bytes[0..4], 0..) |byte, shift| value |= @as(u32, byte) << @intCast(shift * 8);
        },
        .big => {
            for (bytes[0..4]) |byte| value = (value << 8) | byte;
        },
    }
    return value;
}

fn u64At(order: ByteOrder, bytes: []const u8) u64 {
    var value: u64 = 0;
    switch (order) {
        .little => {
            for (bytes[0..8], 0..) |byte, shift| value |= @as(u64, byte) << @intCast(shift * 8);
        },
        .big => {
            for (bytes[0..8]) |byte| value = (value << 8) | byte;
        },
    }
    return value;
}

pub fn add(a: u64, b: u64) !u64 {
    if (a > std.math.maxInt(u64) - b) return error.IntegerOverflow;
    return a + b;
}

pub fn mul(a: u64, b: u64) !u64 {
    if (a != 0 and b > std.math.maxInt(u64) / a) return error.IntegerOverflow;
    return a * b;
}

fn rangeEnd(start: u64, size: u64) !u64 {
    return add(start, size);
}

fn align4(value: u64) !u64 {
    return (try add(value, 3)) & ~@as(u64, 3);
}

test "ELF integer readers honor byte order" {
    try std.testing.expectEqual(@as(u16, 0x1234), u16At(.little, &.{ 0x34, 0x12 }));
    try std.testing.expectEqual(@as(u16, 0x1234), u16At(.big, &.{ 0x12, 0x34 }));
    try std.testing.expectEqual(@as(u32, 0x12345678), u32At(.little, &.{ 0x78, 0x56, 0x34, 0x12 }));
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), u64At(.big, &.{ 1, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }));
}
