// news-capture — Capture article content area from News.app
//
// Uses macOS Accessibility API to find the article scroll area,
// scrolls programmatically, captures each viewport with CGWindowListCreateImage,
// and stitches into one seamless tall image.

import Foundation
import ApplicationServices
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import Accelerate

// MARK: - Errors

enum CaptureError: Error, LocalizedError {
    case newsAppNotRunning
    case noAccessibilityPermission
    case noScreenRecordingPermission
    case articleScrollAreaNotFound
    case scrollBarNotFound  // kept for future use
    case captureRegionFailed
    case stitchingFailed
    case cannotWriteOutput(String)
    case noFramesCaptured
    case scrollDidNotEngage

    var errorDescription: String? {
        switch self {
        case .newsAppNotRunning: "News.app is not running"
        case .noAccessibilityPermission:
            "Accessibility permission required. Grant access in System Settings > Privacy & Security > Accessibility"
        case .noScreenRecordingPermission:
            "Screen Recording permission required. Grant access in System Settings > Privacy & Security > Screen Recording"
        case .articleScrollAreaNotFound: "Could not find article scroll area in News.app"
        case .scrollBarNotFound: "Could not find vertical scroll bar in article area"
        case .captureRegionFailed: "Failed to capture screen region"
        case .stitchingFailed: "Failed to stitch captured frames"
        case .cannotWriteOutput(let path): "Cannot write output to \(path)"
        case .noFramesCaptured: "No frames were captured"
        case .scrollDidNotEngage: "Scroll never engaged — only one viewport captured; article did not scroll"
        }
    }
}

// MARK: - Config

struct CaptureConfig {
    let outputPath: String
    let settleMs: Int
    let overlapPt: Int
    let scrollToTop: Bool
    let verbose: Bool
}

// MARK: - CLI Argument Parsing

func printUsage() {
    let usage = """
    news-capture — Capture article content from News.app

    Captures ONLY the article content area (no toolbar, sidebar, or chrome)
    by finding the article scroll area via Accessibility API.

    USAGE:
      news-capture -o <output.png> [options]

    OPTIONS:
      -o, --output <path>    Output PNG file path (required)
      --settle <ms>          Settle time after scroll in ms (default: 300)
      --overlap <px>         Overlap between captures in points (default: 100)
      --no-scroll-to-top     Don't scroll to top before capturing
      -v, --verbose          Print progress to stderr
      -h, --help             Show this help

    EXAMPLES:
      news-capture -o article.png
      news-capture -o article.png --verbose --settle 500

    PERMISSIONS:
      Requires Accessibility and Screen Recording permissions.
    """
    fputs(usage + "\n", stderr)
}

func parseArgs() -> CaptureConfig {
    let args = CommandLine.arguments
    var outputPath = ""
    var settleMs = 300
    var overlapPt = 100
    var scrollToTop = true
    var verbose = false

    var i = 1
    while i < args.count {
        switch args[i] {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "-o", "--output":
            i += 1; guard i < args.count else { break }
            outputPath = args[i]
        case "--settle":
            i += 1; guard i < args.count, let ms = Int(args[i]) else { break }
            settleMs = ms
        case "--overlap":
            i += 1; guard i < args.count, let px = Int(args[i]) else { break }
            overlapPt = px
        case "--no-scroll-to-top":
            scrollToTop = false
        case "-v", "--verbose":
            verbose = true
        default:
            break
        }
        i += 1
    }

    return CaptureConfig(
        outputPath: outputPath,
        settleMs: settleMs,
        overlapPt: overlapPt,
        scrollToTop: scrollToTop,
        verbose: verbose
    )
}

// MARK: - Permission Checks

func checkAccessibilityPermission() throws {
    guard AXIsProcessTrusted() else {
        throw CaptureError.noAccessibilityPermission
    }
}

func checkScreenRecordingPermission() async throws {
    // Attempt to enumerate shareable content — throws if permission not granted
    do {
        _ = try await SCShareableContent.current
    } catch {
        throw CaptureError.noScreenRecordingPermission
    }
}

// MARK: - News.app Discovery

func findNewsPID() -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first(where: { $0.bundleIdentifier == "com.apple.news" })?
        .processIdentifier
}

/// Run `/usr/bin/osascript -e <script>` with a HARD timeout, returning stdout (or nil on
/// timeout/failure). CRITICAL: a bare `Process.waitUntilExit()` on osascript can BLOCK
/// FOREVER — `tell application "News" to activate` / System Events queries can stall
/// indefinitely on an Automation (TCC) prompt this .prohibited agent can't answer. That
/// deadlock (confirmed via sampling: waitUntilExit inside osascriptActivateNews) is what
/// hung the whole capture before any scroll. We terminate the child if it overruns.
@discardableResult
func runOsascriptBounded(_ script: String, timeout: TimeInterval = 1.5) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do { try proc.run() } catch { return nil }

    let deadline = Date().addingTimeInterval(timeout)
    while proc.isRunning && Date() < deadline {
        usleep(50_000)  // 50ms poll — never blocks past the deadline
    }
    if proc.isRunning {
        proc.terminate()                // SIGTERM the stalled osascript
        usleep(100_000)
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        return nil                      // fail OPEN — never hang the capture
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Fire AppleScript to foreground News.app (bounded so it can never hang). On macOS 14+
/// the deprecated `activate(options:)` is a no-op and the modern no-arg `activate()` can
/// silently fail to steal focus from a .prohibited agent; `tell application "News" to
/// activate` helps on macOS 26 — but only as a bounded belt-and-suspenders.
func osascriptActivateNews() {
    _ = runOsascriptBounded("tell application \"News\" to activate", timeout: 1.5)
}

/// True if News.app is currently the frontmost application.
///
/// `NSWorkspace.shared.frontmostApplication` is the FAST, non-blocking primary check.
/// It can occasionally read stale at process startup, so we cross-check via System Events
/// — but ONLY through the BOUNDED osascript helper so a stalled query can never hang the
/// capture. If the bounded query times out we simply trust NSWorkspace (fail open).
func newsIsFrontmost() -> Bool {
    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.news" {
        return true
    }
    let name = runOsascriptBounded(
        "tell application \"System Events\" to get name of first application process whose frontmost is true",
        timeout: 1.0)
    return name == "News"
}

