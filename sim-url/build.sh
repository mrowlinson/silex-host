#!/bin/sh
# Build the pngvar binary (Swift, Foundation+ImageIO/CoreGraphics only).
set -e
cd "$(dirname "$0")"
swiftc -O -o pngvar pngvar.swift
echo "built ./pngvar"
