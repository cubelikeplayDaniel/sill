#!/bin/bash
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