/// Force News.app frontmost and CONFIRM it via polling. Returns true only once
/// `NSWorkspace.frontmostApplication == com.apple.news`.
///
/// IMPORTANT: the async NSWorkspace.openApplication overload LEAKS its continuation
/// (never resumes) when the target app is already frontmost / activation is suppressed
/// for a .prohibited agent app — so we never call it. News is already running; we only
/// force focus. We use the MODERN no-arg `activate()` (the deprecated `options:` variant
/// is a no-op on macOS 14+), plus an AppleScript belt-and-suspenders, then poll.
@discardableResult
func activateNewsApp(pid: pid_t) async -> Bool {
    if newsIsFrontmost() { return true }

    let newsApp = NSRunningApplication(processIdentifier: pid)
        ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.news").first

    // Poll up to ~10 tries with ~200ms sleeps, re-issuing activation each round.
    for attempt in 0..<10 {
        newsApp?.activate()          // modern no-arg form (works on macOS 26)
        if attempt % 2 == 0 {
            osascriptActivateNews()  // belt-and-suspenders foregrounding via AppleScript
        }
        try? await Task.sleep(for: .milliseconds(200))
        if newsIsFrontmost() { return true }
    }
    return newsIsFrontmost()
}

/// Re-assert News.app frontmost before a scroll action. Returns true if News.app is
/// frontmost afterward. This directly fixes "Page Down / scroll went to the wrong app
/// because News wasn't focused". `activateNewsApp` already polls internally.
@discardableResult
func ensureNewsFrontmost(pid: pid_t, attempts: Int = 3) async -> Bool {
    if newsIsFrontmost() { return true }
    for _ in 0..<attempts {
        if await activateNewsApp(pid: pid) { return true }
    }
    return newsIsFrontmost()
}

// MARK: - Accessibility Utilities

func axGetAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value
}

func axGetStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let value = axGetAttribute(element, attribute) else { return nil }
    return value as? String
}

func axGetChildren(_ element: AXUIElement) -> [AXUIElement]? {
    guard let value = axGetAttribute(element, kAXChildrenAttribute as String) else { return nil }
    return value as? [AXUIElement]
}

func axGetRole(_ element: AXUIElement) -> String? {
    axGetStringAttribute(element, kAXRoleAttribute as String)
}

func axGetPosition(_ element: AXUIElement) -> CGPoint? {
    guard let value = axGetAttribute(element, kAXPositionAttribute as String) else { return nil }
    var point = CGPoint.zero
    AXValueGetValue(value as! AXValue, .cgPoint, &point)
    return point
}

func axGetSize(_ element: AXUIElement) -> CGSize? {
    guard let value = axGetAttribute(element, kAXSizeAttribute as String) else { return nil }
    var size = CGSize.zero
    AXValueGetValue(value as! AXValue, .cgSize, &size)
    return size
}

func axGetMainWindow(_ app: AXUIElement) -> AXUIElement? {
    // WKWebView apps lazily materialize their AX hierarchy when brought frontmost; the
    // FIRST few window queries against a freshly-frontmost News.app frequently return
    // cannotComplete/nil while WebKit bridges the WebContent AX tree. Retry a few times.
    for attempt in 0..<8 {
        if let focused = axGetAttribute(app, kAXFocusedWindowAttribute as String),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        if let windowRef = axGetAttribute(app, kAXWindowsAttribute as String),
           let windows = windowRef as? [AXUIElement], !windows.isEmpty {
            return windows.first
        }
        if attempt < 7 { usleep(250_000) }  // 250ms between attempts
    }
    return nil
}

func axGetScrollBarValue(_ scrollBar: AXUIElement) -> Double {
    guard let val = axGetAttribute(scrollBar, kAXValueAttribute as String) else { return 0 }
    return (val as? NSNumber)?.doubleValue ?? 0
}

func axFindVerticalScrollBar(_ scrollArea: AXUIElement) -> AXUIElement? {
    guard let children = axGetChildren(scrollArea) else { return nil }
    for child in children {
        if axGetRole(child) == "AXScrollBar" {
            if let orientation = axGetStringAttribute(child, "AXOrientation"),
               orientation == "AXVerticalOrientation" {
                return child
            }
        }
    }
    // Fallback: any scroll bar
    return children.first { axGetRole($0) == "AXScrollBar" }
}

// MARK: - Find Article Scroll Area (key new logic)

/// Shared visited-node budget for the scroll-area tree walk. On macOS 26 a
/// FULLY-MATERIALIZED (frontmost + loaded) News.app article exposes a huge
/// WKWebView Accessibility tree; a naive unbounded recursive walk calling the
/// synchronous AXUIElementCopyAttributeValue at every node HANGS. The DECISIVE hang
/// preventer is (crucially) NOT descending into an AXScrollArea's own content subtree —
/// the article's massive AXWebArea lives below the scroll area, and walking it is what
/// materialized+choked. The node budget + depth cap are only belt-and-suspenders, so they
/// must stay GENEROUS: the article AXScrollArea in News.app's SwiftUI/WebKit tree can be
/// nested >8 deep, and a too-shallow cap (was 8) found ZERO scroll areas. Restored to the
/// historically-working depth 15 with a large budget.
private let axWalkNodeBudget = 20000

