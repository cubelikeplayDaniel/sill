#!/bin/bash
# Pen (Sources/StreamProtocol/Pen.swift) on its own: the wire shape of kind 45, what the host
# accepts of a batch, tilt and place mapping, the tablet area's aspect fit, and the pen state machine.
#   Tests/checks/pen/run.sh
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -O Sources/StreamProtocol/Pen.swift "$here/main.swift" -o "$out/check"
"$out/check"
