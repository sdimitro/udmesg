// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const elf = @import("elf.zig");
const input = @import("input.zig");
const printk = @import("printk.zig");
const vmcoreinfo = @import("vmcoreinfo.zig");

const usage =
    \\Usage: udmesg [OPTIONS] CORE
    \\
    \\Extract the modern lockless Linux printk ring from a raw ELF kcore or vmcore.
    \\
    \\Options:
    \\  -o, --output PATH  Write to PATH instead of stdout; '-' means stdout
    \\  -h, --help         Show this help
    \\      --version      Show the program version
    \\
;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        reportError(err);
        return 1;
    };
}

fn reportError(err: anyerror) void {
    const message = switch (err) {
        error.UnsupportedPrintkFormat => "unsupported printk format: SYMBOL(prb) is missing; only the modern lockless ring is supported",
        error.MissingPrintkMetadata => "unsupported printk format: required lockless-ring VMCOREINFO metadata is missing",
        error.MissingVmcoreInfo => "VMCOREINFO was not found in the ELF notes",
        error.InputOutputAlias => "refusing to overwrite the input core file",
        else => return std.debug.print("udmesg: {s}\n", .{@errorName(err)}),
    };
    std.debug.print("udmesg: {s}\n", .{message});
}

fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = cli.parse(args) catch |err| {
        std.debug.print("udmesg: {s}\n\n{s}", .{ @errorName(err), usage });
        return 2;
    };
    switch (options.action) {
        .help => {
            try std.Io.File.stdout().writeStreamingAll(init.io, usage);
            return 0;
        },
        .version => {
            var buffer: [128]u8 = undefined;
            var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
            try writer.interface.print("udmesg {s}\n", .{build_options.version});
            try writer.interface.flush();
            return 0;
        },
        .extract => {},
    }

    const input_file = try openRead(init.io, options.input.?);
    defer input_file.close(init.io);
    const live = try isLiveInput(init.io, input_file);
    var file_reader: input.FileReader = .{ .file = input_file, .io = init.io };
    const image = try elf.Image.parse(&file_reader);
    const vmcore_region = try image.findVmcoreInfo(&file_reader);
    const metadata = try vmcoreinfo.parse(&file_reader, vmcore_region.offset, vmcore_region.size);

    var output_file: ?std.Io.File = null;
    if (options.output) |path| if (!std.mem.eql(u8, path, "-")) {
        const file = try createWithoutTruncating(init.io, path);
        errdefer file.close(init.io);
        if (try sameFile(init.io, input_file, file)) return error.InputOutputAlias;
        try file.setLength(init.io, 0);
        output_file = file;
    };
    defer if (output_file) |file| file.close(init.io);

    const destination = output_file orelse std.Io.File.stdout();
    var output_buffer: [8192]u8 = undefined;
    var file_writer = destination.writerStreaming(init.io, &output_buffer);
    var sink: Sink = .{ .writer = &file_writer.interface };
    var flushed = false;
    defer if (!flushed) file_writer.interface.flush() catch {};
    try printk.extract(init.arena.allocator(), &file_reader, &sink, image, metadata, live);
    try file_writer.interface.flush();
    flushed = true;
    return 0;
}

const Sink = struct {
    writer: *std.Io.Writer,

    pub fn writeAll(self: *Sink, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
    }
};

fn openRead(io: std.Io, path: []const u8) !std.Io.File {
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        std.Io.Dir.cwd().openFile(io, path, .{});
}

fn createWithoutTruncating(io: std.Io, path: []const u8) !std.Io.File {
    const options: std.Io.Dir.CreateFileOptions = .{ .truncate = false };
    return if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(io, path, options)
    else
        std.Io.Dir.cwd().createFile(io, path, options);
}

fn isLiveInput(io: std.Io, file: std.Io.File) !bool {
    const stat = try file.stat(io);
    if (stat.kind == .character_device) return true;
    const kcore = openRead(io, "/proc/kcore") catch return false;
    defer kcore.close(io);
    return sameFile(io, file, kcore);
}

fn sameFile(io: std.Io, a: std.Io.File, b: std.Io.File) !bool {
    if (builtin.os.tag == .linux) {
        const ai = try linuxIdentity(a);
        const bi = try linuxIdentity(b);
        return ai.ino == bi.ino and ai.dev_major == bi.dev_major and ai.dev_minor == bi.dev_minor;
    }
    const ai = try a.stat(io);
    const bi = try b.stat(io);
    return ai.inode == bi.inode;
}

const LinuxIdentity = struct { ino: u64, dev_major: u32, dev_minor: u32 };

fn linuxIdentity(file: std.Io.File) !LinuxIdentity {
    const linux = std.os.linux;
    var statx = std.mem.zeroes(linux.Statx);
    const result = linux.statx(file.handle, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &statx);
    if (linux.errno(result) != .SUCCESS) return error.StatFailed;
    return .{ .ino = statx.ino, .dev_major = statx.dev_major, .dev_minor = statx.dev_minor };
}