/// Recursively collect all AXScrollArea elements (bounded).
func axCollectScrollAreas(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 15,
                          visited: inout Int) -> [AXUIElement] {
    guard depth < maxDepth, visited < axWalkNodeBudget else { return [] }
    visited += 1
    var results: [AXUIElement] = []

    if axGetRole(element) == "AXScrollArea" {
        // Found a scroll area. Record it but DO NOT recurse into its subtree — the
        // article's massive AXWebArea lives below here and walking it is the hang.
        results.append(element)
        return results
    }

    if let children = axGetChildren(element) {
        for child in children {
            if visited >= axWalkNodeBudget { break }
            results.append(contentsOf: axCollectScrollAreas(child, depth: depth + 1,
                                                            maxDepth: maxDepth, visited: &visited))
        }
    }
    return results
}

/// Convenience overload that owns the visited counter.
func axCollectScrollAreas(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 15) -> [AXUIElement] {
    var visited = 0
    return axCollectScrollAreas(element, depth: depth, maxDepth: maxDepth, visited: &visited)
}

/// Best-effort: get the full scrollable content height from the scroll area's
/// AXWebArea (or a tall AXGroup) child. Returns nil if not cheaply obtainable.
/// Used by the stitch-time one-viewport backstop (#3).
func axGetWebAreaContentHeight(_ scrollArea: AXUIElement) -> CGFloat? {
    guard let children = axGetChildren(scrollArea) else { return nil }
    var best: CGFloat? = nil
    func consider(_ el: AXUIElement) {
        let role = axGetRole(el) ?? ""
        if role == "AXWebArea" || role == "AXGroup" {
            if let sz = axGetSize(el) {
                if best == nil || sz.height > best! { best = sz.height }
            }
        }
    }
    for child in children {
        consider(child)
        if let grandchildren = axGetChildren(child) {
            for gc in grandchildren { consider(gc) }
        }
    }
    return best
}

/// Check if an AXScrollArea contains an AXWebArea child (article content is web).
func axContainsWebArea(_ scrollArea: AXUIElement) -> Bool {
    guard let children = axGetChildren(scrollArea) else { return false }
    for child in children {
        if axGetRole(child) == "AXWebArea" { return true }
        // Also check one level deeper
        if let grandchildren = axGetChildren(child) {
            for gc in grandchildren {
                if axGetRole(gc) == "AXWebArea" { return true }
            }
        }
    }
    return false
}

/// Find the article scroll area: widest AXScrollArea that contains an AXWebArea.
func findArticleScrollArea(pid: pid_t, verbose: Bool) throws -> AXUIElement {
    let app = AXUIElementCreateApplication(pid)
    // Timeout tuning (macOS 26 / WKWebView): a 2.0s timeout on the APP element was too
    // aggressive — a freshly-frontmost News.app blocks its main thread doing WebKit AX
    // materialization for >2s, so the top-level window query returned cannotComplete/nil
    // and we failed with "no scroll area". Give the app element a GENEROUS 10s so window
    // queries survive that bottleneck; the aggressive hang-guard is applied PER-ELEMENT
    // (below, on the window before the deep walk) instead. AXUIElementSetMessagingTimeout
    // applies to the specific AXUIElementRef passed.
    AXUIElementSetMessagingTimeout(app, 10.0)

    guard let window = axGetMainWindow(app) else {
        throw CaptureError.articleScrollAreaNotFound
    }

    // Aggressive per-element hang-guard for the deep walk into the giant WKWebView subtree.
    AXUIElementSetMessagingTimeout(window, 2.0)
    let scrollAreas = axCollectScrollAreas(window)

    if verbose {
        fputs("news-capture: Found \(scrollAreas.count) AXScrollArea(s)\n", stderr)
        for (i, sa) in scrollAreas.enumerated() {
            let size = axGetSize(sa) ?? .zero
            let hasWeb = axContainsWebArea(sa)
            fputs("  [\(i)] \(Int(size.width))x\(Int(size.height)) hasWebArea=\(hasWeb)\n", stderr)
        }
    }

    // Filter: width > 400 AND contains AXWebArea
    var candidates = scrollAreas.filter { sa in
        guard let size = axGetSize(sa), size.width > 400 else { return false }
        return axContainsWebArea(sa)
    }

    // If no WebArea candidates, fall back to widest scroll area > 400pt
    if candidates.isEmpty {
        candidates = scrollAreas.filter { sa in
            guard let size = axGetSize(sa) else { return false }
            return size.width > 400
        }
    }

    // Pick widest
    guard let best = candidates.max(by: { (axGetSize($0)?.width ?? 0) < (axGetSize($1)?.width ?? 0) }) else {
        throw CaptureError.articleScrollAreaNotFound
    }

    if verbose {
        fputs("news-capture: Selected scroll area children:\n", stderr)
        dumpAXTree(best, depth: 0, maxDepth: 4)
    }

    return best
}

