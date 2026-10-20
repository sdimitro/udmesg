# udmesg

## Project status

`udmesg` has outlived its original purpose. The
[kexec-tools change to stream lockless printk records](https://github.com/horms/kexec-tools/commit/2bcd7801948d853499a5cc2b538f65563c791a1a)
lets `vmcore-dmesg` extract the kernel log from `/proc/vmcore` in a crash kernel
without copying the entire printk rings into memory. For this use case, use a
`kexec-tools` build that includes that change instead of `udmesg`.

`udmesg` is a small, static utility that extracts the Linux kernel log from the
modern lockless printk ring stored in a raw ELF core. It was created for
memory-constrained crash kernels where copying a large descriptor, info, and
text ring can trigger the OOM killer before any log is recovered.

The printk decoder keeps one descriptor, one info record, and at most one `u16`
length text record in memory. Its memory use therefore does not grow with the
configured printk ring size or the number of descriptors.

There are two binaries. `udmesg` keeps the dependency-free raw ELF reader.
`udmesg-kdump` links libkdumpfile and its compression codecs statically to read
saved makedumpfile dumps, including compressed and flattened dumps. Its target
architecture can differ from the architecture of the binary running it.

## Usage

```text
Usage: udmesg [OPTIONS] CORE

Options:
  -o, --output PATH  Write to PATH instead of stdout; '-' means stdout
  -h, --help         Show help
      --version      Show the program version
```

Examples:

```sh
udmesg /proc/vmcore > dmesg.txt
udmesg -o dmesg.txt /proc/vmcore
udmesg /proc/kcore
udmesg-kdump dump.202610071921 > dmesg.txt
udmesg-kdump -o dmesg.txt dump.part1 dump.part2
```

Output files are checked against the input by device and inode before they are
truncated. If parsing or output fails after records have been written, partial
output is deliberately retained.

Exit status is `0` for success, `2` for command-line errors, and `1` for input,
format, or output errors. Diagnostics are written to standard error.

## Supported inputs

`udmesg` accepts seekable raw ELF core files:

- `/proc/kcore` from a live kernel;
- `/proc/vmcore` from a crash dump capture kernel; and
- a raw saved copy of either file.

The input parser handles ELF32 and ELF64, both ELF byte orders, normal and
extended program-header counts, direct virtual mappings, and the
`PAGE_OFFSET` plus `PHYS_OFFSET`/`phys_ram_base` fallback used by kexec-tools.
The architecture of the binary running `udmesg` does not need to match the
architecture recorded in the core.

`udmesg-kdump` also accepts the ELF, KDUMP-compressed, flattened ELF/KDUMP, and
split KDUMP formats supported by libkdumpfile 0.5.6. Pass every part of a split
dump as a positional argument. Its static build includes zlib, LZO, Snappy, and
Zstandard support. Both binaries require the modern lockless printk ring
identified by `SYMBOL(prb)` in VMCOREINFO; legacy printk rings, stdin, and
external symbol lookup remain unsupported.

For live `/proc/kcore`, `udmesg` accepts finalized records only and verifies
that each descriptor did not change while its data was being copied. For a
vmcore it also accepts the last committed record, which may have been left
unfinalized by the crash.

## Build

Zig 0.16.0 is required. The plain `udmesg` build has no package or libc
dependencies.

```sh
zig build
zig build test
zig build release
```

`zig build release` produces stripped, statically linked binaries:

```text
zig-out/bin/udmesg-linux-amd64
zig-out/bin/udmesg-linux-arm64
```

Build `udmesg-kdump` on a native Linux amd64 or arm64 host with Docker:

```sh
docker run --rm -v "$PWD:/work" -w /work alpine:3.22 \
  sh tools/build-kdump-static.sh 1.2.3
```

This pins the Codeberg libkdumpfile 0.5.6 source archive and Zig 0.16.0 by
SHA-256, builds all compression codecs into the binary, and produces
`zig-out/bin/udmesg-kdump-linux-amd64` or
`zig-out/bin/udmesg-kdump-linux-arm64`. The binary needs no shared libraries
at runtime. To use an existing static dependency build, pass its directory to
`zig build kdump-release -Dkdump-prefix=DIR -Dtarget=ARCH-linux-musl`.

Set a release version with `-Dversion=1.2.3`. Local builds default to
`0.1.0-dev`.

## Tests and benchmark

The test suite builds synthetic sparse ELF cores covering:

- every ELF32/ELF64 and little-/big-endian combination;
- extended program-header counts and direct-map fallback;
- committed, finalized, empty, skipped, wrapped, and truncated records;
- descriptor ID wraparound and live descriptor mutation; and
- malformed ELF, VMCOREINFO, address, and ring geometry.

`zig build test` also exhaustively injects an out-of-memory failure at every
allocation point in a full extraction and verifies that all earlier allocations
are released. Zig's testing allocator reports leaks, double frees, and invalid
frees in the rest of the test suite.

Golden output follows `vmcore-dmesg`: timestamps are truncated to microseconds,
ASCII printable and whitespace bytes pass through, other bytes use lowercase
`\\xNN`, and every emitted record ends in a newline.

The kdump binary was also exercised on Wreakit makedumpfile-compressed amd64
and arm64 archives with the same arm64 executable. Its amd64 output matched the
archived `dmesg` reference byte for byte.

Run the repeatable benchmark with:

```sh
zig build bench
```

It creates a sparse fixture with a 64 MiB text ring and 100,000 active records,
then reports binary size, apparent fixture size, elapsed time, and peak RSS when
the host's `time` implementation exposes it.

## Releases

Pushing an explicit `vMAJOR.MINOR.PATCH` tag runs the release workflow. It
builds static amd64 and arm64 binaries and installable Debian packages for both
flavors, then
publishes each artifact and its SHA-256 file in a GitHub Release with generated
notes. Debian packages use names such as `udmesg_0.1.0_amd64.deb` and install
the executable at `/usr/bin/udmesg`. Tags are never created automatically from
`main`.

The kdump assets are named `udmesg-kdump-linux-amd64` and
`udmesg-kdump-linux-arm64`; Debian packages such as
`udmesg-kdump_0.1.0_arm64.deb` install `/usr/bin/udmesg-kdump`.
