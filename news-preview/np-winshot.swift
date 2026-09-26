// np-winshot.swift — list windows by owner substring; capture one by ID to PNG.
// Usage: np-winshot list <owner-substring> | np-winshot shot <winid> <out.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func windowList() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: list <owner> | shot <winid> <out>"); exit(2) }

if args[1] == "list" {
    let sub = args.count > 2 ? args[2] : ""
    for w in windowList() {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        if sub.isEmpty || owner.localizedCaseInsensitiveContains(sub) {
            let wid = w[kCGWindowNumber as String] ?? 0
            let name = w[kCGWindowName as String] as? String ?? ""
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let layer = w[kCGWindowLayer as String] ?? 0
            print("\(wid)\t\(owner)\tL\(layer)\t\(name.prefix(50))\t\(b)")
        }
    }
} else if args[1] == "list-all" {
    for w in windowList() {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let wid = w[kCGWindowNumber as String] ?? 0
        print("\(wid)\t\(owner)")
    }
} else if args[1] == "shot" {
    // Capture via `screencapture -l<wid>` (CGWindowListCreateImage is
    // unavailable in this SDK; ScreenCaptureKit overkill for stills).
    guard args.count >= 4 else { print("usage: shot <winid> <out>"); exit(2) }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    proc.arguments = ["-l\(args[2])", "-x", "-o", args[3]]
    try proc.run()
    proc.waitUntilExit()
    if proc.terminationStatus != 0 { fputs("screencapture failed\n", stderr); exit(1) }
    print("wrote \(args[3])")
} else { print("unknown cmd"); exit(2) }
