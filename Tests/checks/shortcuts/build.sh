#!/bin/bash
# usage: build.sh WT OUT
WT=$1; OUT=$2; T=$(mktemp -d)
cp "$WT"/Sources/StreamProtocol/*.swift "$T"/
sed '/^import StreamProtocol$/d' "$WT/iOSClient/KeyChords.swift" > "$T/KeyChords.swift"
sed '/^import StreamProtocol$/d' "$WT/iOSClient/TextComposition.swift" > "$T/TextComposition.swift"
sed '/^import StreamProtocol$/d' "$WT/iOSClient/CustomShortcuts.swift" > "$T/CustomShortcuts.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O -package-name sill "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" || true
rm -rf "$T"