/// Debug: dump AX tree to stderr.
func dumpAXTree(_ element: AXUIElement, depth: Int, maxDepth: Int) {
    guard depth < maxDepth else { return }
    let indent = String(repeating: "  ", count: depth)
    let role = axGetRole(element) ?? "?"
    let size = axGetSize(element)
    let sizeStr = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
    fputs("\(indent)\(role) (\(sizeStr))\n", stderr)

    if let children = axGetChildren(element) {
        for child in children {
            dumpAXTree(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

// MARK: - Scroll Area Info

struct ScrollAreaInfo {
    let position: CGPoint        // Screen coords of the full scroll area
    let size: CGSize             // Full scroll area size (may include sidebar/toolbar)
    let articleRect: CGRect      // Screen coords of JUST the article content area
    let contentHeight: CGFloat?  // Full scrollable content height if determinable
    let contentColumnRect: CGRect? // Screen coords of the article content column (text/images only)
}

/// Derive the article-only capture rectangle by finding the sidebar and toolbar
/// in the AX tree and excluding them from the scroll area bounds.
func getScrollAreaInfo(_ scrollArea: AXUIElement, pid: pid_t, verbose: Bool) -> ScrollAreaInfo {
    let position = axGetPosition(scrollArea) ?? .zero
    let size = axGetSize(scrollArea) ?? CGSize(width: 800, height: 600)
    let windowRight = position.x + size.width
    let windowBottom = position.y + size.height

    // Find sidebar and toolbar by walking the AX tree
    let app = AXUIElementCreateApplication(pid)
    // Generous timeout on the app element (matches findArticleScrollArea) so top-level
    // window/toolbar/sidebar queries survive WebKit AX materialization; findSidebar's
    // recursion is depth-capped (<6) and stays in chrome, not the deep web subtree.
    AXUIElementSetMessagingTimeout(app, 10.0)
    var sidebarRight: CGFloat = position.x    // default: no sidebar
    var toolbarBottom: CGFloat = position.y   // default: no toolbar

    if let window = axGetMainWindow(app), let windowChildren = axGetChildren(window) {
        for child in windowChildren {
            let role = axGetRole(child) ?? ""

            // Toolbar: full-width bar at the top of the window
            if role == "AXToolbar" {
                if let tbPos = axGetPosition(child), let tbSize = axGetSize(child) {
                    let tbBottom = tbPos.y + tbSize.height
                    if tbBottom > toolbarBottom {
                        toolbarBottom = tbBottom
                    }
                    if verbose {
                        fputs("news-capture: Found toolbar: \(Int(tbSize.width))x\(Int(tbSize.height)) @ (\(Int(tbPos.x)),\(Int(tbPos.y))) bottom=\(Int(tbBottom))\n", stderr)
                    }
                }
            }
        }

        // Find sidebar: look for narrow AXGroup on the left side containing navigation items
        // Walk into the iOSContentGroup → AXGroup chain
        func findSidebar(in element: AXUIElement, depth: Int = 0) {
            guard depth < 6 else { return }
            guard let children = axGetChildren(element) else { return }
            for child in children {
                let role = axGetRole(child) ?? ""
                if role == "AXGroup" {
                    if let cSize = axGetSize(child), let cPos = axGetPosition(child) {
                        // Sidebar heuristic: narrow group (< 300px), tall, on the left side
                        if cSize.width < 300 && cSize.height > 400 && cPos.x < position.x + 50 {
                            let right = cPos.x + cSize.width
                            if right > sidebarRight {
                                sidebarRight = right
                                if verbose {
                                    fputs("news-capture: Found sidebar: \(Int(cSize.width))x\(Int(cSize.height)) @ (\(Int(cPos.x)),\(Int(cPos.y))) right=\(Int(right))\n", stderr)
                                }
                            }
                        }
                    }
                    findSidebar(in: child, depth: depth + 1)
                }
            }
        }
        for child in windowChildren {
            findSidebar(in: child)
        }
    }

    // Article content rectangle: exclude sidebar (left) and toolbar (top)
    let articleX = sidebarRight
    let articleY = toolbarBottom
    let articleW = windowRight - articleX
    let articleH = windowBottom - articleY
    let articleRect = CGRect(x: articleX, y: articleY, width: articleW, height: articleH)

    // Try to get full content height from tall child elements
    // Also detect the content column bounds from AX element positions
    var contentHeight: CGFloat? = nil
    var contentLeft: CGFloat = .greatestFiniteMagnitude
    var contentRight: CGFloat = 0

    if let children = axGetChildren(scrollArea) {
        for child in children {
            let role = axGetRole(child) ?? ""
            if let childSize = axGetSize(child), let childPos = axGetPosition(child) {
                if (role == "AXWebArea" || role == "AXGroup") && childSize.height > size.height {
                    contentHeight = childSize.height
                }
                // Track content element bounds (text, images, headings)
                // Skip very wide elements (they're containers, not content)
                if childSize.width < size.width * 0.8 && childSize.width > 50 {
                    contentLeft = min(contentLeft, childPos.x)
                    contentRight = max(contentRight, childPos.x + childSize.width)
                }
            }
        }
    }

    var contentColumnRect: CGRect? = nil
    if contentLeft < contentRight {
        // Add small padding around content bounds
        let padded = CGRect(
            x: contentLeft - 20,
            y: articleY,
            width: (contentRight - contentLeft) + 40,
            height: articleH
        )
        contentColumnRect = padded
        if verbose {
            fputs("news-capture: Content column: \(Int(padded.width))pt wide @ x=\(Int(padded.origin.x))\n", stderr)
        }
    }

    if verbose {
        fputs("news-capture: Scroll area: \(Int(size.width))x\(Int(size.height)) @ (\(Int(position.x)),\(Int(position.y)))\n", stderr)
        fputs("news-capture: Article rect: \(Int(articleW))x\(Int(articleH)) @ (\(Int(articleX)),\(Int(articleY)))\n", stderr)
        if let ch = contentHeight {
            fputs("news-capture: Content height: \(Int(ch))\n", stderr)
        }
    }

    return ScrollAreaInfo(position: position, size: size, articleRect: articleRect, contentHeight: contentHeight, contentColumnRect: contentColumnRect)
}

// MARK: - Key Event Helper

func sendKeyToFrontApp(keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
        down.flags = flags
        down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
        up.flags = flags
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - Region Capture via ScreenCaptureKit

/// Captures a specific screen region using ScreenCaptureKit.
/// Position/size are in screen coordinates (points, top-left origin).
func captureRegion(position: CGPoint, size: CGSize, display: SCDisplay) async throws -> CGImage {
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(origin: position, size: size)
    config.width = Int(size.width) * 2   // Retina 2x
    config.height = Int(size.height) * 2
    config.showsCursor = false
    config.captureResolution = .best

    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    return image
}

/// Find the display that contains the given screen point.
func findDisplay(containing point: CGPoint) async throws -> SCDisplay {
    let content = try await SCShareableContent.current
    // Find the display whose frame contains the point
    if let display = content.displays.first(where: { $0.frame.contains(point) }) {
        return display
    }
    // Fallback to primary (first) display
    guard let primary = content.displays.first else {
        throw CaptureError.captureRegionFailed
    }
    return primary
}

// MARK: - Scroll + Capture Loop

func captureArticle(
    scrollArea: AXUIElement,
    info: ScrollAreaInfo,
    display: SCDisplay,
    pid: pid_t,
    config: CaptureConfig
) async throws -> [CGImage] {
    // Try scroll bar first, fall back to scroll wheel
    let scrollBar = axFindVerticalScrollBar(scrollArea)

    if let scrollBar = scrollBar {
        if config.verbose { fputs("news-capture: Using AX scroll bar approach\n", stderr) }
        return try await captureViaScrollBar(scrollArea: scrollArea, scrollBar: scrollBar, info: info, display: display, pid: pid, config: config)
    } else {
        if config.verbose { fputs("news-capture: No scroll bar found, using CGEvent scroll wheel\n", stderr) }
        return try await captureViaScrollWheel(scrollArea: scrollArea, info: info, display: display, pid: pid, config: config)
    }
}

// MARK: - Scroll Bar Capture

private func captureViaScrollBar(
    scrollArea: AXUIElement, scrollBar: AXUIElement,
    info: ScrollAreaInfo, display: SCDisplay, pid: pid_t, config: CaptureConfig
) async throws -> [CGImage] {
    if config.scrollToTop {
        AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: 0.0))
        try await Task.sleep(for: .milliseconds(config.settleMs + 200))
    }

    var captures: [CGImage] = []
    let steps = 120   // raised from 50 so genuinely tall (100k+ px) articles aren't truncated
    var lastScrollValue: Double = -1
    var staticCount = 0

    // --- Progress guard state (the core anti-2566 defense) ---
    // We refuse to honor ANY early break until the capture has demonstrably moved
    // beyond the first viewport: scroll bar value crossed a small floor, OR we have
    // several unique frames whose scroll delta is real.
    let progressFloor = 0.05
    var maxScrollSeen: Double = 0
    var noProgressRetries = 0
    let maxNoProgressRetries = 5

    // Has the article actually scrolled past viewport 1?
    func hasEngaged() -> Bool {
        return maxScrollSeen > progressFloor || captures.count >= 3
    }

    for step in 0...steps {
        // Re-assert frontmost/focus before EACH scroll action. If News.app cannot be
        // foregrounded, the scroll bar set would apply to a background app / nothing —
        // never emit a one-viewport stub in that case.
        if !(await ensureNewsFrontmost(pid: pid)) {
            if captures.count <= 1 { throw CaptureError.scrollDidNotEngage }
        }

        let position = Double(step) / Double(steps)
        AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: position))
        try await Task.sleep(for: .milliseconds(config.settleMs))

        // Capture ONLY the article content rectangle (excludes sidebar + toolbar)
        let frame: CGImage
        do { frame = try await captureRegion(position: info.articleRect.origin, size: info.articleRect.size, display: display) }
        catch { if config.verbose { fputs("news-capture: Warning: capture failed at step \(step)\n", stderr) }; continue }

        let isIdentical = captures.last.map { imagesAreIdentical($0, frame) } ?? false
        if !isIdentical { captures.append(frame) }

        let currentValue = axGetScrollBarValue(scrollBar)
        maxScrollSeen = max(maxScrollSeen, currentValue)
        if config.verbose {
            fputs("news-capture: Step \(step)/\(steps): scrollValue=\(String(format: "%.3f", currentValue)) maxSeen=\(String(format: "%.3f", maxScrollSeen)) frame=\(frame.width)x\(frame.height) unique=\(captures.count)\n", stderr)
        }

        // Determine whether the loop WANTS to terminate this step.
        let scrollBarStuck = (currentValue == lastScrollValue && step > 5)
        var wantsBreak = false
        if isIdentical {
            staticCount += 1
            if staticCount >= 2 { wantsBreak = true }
        } else {
            staticCount = 0
        }
        if currentValue >= 0.99 { wantsBreak = true }   // legitimate true-bottom (progress made)
        if scrollBarStuck { staticCount += 1; if staticCount >= 2 { wantsBreak = true } }
        lastScrollValue = currentValue

        if wantsBreak {
            // A break at >=0.99 with progress made is a legitimate true bottom.
            if currentValue >= 0.99 && hasEngaged() { break }
            // Otherwise, only honor the break if we've genuinely engaged past viewport 1.
            if hasEngaged() { break }

            // NOT engaged — this is the 2566 signature. Refuse; nudge harder.
            noProgressRetries += 1
            if config.verbose {
                fputs("news-capture: No scroll progress (retry \(noProgressRetries)/\(maxNoProgressRetries)) — re-asserting frontmost + stronger nudge\n", stderr)
            }
            if noProgressRetries > maxNoProgressRetries {
                throw CaptureError.scrollDidNotEngage
            }
            // Re-assert frontmost and force the scroll bar to a small positive value,
            // then continue the loop rather than accepting a one-viewport stub.
            await ensureNewsFrontmost(pid: pid)
            let nudgeValue = min(0.1 + Double(noProgressRetries) * 0.05, 0.9)
            AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: nudgeValue))
            try await Task.sleep(for: .milliseconds(config.settleMs + 200))
            staticCount = 0
            continue
        }
    }

    AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: 0.0))
    guard !captures.isEmpty else { throw CaptureError.noFramesCaptured }
    // Backstop: if we ended with a single viewport and never engaged, this is invalid GT.
    if captures.count == 1 && !hasEngaged() {
        throw CaptureError.scrollDidNotEngage
    }
    return captures
}

