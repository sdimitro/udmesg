#!/bin/sh
set -eu

version=${1:-0.1.0-dev}
case "$(uname -m)" in
    x86_64)
        zig_arch=x86_64
        asset_arch=amd64
        zig_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
        ;;
    aarch64)
        zig_arch=aarch64
        asset_arch=arm64
        zig_sha=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
        ;;
    *)
        echo 'udmesg-kdump supports amd64 and arm64 build hosts' >&2
        exit 1
        ;;
esac

apk add --no-cache autoconf automake build-base ca-certificates curl libtool linux-headers \
    lzo-dev pkgconf snappy-dev snappy-static xz zlib-dev zlib-static \
    zstd-dev zstd-static

work=/tmp/udmesg-kdump-build
prefix=$work/prefix
mkdir -p "$work" "$prefix/include/libkdumpfile" "$prefix/lib"

curl -fsSL https://codeberg.org/ptesarik/libkdumpfile/archive/v0.5.6.tar.gz \
    -o "$work/libkdumpfile.tar.gz"
echo "a4e9a247b8e2023278cb3951ee60542519a3f06b6a5fc7374b8f6c6e2547d121  $work/libkdumpfile.tar.gz" | sha256sum -c -
tar -xzf "$work/libkdumpfile.tar.gz" -C "$work"
(
    cd "$work/libkdumpfile"
    autoreconf -fi
    ./configure --disable-kdumpid --disable-shared --enable-static --without-pthread --with-zlib=yes \
        --with-lzo2=yes --with-snappy=yes --with-libzstd=yes
    make -j2
)
cp "$work/libkdumpfile/src/kdumpfile/.libs/libkdumpfile.a" "$prefix/lib/"
cp "$work/libkdumpfile/src/addrxlat/.libs/libaddrxlat.a" "$prefix/lib/"
cp "$work/libkdumpfile/include/libkdumpfile/"*.h "$prefix/include/libkdumpfile/"
cp /usr/lib/libzstd.a /usr/lib/libsnappy.a /usr/lib/liblzo2.a /usr/lib/libz.a \
    /usr/lib/libstdc++.a "$prefix/lib/"
cp "$(gcc -print-file-name=libgcc_eh.a)" "$prefix/lib/"

zig_archive="zig-$zig_arch-linux-0.16.0.tar.xz"
curl -fsSL "https://ziglang.org/download/0.16.0/$zig_archive" -o "$work/$zig_archive"
echo "$zig_sha  $work/$zig_archive" | sha256sum -c -
tar -xJf "$work/$zig_archive" -C "$work"
ZIG_GLOBAL_CACHE_DIR="$work/zig-cache" \
    "$work/zig-$zig_arch-linux-0.16.0/zig" build kdump-release \
    -Dtarget="$zig_arch-linux-musl" \
    -Dkdump-prefix="$prefix" \
    -Dversion="$version"

binary="zig-out/bin/udmesg-kdump-linux-$asset_arch"
test -x "$binary"
test "$("$binary" --version)" = "udmesg-kdump $version"
