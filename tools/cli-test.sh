#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

udmesg=$1
fixture_tool=$2
version=$3
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/udmesg-cli-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

"$fixture_tool" "$test_dir/vmcore"
printf '%s\n' \
    '[    1.234567] hello' \
    '[    2.000000] ' \
    '[   12.034567] b\x01' \
    '' > "$test_dir/expected"

"$udmesg" "$test_dir/vmcore" > "$test_dir/stdout"
cmp "$test_dir/expected" "$test_dir/stdout"

"$udmesg" -o "$test_dir/output" "$test_dir/vmcore"
cmp "$test_dir/expected" "$test_dir/output"
"$udmesg" -o - "$test_dir/vmcore" > "$test_dir/dash-output"
cmp "$test_dir/expected" "$test_dir/dash-output"

"$udmesg" --help | grep -q '^Usage: udmesg'
test "$("$udmesg" --version)" = "udmesg $version"

if "$udmesg" --unknown > /dev/null 2> "$test_dir/bad-arguments"; then
    echo "bad arguments unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
test -s "$test_dir/bad-arguments"

if "$udmesg" -o "$test_dir" "$test_dir/vmcore" > /dev/null 2> "$test_dir/output-error"; then
    echo "opening a directory as output unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
test -s "$test_dir/output-error"

before=$(cksum "$test_dir/vmcore")
if "$udmesg" -o "$test_dir/vmcore" "$test_dir/vmcore" > /dev/null 2> "$test_dir/alias-error"; then
    echo "input/output alias unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
test "$before" = "$(cksum "$test_dir/vmcore")"
test -s "$test_dir/alias-error"

"$fixture_tool" --partial-failure "$test_dir/broken-vmcore"
if "$udmesg" -o "$test_dir/partial" "$test_dir/broken-vmcore" 2> "$test_dir/partial-error"; then
    echo "malformed record unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
printf '%s\n' \
    '[    1.234567] hello' \
    '[    2.000000] ' > "$test_dir/partial-expected"
cmp "$test_dir/partial-expected" "$test_dir/partial"
test -s "$test_dir/partial-error"
