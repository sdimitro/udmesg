# udmesg

`udmesg` is a small, static utility that extracts the Linux kernel log from the
modern lockless printk ring stored in a raw ELF core. It is intended for
memory-constrained crash kernels where copying a large descriptor, info, and
text ring can trigger the OOM killer before any log is recovered.

The extractor keeps one descriptor, one info record, and at most one `u16`
length text record in memory. Its memory use therefore does not grow with the
configured printk ring size or the number of descriptors.

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

Version 0.1 supports only the modern lockless printk ring identified by
`SYMBOL(prb)` in VMCOREINFO. Legacy byte rings, the older structured record
format, makedumpfile-compressed dumps, stdin, decompression, and external symbol
lookup are intentionally out of scope.

For live `/proc/kcore`, `udmesg` accepts finalized records only and verifies
that each descriptor did not change while its data was being copied. For a
vmcore it also accepts the last committed record, which may have been left
unfinalized by the crash.

## Build

Zig 0.16.0 is required. There are no package or libc dependencies.

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

Set a release version with `-Dversion=1.2.3`. Local builds default to
`0.1.0-dev`.

## Tests and benchmark

The test suite builds synthetic sparse ELF cores covering:

- every ELF32/ELF64 and little-/big-endian combination;
- extended program-header counts and direct-map fallback;
- committed, finalized, empty, skipped, wrapped, and truncated records;
- descriptor ID wraparound and live descriptor mutation; and
- malformed ELF, VMCOREINFO, address, and ring geometry.

Golden output follows `vmcore-dmesg`: timestamps are truncated to microseconds,
ASCII printable and whitespace bytes pass through, other bytes use lowercase
`\\xNN`, and every emitted record ends in a newline.

Run the repeatable benchmark with:

```sh
zig build bench
```

It creates a sparse fixture with a 64 MiB text ring and 100,000 active records,
then reports binary size, apparent fixture size, elapsed time, and peak RSS when
the host's `time` implementation exposes it.

## Releases

Pushing an explicit `vMAJOR.MINOR.PATCH` tag runs the release workflow. It
builds static amd64 and arm64 binaries, generates individual SHA-256 files, and
publishes all four assets in a GitHub Release with generated notes. Tags are
never created automatically from `main`.

## Provenance and license

The ELF, VMCOREINFO, and printk behavior is derived from the GPL-licensed
`vmcore-dmesg` implementation in kexec-tools, including Serapheim
Dimitropoulos's bounded-memory lockless-ring patch at commit
`f2185f602cae4ec01e2aaf8c199a5a52ec52101e`.

`udmesg` is distributed under the GNU General Public License, version 2 or (at
your option) any later version. See [LICENSE](LICENSE).