// MARK: - Scroll Wheel Capture

private func captureViaScrollWheel(
    scrollArea: AXUIElement,
    info: ScrollAreaInfo, display: SCDisplay, pid: pid_t, config: CaptureConfig
) async throws -> [CGImage] {
    // Ensure News.app is frontmost — Page Down must land on News.app, not a background app.
    // If we cannot foreground it, there is no point scrolling; fail with a distinct error.
    guard await activateNewsApp(pid: pid) else { throw CaptureError.scrollDidNotEngage }

    // Scroll to top using Cmd+Up (keyCode 126) — reliable in News.app on macOS 26
    if config.scrollToTop {
        await ensureNewsFrontmost(pid: pid)
        sendKeyToFrontApp(keyCode: 126, flags: .maskCommand)  // Cmd+Up = scroll to top
        try await Task.sleep(for: .milliseconds(500))
        sendKeyToFrontApp(keyCode: 126, flags: .maskCommand)  // twice to be sure
        try await Task.sleep(for: .milliseconds(800))
    }

    var captures: [CGImage] = []
    let maxSteps = 200   // raised from 80 so genuinely tall (100k+ px) articles aren't truncated
    var identicalCount = 0

    // --- Progress guard state (the core anti-2566 defense) ---
    // Without a scroll bar value here, "engagement" means: we have several UNIQUE,
    // non-identical frames whose measured scroll delta is real. We refuse any early
    // break (identical / low changeRatio) until at least this many unique frames exist.
    let minUniqueForEngagement = 3
    var maxChangeSeen: Double = 0
    var noProgressRetries = 0
    let maxNoProgressRetries = 5

    // Has the article actually scrolled past viewport 1?
    // Requires >=3 unique frames AND a nonzero observed scroll delta between frames.
    func hasEngaged() -> Bool {
        return captures.count >= minUniqueForEngagement && maxChangeSeen > 0
    }

    // Send a stronger scroll nudge: several Page Downs in a row after re-asserting focus.
    func strongerNudge() async {
        await ensureNewsFrontmost(pid: pid)
        for _ in 0..<3 {
            sendKeyToFrontApp(keyCode: 121)  // Page Down
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .milliseconds(config.settleMs))
    }

    for step in 0..<maxSteps {
        // Re-assert frontmost/focus before EACH scroll action so Page Down lands on News.app.
        // If News.app cannot be foregrounded, Page Down goes nowhere — never emit a stub.
        if !(await ensureNewsFrontmost(pid: pid)) {
            if captures.count <= 1 { throw CaptureError.scrollDidNotEngage }
        }

        // Capture ONLY the article content rectangle (excludes sidebar + toolbar)
        let frame: CGImage
        do { frame = try await captureRegion(position: info.articleRect.origin, size: info.articleRect.size, display: display) }
        catch { if config.verbose { fputs("news-capture: Warning: capture failed at step \(step)\n", stderr) }; continue }

        // Classify this frame vs the last kept frame, and decide if the loop WANTS to break.
        var wantsBreak = false
        if let lastFrame = captures.last {
            if imagesAreIdentical(lastFrame, frame) {
                identicalCount += 1
                if identicalCount >= 2 { wantsBreak = true }
            } else {
                let changeRatio = measureChangeRatio(lastFrame, frame)
                maxChangeSeen = max(maxChangeSeen, changeRatio)
                if changeRatio < 0.005 {
                    identicalCount += 1
                    captures.append(frame)
                    if identicalCount >= 3 { wantsBreak = true }
                } else {
                    identicalCount = 0
                    captures.append(frame)
                }
            }
        } else {
            captures.append(frame)
        }

        if config.verbose {
            fputs("news-capture: Step \(step + 1)/\(maxSteps): frame=\(frame.width)x\(frame.height) unique=\(captures.count) maxChange=\(String(format: "%.4f", maxChangeSeen))\n", stderr)
        }

        if wantsBreak {
            // Only honor the break if we've genuinely engaged past viewport 1.
            if hasEngaged() { break }

            // NOT engaged — this is the 2566 signature (nothing scrolled). Refuse; nudge harder.
            noProgressRetries += 1
            if config.verbose {
                fputs("news-capture: No scroll progress (retry \(noProgressRetries)/\(maxNoProgressRetries)) — re-asserting frontmost + stronger nudge\n", stderr)
            }
            if noProgressRetries > maxNoProgressRetries {
                throw CaptureError.scrollDidNotEngage
            }
            await strongerNudge()
            identicalCount = 0
            continue
        }

        // Scroll down using Page Down key — reliable across all window sizes
        sendKeyToFrontApp(keyCode: 121)  // Page Down
        try await Task.sleep(for: .milliseconds(config.settleMs))
    }

    // Scroll back to top
    sendKeyToFrontApp(keyCode: 126, flags: .maskCommand)  // Cmd+Up

    guard !captures.isEmpty else { throw CaptureError.noFramesCaptured }
    // Backstop: if we ended with a single viewport and never engaged, this is invalid GT.
    if captures.count == 1 && !hasEngaged() {
        throw CaptureError.scrollDidNotEngage
    }
    return captures
}

