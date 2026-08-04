#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: build-deb.sh VERSION ARCH BINARY OUTPUT" >&2
    exit 2
fi

version=$1
architecture=$2
binary=$3
output=$4

if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+~.-][0-9A-Za-z.+:~-]+)?$'; then
    echo "invalid Debian package version: $version" >&2
    exit 2
fi

case "$architecture" in
    amd64|arm64) ;;
    *)
        echo "unsupported Debian architecture: $architecture" >&2
        exit 2
        ;;
esac

if [ ! -f "$binary" ]; then
    echo "binary not found: $binary" >&2
    exit 1
fi

command -v dpkg-deb >/dev/null 2>&1 || {
    echo "dpkg-deb is required" >&2
    exit 1
}

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname -- "$script_dir")
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/udmesg-deb.XXXXXX")
trap 'rm -rf "$package_dir"' EXIT HUP INT TERM

root="$package_dir/root"
mkdir -p "$root/DEBIAN" "$root/usr/bin" "$root/usr/share/doc/udmesg" "$(dirname -- "$output")"
install -m 0755 "$binary" "$root/usr/bin/udmesg"
install -m 0644 "$project_dir/packaging/debian/copyright" "$root/usr/share/doc/udmesg/copyright"

installed_size=$(du -sk "$root/usr" | awk '{print $1}')
cat > "$root/DEBIAN/control" <<EOF
Package: udmesg
Version: $version
Section: admin
Priority: optional
Architecture: $architecture
Maintainer: Serapheim Dimitropoulos <sdimitropoulos@coreweave.com>
Installed-Size: $installed_size
Description: bounded-memory Linux kernel log extractor
 Extracts the modern lockless printk ring from raw ELF /proc/kcore,
 /proc/vmcore, or saved raw vmcore files without allocating memory based
 on the total ring size.
EOF

chmod 0755 "$root/DEBIAN"
chmod 0644 "$root/DEBIAN/control"
dpkg-deb --root-owner-group --build "$root" "$output"
