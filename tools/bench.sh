#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

udmesg=$1
fixture_tool=$2
bench_dir=$(mktemp -d "${TMPDIR:-/tmp}/udmesg-bench.XXXXXX")
trap 'rm -rf "$bench_dir"' EXIT HUP INT TERM

"$fixture_tool" --benchmark "$bench_dir/vmcore"

binary_bytes=$(wc -c < "$udmesg" | tr -d ' ')
time_output="$bench_dir/time.txt"
"$udmesg" "$bench_dir/vmcore" > /dev/null
if [ "$(uname -s)" = Darwin ]; then
    (/usr/bin/time -l "$udmesg" "$bench_dir/vmcore" > /dev/null) 2> "$time_output" || true
    rss=$(awk '/maximum resident set size/ { print $1 }' "$time_output")
    elapsed=$(awk '/ real / { print $1 }' "$time_output")
else
    (/usr/bin/time -v "$udmesg" "$bench_dir/vmcore" > /dev/null) 2> "$time_output" || true
    rss_kib=$(awk -F: '/Maximum resident set size/ { gsub(/^[[:space:]]+/, "", $2); print $2 }' "$time_output")
    rss=$(( ${rss_kib:-0} * 1024))
    elapsed=$(awk -F: '/Elapsed.*wall clock/ { sub(/^[^:]*: /, ""); print }' "$time_output")
fi
rss=${rss:-unavailable}
elapsed=${elapsed:-unavailable}

echo "binary_bytes=$binary_bytes"
echo "fixture_apparent_bytes=$(wc -c < "$bench_dir/vmcore" | tr -d ' ')"
echo "text_ring_bytes=67108864"
echo "record_count=100000"
echo "peak_rss_bytes=$rss"
echo "elapsed=$elapsed"
