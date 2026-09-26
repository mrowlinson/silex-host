#!/bin/sh
# build.sh — compile the mac-news Swift tools (no dependencies beyond Xcode CLT).
# Usage: ./build.sh   (run from this directory)
set -e
cd "$(dirname "$0")"
swiftc -O winlist.swift -o winlist
swiftc -O mac-news-scale.swift -o mac-news-scale
swiftc -O gt-scale-capture.swift -o gt-scale-capture
echo "built: winlist mac-news-scale gt-scale-capture"