// MARK: - Pixel Buffer (ported from ImageUtils.swift)

struct PixelBuffer: Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let bytesPerRow: Int

    func rgba(at x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let offset = y * bytesPerRow + x * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }
}

func extractPixels(_ image: CGImage) -> PixelBuffer? {
    let w = image.width
    let h = image.height
    let bytesPerRow = w * 4
    var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)

    guard let context = CGContext(
        data: &pixels, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return PixelBuffer(pixels: pixels, width: w, height: h, bytesPerRow: bytesPerRow)
}

/// Convert a PixelBuffer to a flat grayscale Float array using vDSP BT.709 weights.
/// Fast path uses stride-4 vDSP_vfltu8 channel extraction — same pattern as ANFCompare.
private func toGrayscaleFloats(_ buf: PixelBuffer) -> [Float] {
    let n = buf.width * buf.height
    guard buf.bytesPerRow == buf.width * 4 else {
        var gray = [Float](repeating: 0, count: n)
        for y in 0..<buf.height {
            for x in 0..<buf.width {
                let (r, g, b, _) = buf.rgba(at: x, y)
                gray[y * buf.width + x] = Float(r) * 0.2126 + Float(g) * 0.7152 + Float(b) * 0.0722
            }
        }
        return gray
    }
    var rF = [Float](repeating: 0, count: n)
    var gF = [Float](repeating: 0, count: n)
    var bF = [Float](repeating: 0, count: n)
    var gray = [Float](repeating: 0, count: n)
    buf.pixels.withUnsafeBufferPointer { ptr in
        let base = ptr.baseAddress!
        vDSP_vfltu8(base,     4, &rF, 1, vDSP_Length(n))
        vDSP_vfltu8(base + 1, 4, &gF, 1, vDSP_Length(n))
        vDSP_vfltu8(base + 2, 4, &bF, 1, vDSP_Length(n))
    }
    var wR: Float = 0.2126, wG: Float = 0.7152, wB: Float = 0.0722
    vDSP_vsmul(rF, 1, &wR, &gray, 1, vDSP_Length(n))
    vDSP_vsma(gF, 1, &wG, gray, 1, &gray, 1, vDSP_Length(n))
    vDSP_vsma(bF, 1, &wB, gray, 1, &gray, 1, vDSP_Length(n))
    return gray
}

