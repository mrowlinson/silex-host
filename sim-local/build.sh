#!/bin/sh
# Build the discriminate binary (Swift, Foundation+ImageIO/CoreGraphics only).
set -e
cd "$(dirname "$0")"
swiftc -O -o discriminate discriminate.swift
echo "built ./discriminate"
