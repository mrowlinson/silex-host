#!/bin/sh
# Build the gt-scale-capture binary (Swift, Foundation+ImageIO/CoreGraphics only).
set -e
cd "$(dirname "$0")"
swiftc -O -o gt-scale-capture gt-scale-capture.swift
echo "built ./gt-scale-capture"