// MARK: - Frame Stitching (ported from NewsAppCapture.swift)

func imagesAreIdentical(_ a: CGImage, _ b: CGImage) -> Bool {
    guard a.width == b.width && a.height == b.height else { return false }
    guard let bufA = extractPixels(a), let bufB = extractPixels(b) else { return false }

    // Compare bottom 1/3 of image (where scroll changes are visible)
    // AND middle section, to detect even small scrolls
    let w = bufA.width
    let h = bufA.height
    let sampleStep = max(1, w / 30)
    var diffCount = 0
    let checkRegions = [h / 4, h / 2, h * 3 / 4]  // sample at 25%, 50%, 75% height

    for baseY in checkRegions {
        for row in 0..<min(20, h - baseY) {
            let y = baseY + row
            for x in stride(from: 0, to: w, by: sampleStep) {
                let (r1, g1, b1, _) = bufA.rgba(at: x, y)
                let (r2, g2, b2, _) = bufB.rgba(at: x, y)
                if abs(Int(r1)-Int(r2)) > 5 || abs(Int(g1)-Int(g2)) > 5 || abs(Int(b1)-Int(b2)) > 5 {
                    diffCount += 1
                }
            }
        }
    }

    // If more than 3% of sampled pixels differ, images are not identical
    let totalSampled = 3 * 20 * (w / sampleStep)
    return diffCount < totalSampled * 3 / 100
}

/// Measure what fraction of the image changed between two frames.
func measureChangeRatio(_ a: CGImage, _ b: CGImage) -> Double {
    guard a.width == b.width && a.height == b.height else { return 1.0 }
    guard let bufA = extractPixels(a), let bufB = extractPixels(b) else { return 1.0 }

    let w = bufA.width
    let h = bufA.height
    let sampleStep = max(1, w / 40)
    let rowStep = max(1, h / 50)
    var diffCount = 0
    var totalCount = 0

    for y in stride(from: 0, to: h, by: rowStep) {
        for x in stride(from: 0, to: w, by: sampleStep) {
            let (r1, g1, b1, _) = bufA.rgba(at: x, y)
            let (r2, g2, b2, _) = bufB.rgba(at: x, y)
            totalCount += 1
            if abs(Int(r1)-Int(r2)) > 10 || abs(Int(g1)-Int(g2)) > 10 || abs(Int(b1)-Int(b2)) > 10 {
                diffCount += 1
            }
        }
    }

    return totalCount > 0 ? Double(diffCount) / Double(totalCount) : 1.0
}

func detectOverlap(bottom: CGImage, top: CGImage, maxSearch: Int, stripHeight: Int) -> Int {
    guard let bufBottom = extractPixels(bottom),
          let bufTop = extractPixels(top) else { return 0 }

    let w = min(bufBottom.width, bufTop.width)
    let bottomH = bufBottom.height

    // Pre-extract grayscale once — eliminates per-pixel rgba() overhead in search loop.
    // vDSP_vfltu8 + weighted sum, same pattern as ANFCompare.
    let grayBottom = toGrayscaleFloats(bufBottom)
    let grayTop    = toGrayscaleFloats(bufTop)

    // Score: total mean absolute luminance difference across overlap rows (lower = better match).
    func scoreOverlap(_ overlap: Int) -> Float {
        let checkRows = min(stripHeight, overlap)
        var totalMAD: Float = 0
        var diff = [Float](repeating: 0, count: w)
        grayBottom.withUnsafeBufferPointer { botPtr in
            grayTop.withUnsafeBufferPointer { topPtr in
                let bBase = botPtr.baseAddress!
                let tBase = topPtr.baseAddress!
                for row in 0..<checkRows {
                    let bRow = bottomH - overlap + row
                    guard bRow >= 0 && bRow < bottomH && row < bufTop.height else { continue }
                    vDSP_vsub(tBase + row * w, 1, bBase + bRow * w, 1, &diff, 1, vDSP_Length(w))
                    vDSP_vabs(diff, 1, &diff, 1, vDSP_Length(w))
                    var mad: Float = 0
                    vDSP_meanv(diff, 1, &mad, vDSP_Length(w))
                    totalMAD += mad
                }
            }
        }
        return totalMAD  // lower = better
    }

    // Pass 1: coarse search with 4px steps
    var bestOverlap = 0
    var bestScore = Float.greatestFiniteMagnitude
    for overlap in stride(from: 20, to: maxSearch, by: 4) {
        let score = scoreOverlap(overlap)
        if score < bestScore {
            bestScore = score
            bestOverlap = overlap
        }
    }

    // Pass 2: fine search with 1px steps around the coarse best
    let fineStart = max(20, bestOverlap - 6)
    let fineEnd = min(maxSearch, bestOverlap + 6)
    for overlap in fineStart...fineEnd {
        let score = scoreOverlap(overlap)
        if score < bestScore {
            bestScore = score
            bestOverlap = overlap
        }
    }

    // Quality gate: mean luminance diff < 8 per row ≈ 60% pixel match at threshold 15
    let checkRows = Float(min(stripHeight, bestOverlap))
    if checkRows > 0 && bestScore / checkRows < 8.0 {
        return bestOverlap
    }
    return 0
}

func stitchFrames(_ captures: [CGImage], verbose: Bool) throws -> CGImage {
    guard !captures.isEmpty else { throw CaptureError.noFramesCaptured }
    if captures.count == 1 { return captures[0] }

    let stripHeight = 200

    // Step 1: detect overlaps
    var overlaps: [Int] = [0]
    for i in 1..<captures.count {
        let overlap = detectOverlap(
            bottom: captures[i - 1], top: captures[i],
            maxSearch: captures[i - 1].height * 3 / 4,
            stripHeight: stripHeight
        )
        overlaps.append(overlap)
        if verbose {
            fputs("news-capture: Frame \(i-1)→\(i) overlap: \(overlap)px\n", stderr)
        }
    }

    // Step 2: compute total height and draw with CGContext (proven working approach)
    let frameH = captures[0].height
    let width = captures[0].width
    var totalHeight = frameH
    for i in 1..<captures.count {
        totalHeight += frameH - overlaps[i]
    }

    let bpr = width * 4
    guard let ctx = CGContext(
        data: nil, width: width, height: totalHeight,
        bitsPerComponent: 8, bytesPerRow: bpr,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CaptureError.stitchingFailed
    }

    // CGContext origin is bottom-left. Frame 0 goes at the top (highest y).
    // Draw each frame, cropping the overlap from the top of subsequent frames.
    var y = totalHeight
    for i in 0..<captures.count {
        let cropTop = overlaps[i]
        let drawHeight = frameH - cropTop
        y -= drawHeight
        if cropTop > 0 {
            // CGImage.cropping: origin is top-left, so y=0 is top of image.
            // Crop `cropTop` rows from the top → start at y=cropTop.
            if let cropped = captures[i].cropping(to: CGRect(x: 0, y: cropTop, width: width, height: drawHeight)) {
                ctx.draw(cropped, in: CGRect(x: 0, y: y, width: width, height: drawHeight))
            }
        } else {
            ctx.draw(captures[i], in: CGRect(x: 0, y: y, width: width, height: frameH))
        }
    }

    guard let result = ctx.makeImage() else {
        throw CaptureError.stitchingFailed
    }
    return result
}

// MARK: - PNG Output

func saveImage(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw CaptureError.cannotWriteOutput(path)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw CaptureError.cannotWriteOutput(path)
    }
}

// MARK: - Main

let config = parseArgs()

if config.outputPath.isEmpty {
    printUsage()
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

DispatchQueue.main.async {
    Task { @MainActor in
        do {
            // Permission checks
            try checkAccessibilityPermission()
            try await checkScreenRecordingPermission()

            // Find News.app
            guard let pid = findNewsPID() else {
                throw CaptureError.newsAppNotRunning
            }
            if config.verbose {
                fputs("news-capture: News.app pid=\(pid)\n", stderr)
            }

            // Activate News.app (confirmed frontmost via polling inside activateNewsApp).
            let frontmostOK = await activateNewsApp(pid: pid)
            if config.verbose {
                fputs("news-capture: News.app frontmost=\(frontmostOK)\n", stderr)
            }

            // Find article scroll area
            let scrollArea = try findArticleScrollArea(pid: pid, verbose: config.verbose)
            let info = getScrollAreaInfo(scrollArea, pid: pid, verbose: config.verbose)

            // Find the display containing the scroll area
            let display = try await findDisplay(containing: info.position)

            if config.verbose {
                fputs("news-capture: Starting capture on display \(display.width)x\(display.height)...\n", stderr)
            }

            // Capture loop
            let frames = try await captureArticle(scrollArea: scrollArea, info: info, display: display, pid: pid, config: config)

            if config.verbose {
                fputs("news-capture: Captured \(frames.count) frame(s), stitching...\n", stderr)
            }

            // Stitch
            var result = try stitchFrames(frames, verbose: config.verbose)

            // Backstop (#3): if the FINAL stitch is ~one viewport (only 1 unique frame kept)
            // but the AX web-area content is much taller than one viewport, the scroll never
            // engaged. Fail with a distinct error rather than emit a corrupt one-viewport GT.
            if frames.count == 1 {
                let viewportPx = info.articleRect.size.height * 2   // captured region is 2x Retina
                let oneViewport = result.height <= Int(viewportPx * 1.15)
                if oneViewport, let contentH = axGetWebAreaContentHeight(scrollArea),
                   contentH > info.articleRect.size.height * 1.5 {
                    if config.verbose {
                        fputs("news-capture: One-viewport stitch (\(result.height)px) but AX content height=\(Int(contentH))pt >> viewport=\(Int(info.articleRect.size.height))pt — scroll did not engage\n", stderr)
                    }
                    throw CaptureError.scrollDidNotEngage
                }
            }

            // Crop to article content column (removes scroll bar + grey margins)
            if let contentCol = info.contentColumnRect {
                // Convert screen coords to capture-relative coords (2x Retina)
                let captureX = Int((contentCol.origin.x - info.articleRect.origin.x) * 2)
                let captureW = Int(contentCol.width * 2)
                let cropX = max(0, captureX)
                let cropW = min(captureW, result.width - cropX)
                if cropW > result.width / 5 {
                    let cropRect = CGRect(x: cropX, y: 0, width: cropW, height: result.height)
                    if let cropped = result.cropping(to: cropRect) {
                        result = cropped
                        if config.verbose {
                            fputs("news-capture: Cropped to content column: \(result.width)x\(result.height)\n", stderr)
                        }
                    }
                }
            }

            // Save
            try saveImage(result, to: config.outputPath)

            if config.verbose {
                fputs("news-capture: Output: \(config.outputPath) (\(result.width)x\(result.height))\n", stderr)
            } else {
                fputs("\(config.outputPath)\n", stdout)
            }

        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        NSApp.terminate(nil)
    }
}

app.run()
