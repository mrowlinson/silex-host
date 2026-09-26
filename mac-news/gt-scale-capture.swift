// gt-scale-capture.swift — Apple-engine GT PNGs at scale (T5).
//
// Swift port of gt-scale-capture.py: same CLI flags, same manifest columns,
// same verdicts (PASS/IDENT-FAIL/BLANK-FAIL/CAPTURE-FAIL), same deterministic
// article order (Python random.Random(seed) compatible shuffle).
// Single-file, Foundation + ImageIO/CoreGraphics only. Build: ./build.sh
//
// For each corpus article: open https://apple.news/<slug> in native macOS
// News.app (real Silex/Tangier engine), capture the full article body via
// news-capture, discriminate vs blank/shell failure (size + ink fraction +
// pixel variance), and prove identity vs the local corpus JSON (title +
// identifier + component count from the freshly-cached News assetstore copy).
//
// Writes: <out>/gt-<i>-<slug>.png + <out>/manifest.tsv (one row/article).
// Exit 0 iff <count> articles PASS. Deterministic article order (seed).
//
// Usage:
//   gt-scale-capture --manifest <anf-corpus/manifest.tsv> --count 20
//       --out tmp/trigger/... --tools /path/to/.build/debug [--attempts 30]

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Mersenne Twister (bit-compatible with CPython random.Random for int seeds)

struct MT19937 {
    private var mt = [UInt32](repeating: 0, count: 624)
    private var idx = 624

    /// CPython _random.seed(int): init_genrand(19650218) then init_by_array
    /// over the little-endian 32-bit words of abs(seed). `key` must be non-empty.
    init(key: [UInt32]) {
        mt[0] = 19650218
        for i in 1 ..< 624 {
            mt[i] = 1812433253 &* (mt[i - 1] ^ (mt[i - 1] >> 30)) &+ UInt32(i)
        }
        var i = 1, j = 0
        var k = max(624, key.count)
        while k > 0 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1664525))
                &+ key[j] &+ UInt32(truncatingIfNeeded: j)
            i += 1; j += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            if j >= key.count { j = 0 }
            k -= 1
        }
        k = 623
        while k > 0 {
            mt[i] = (mt[i] ^ ((mt[i - 1] ^ (mt[i - 1] >> 30)) &* 1566083941))
                &- UInt32(i)
            i += 1
            if i >= 624 { mt[0] = mt[623]; i = 1 }
            k -= 1
        }
        mt[0] = 0x8000_0000
    }

    private mutating func twist() {
        for i in 0 ..< 624 {
            let y = (mt[i] & 0x8000_0000) | (mt[(i + 1) % 624] & 0x7FFF_FFFF)
            var v = mt[(i + 397) % 624] ^ (y >> 1)
            if y & 1 != 0 { v ^= 2567483615 }
            mt[i] = v
        }
        idx = 0
    }

    mutating func nextUInt32() -> UInt32 {
        if idx >= 624 { twist() }
        var y = mt[idx]; idx += 1
        y ^= y >> 11
        y ^= (y << 7) & 2636928640
        y ^= (y << 15) & 4022730752
        y ^= y >> 18
        return y
    }

    /// CPython _random.getrandbits: least-significant word first, top word drops LSBs.
    mutating func getrandbits(_ k: Int) -> UInt64 {
        var r: UInt64 = 0
        var kk = k, shift = 0
        while kk > 0 {
            var w = nextUInt32()
            if kk < 32 { w >>= 32 - kk }
            r |= UInt64(w) << shift
            shift += 32; kk -= 32
        }
        return r
    }

    /// CPython _randbelow (with getrandbits).
    mutating func randbelow(_ n: Int) -> Int {
        let k = Int.bitWidth - n.leadingZeroBitCount // n.bit_length()
        var r = Int(getrandbits(k))
        while r >= n { r = Int(getrandbits(k)) }
        return r
    }

    /// CPython Random.shuffle (Fisher-Yates from the end).
    mutating func shuffle<T>(_ a: inout [T]) {
        guard a.count > 1 else { return }
        for i in stride(from: a.count - 1, through: 1, by: -1) {
            a.swapAt(i, randbelow(i + 1))
        }
    }
}

// MARK: - CLI (argparse-compatible: flags, --help text, exit codes)

let prog = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent

/// shutil.get_terminal_size().columns - 2 (COLUMNS env, else 80 when not a tty).
func helpWidth() -> Int {
    if let c = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init), c > 0 {
        return c - 2
    }
    return 78 // piped/file output: argparse default (no tty ioctl without Darwin)
}

/// argparse _format_usage for this CLI (fixed parts; prog from argv[0]).
func usage() -> String {
    let prefix = "usage: "
    let parts = [
        "[-h]", "--manifest MANIFEST", "--count COUNT", "--out OUT",
        "--tools TOOLS", "[--attempts ATTEMPTS]", "[--seed SEED]",
    ]
    let textWidth = helpWidth()
    let joined = ([prog] + parts).joined(separator: " ")
    if prefix.count + joined.count <= textWidth {
        return prefix + joined
    }
    func getLines(_ ps: [String], indent: String, stripFirst: Bool) -> [String] {
        var lines: [String] = []
        var line: [String] = []
        let il = indent.count
        var lineLen = stripFirst ? prefix.count - 1 : il - 1
        for p in ps {
            if lineLen + 1 + p.count > textWidth, !line.isEmpty {
                lines.append(indent + line.joined(separator: " "))
                line = []
                lineLen = il - 1
            }
            line.append(p)
            lineLen += p.count + 1
        }
        if !line.isEmpty { lines.append(indent + line.joined(separator: " ")) }
        if stripFirst, !lines.isEmpty {
            lines[0] = String(lines[0].dropFirst(il))
        }
        return lines
    }
    if Double(prefix.count + prog.count) <= 0.75 * Double(textWidth) {
        let indent = String(repeating: " ", count: prefix.count + prog.count + 1)
        return prefix + getLines([prog] + parts, indent: indent, stripFirst: true)
            .joined(separator: "\n")
    }
    let indent = String(repeating: " ", count: prefix.count)
    return prefix + ([prog] + getLines(parts, indent: indent, stripFirst: false))
        .joined(separator: "\n")
}

func helpText() -> String {
    usage() + "\n\noptions:\n"
        + "  -h, --help           show this help message and exit\n"
        + "  --manifest MANIFEST\n"
        + "  --count COUNT\n"
        + "  --out OUT\n"
        + "  --tools TOOLS\n"
        + "  --attempts ATTEMPTS\n"
        + "  --seed SEED\n"
}

func argError(_ msg: String) -> Never {
    fputs(usage() + "\n\(prog): error: \(msg)\n", stderr)
    exit(2)
}

/// Python int(s): surrounding whitespace ok, [+-]?, digits with single interior underscores.
func pythonInt(_ s: String) -> Int? {
    let t = s.trimmingCharacters(in: .whitespaces)
    var u = t[...]
    if u.first == "+" || u.first == "-" { u = u.dropFirst() }
    guard !u.isEmpty else { return nil }
    var prevUnderscore = false
    var digits = ""
    for c in u {
        if c == "_" {
            if prevUnderscore || digits.isEmpty { return nil }
            prevUnderscore = true
        } else if c.isASCII, c.isNumber {
            digits.append(c); prevUnderscore = false
        } else {
            return nil
        }
    }
    if prevUnderscore { return nil }
    return Int((t.first == "-" ? "-" : "") + digits)
}

/// Python int(s) magnitude as little-endian 32-bit words (arbitrary precision,
// like CPython seeds). Nil unless valid Python int syntax.
func pythonSeedWords(_ s: String) -> [UInt32]? {
    let t = s.trimmingCharacters(in: .whitespaces)
    var u = t[...]
    if u.first == "+" || u.first == "-" { u = u.dropFirst() }
    guard !u.isEmpty else { return nil }
    var prevUnderscore = false
    var digits = ""
    for c in u {
        if c == "_" {
            if prevUnderscore || digits.isEmpty { return nil }
            prevUnderscore = true
        } else if c.isASCII, c.isNumber {
            digits.append(c); prevUnderscore = false
        } else {
            return nil
        }
    }
    if prevUnderscore { return nil }
    var words: [UInt32] = [0]
    for c in digits {
        var carry = UInt64(c.asciiValue! - 48)
        for i in 0 ..< words.count {
            let v = UInt64(words[i]) * 10 + carry
            words[i] = UInt32(truncatingIfNeeded: v)
            carry = v >> 32
        }
        while carry > 0 {
            words.append(UInt32(truncatingIfNeeded: carry)); carry >>= 32
        }
    }
    while words.count > 1, words.last == 0 { words.removeLast() }
    return words
}

struct Args {
    var manifest = ""
    var count = 0
    var out = ""
    var tools = ""
    var attempts = 0
    var seed: [UInt32] = [7]
}

func parseArgs() -> Args {
    var a = Args()
    var seen = Set<String>()
    var extras: [String] = []
    let toks = Array(CommandLine.arguments.dropFirst())
    var i = 0
    var dashdash = false
    while i < toks.count {
        let t = toks[i]
        if dashdash { extras.append(t); i += 1; continue }
        if t == "--" { dashdash = true; i += 1; continue }
        var name = t, val: String? = nil
        if let eq = t.firstIndex(of: "="), t.hasPrefix("-") {
            name = String(t[..<eq]); val = String(t[t.index(after: eq)...])
        }
        switch name {
        case "-h", "--help":
            print(helpText(), terminator: "")
            exit(0)
        case "--manifest", "--count", "--out", "--tools", "--attempts", "--seed":
            var v = val
            if v == nil {
                if i + 1 < toks.count, !toks[i + 1].hasPrefix("-") || toks[i + 1].isEmpty {
                    v = toks[i + 1]; i += 1
                } else {
                    argError("argument \(name): expected one argument")
                }
            } else if v!.hasPrefix("-") {
                // "--count=-5": argparse takes "=…" literally (int("-5") ok).
                // "--count -5": looks like a flag → "expected one argument".
                if v!.isEmpty { argError("argument \(name): expected one argument") }
            }
            let s = v!
            switch name {
            case "--manifest": a.manifest = s
            case "--out": a.out = s
            case "--tools": a.tools = s
            case "--count":
                guard let n = pythonInt(s) else {
                    argError("argument --count: invalid int value: '\(s)'")
                }
                a.count = n
            case "--attempts":
                guard let n = pythonInt(s) else {
                    argError("argument --attempts: invalid int value: '\(s)'")
                }
                a.attempts = n
            case "--seed":
                guard let w = pythonSeedWords(s) else {
                    argError("argument --seed: invalid int value: '\(s)'")
                }
                a.seed = w
            default: break
            }
            seen.insert(name)
        default:
            extras.append(t)
        }
        i += 1
    }
    if !extras.isEmpty {
        argError("unrecognized arguments: \(extras.joined(separator: " "))")
    }
    var missing: [String] = []
    for f in ["--manifest", "--count", "--out", "--tools"] where !seen.contains(f) {
        missing.append(f)
    }
    if !missing.isEmpty {
        argError("the following arguments are required: \(missing.joined(separator: ", "))")
    }
    return a
}

// MARK: - Subprocesses (Python sh(): output discarded; nil only on timeout/spawn failure)

@discardableResult
func sh(_ exe: String, _ args: String..., timeout: TimeInterval? = nil) -> Int32? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    if let t = timeout {
        let deadline = Date().addingTimeInterval(t)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            usleep(500_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            return nil
        }
    } else {
        p.waitUntilExit()
    }
    return p.terminationStatus
}

let CLOSE_SCRIPT = "tell application \"System Events\" to tell process \"News\" to repeat (count of windows) times\n try\n click button 1 of window 1\n end try\n key code 13 using command down\n delay 0.15\nend repeat"

func closeNewsWindows() {
    sh("/usr/bin/osascript", "-e", "tell application \"System Events\" to key code 53")
    Thread.sleep(forTimeInterval: 0.2)
    sh("/usr/bin/osascript", "-e", CLOSE_SCRIPT)
    Thread.sleep(forTimeInterval: 0.4)
}

// MARK: - discriminate (PIL-compatible: L round(), BICUBIC downscale, ink/var)

func loadRGBA(_ path: String) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    let w = img.width, h = img.height
    guard w > 0, h > 0 else { return nil }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = img.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    var ok = false
    px.withUnsafeMutableBytes { buf in
        guard let base = buf.baseAddress else { return }
        guard let ctx = CGContext(
            data: base, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ok = true
    }
    return ok ? (w, h, px) : nil
}

func bicubicKernel(_ x: Double) -> Double {
    // PIL bicubic_filter, a = -0.5 (expression kept identical).
    let ax = x < 0 ? -x : x
    if ax < 1 { return (1.5 * ax - 2.5) * ax * ax + 1 }
    if ax < 2 { return (((ax - 5) * ax + 8) * ax - 4) * -0.5 }
    return 0
}

/// PIL precompute_coeffs + normalize_coeffs_8bpc for one axis (full-image box).
/// Returns (ksize, per-output (min, count), quantized coeffs, ksize-padded per output).
func pilCoeffs(inSize: Int, outSize: Int) -> (Int, [(Int, Int)], [Int]) {
    let scale = Double(inSize) / Double(outSize)
    let filterscale = max(scale, 1.0)
    let support = 2.0 * filterscale
    let ksize = Int(ceil(support)) * 2 + 1
    let inv = 1.0 / filterscale
    var bounds: [(Int, Int)] = []
    var kk: [Int] = []
    kk.reserveCapacity(outSize * ksize)
    for xx in 0 ..< outSize {
        let center = (Double(xx) + 0.5) * scale
        var xmin = Int(center - support + 0.5)
        if xmin < 0 { xmin = 0 }
        var xmax = Int(center + support + 0.5)
        if xmax > inSize { xmax = inSize }
        let count = xmax - xmin
        var wts: [Double] = []
        var ww = 0.0
        for x in 0 ..< count {
            let w = bicubicKernel((Double(x + xmin) - center + 0.5) * inv)
            wts.append(w)
            ww += w
        }
        if ww != 0 {
            for x in 0 ..< count { wts[x] /= ww }
        }
        for x in 0 ..< ksize {
            if x < count {
                let w = wts[x]
                kk.append(w < 0 ? Int(-0.5 + w * 4194304.0) : Int(0.5 + w * 4194304.0))
            } else {
                kk.append(0)
            }
        }
        bounds.append((xmin, count))
    }
    return (ksize, bounds, kk)
}

/// PIL _ImagingResampleHorizontal_8bpc (image8 path).
func pilHorizontal(_ src: [UInt8], w: Int, h: Int, tw: Int) -> [UInt8] {
    let (ksize, bounds, kk) = pilCoeffs(inSize: w, outSize: tw)
    var out = [UInt8](repeating: 0, count: tw * h)
    for yy in 0 ..< h {
        for xx in 0 ..< tw {
            let (xmin, count) = bounds[xx]
            var ss = 1 << 21
            for x in 0 ..< count {
                ss += Int(src[yy * w + xmin + x]) * kk[xx * ksize + x]
            }
            out[yy * tw + xx] = UInt8(min(max(ss >> 22, 0), 255))
        }
    }
    return out
}

/// PIL _ImagingResampleVertical_8bpc (image8 path).
func pilVertical(_ src: [UInt8], w: Int, h: Int, th: Int) -> [UInt8] {
    let (ksize, bounds, kk) = pilCoeffs(inSize: h, outSize: th)
    var out = [UInt8](repeating: 0, count: w * th)
    for yy in 0 ..< th {
        let (ymin, count) = bounds[yy]
        for xx in 0 ..< w {
            var ss = 1 << 21
            for y in 0 ..< count {
                ss += Int(src[(ymin + y) * w + xx]) * kk[yy * ksize + y]
            }
            out[yy * w + xx] = UInt8(min(max(ss >> 22, 0), 255))
        }
    }
    return out
}

/// PIL Image.resize(..., BICUBIC) on an 8-bit gray plane (uint8 rounding between passes).
func bicubicGray(_ src: [UInt8], w: Int, h: Int, tw: Int, th: Int) -> [UInt8] {
    let needH = tw != w, needV = th != h
    if !needH && !needV { return src }
    if needH && !needV { return pilHorizontal(src, w: w, h: h, tw: tw) }
    if needV && !needH { return pilVertical(src, w: w, h: h, th: th) }
    let horizontalFirst = !((h - th) > 0 && (h - th) > (w - tw) * 2)
    if horizontalFirst {
        return pilVertical(pilHorizontal(src, w: w, h: h, tw: tw), w: tw, h: h, th: th)
    }
    return pilHorizontal(pilVertical(src, w: w, h: h, th: th), w: w, h: th, tw: tw)
}

/// (ok, size, w, h, inkFrac, var). Blank/shell => tiny ink/var.
func discriminate(_ png: String) -> (ok: Bool, st: Int, w: Int, h: Int, ink: Double, variance: Double)? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: png),
          let size = (attrs[.size] as? NSNumber)?.intValue,
          let (w, h, px) = loadRGBA(png)
    else { return nil }
    var gray = [UInt8](repeating: 0, count: w * h)
    for i in 0 ..< w * h {
        let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
        gray[i] = UInt8((r * 299 + g * 587 + b * 114 + 500) / 1000) // PIL L(): round-half-up
    }
    // Python: int(200 * h / w) — float divide, truncate.
    let th = max(1, Int(Double(200 * h) / Double(w)))
    let small = bicubicGray(gray, w: w, h: h, tw: 200, th: th)
    var dark = 0
    for p in small where p < 128 { dark += 1 }
    let ink = Double(dark) / Double(small.count)
    let mean = small.reduce(0.0) { $0 + Double($1) } / Double(small.count)
    var ss = 0.0
    for p in small { let d = Double(p) - mean; ss += d * d }
    let variance = ss / Double(small.count) // population variance, like statistics.pvariance
    let ok = size > 100_000 && ink > 0.02 && variance > 500.0
    return (ok, size, w, h, ink, variance)
}

// MARK: - corpus + assetstore identity

struct CorpusMeta {
    var title: String
    var identifier: String
    var comps: Int
}

func readJSON(_ path: String) -> [String: Any]? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return j
}

func compsCount(_ j: [String: Any]) -> Int {
    if let a = j["components"] as? [Any] { return a.count }
    if j["components"] == nil { return 0 }
    if let d = j["components"] as? [String: Any] { return d.count }
    if let s = j["components"] as? String { return s.count }
    return 0
}

func corpusMeta(corpusRoot: String, dir: String, slug: String) -> CorpusMeta? {
    let p = corpusRoot + "/" + dir + "/" + slug + ".json"
    guard let j = readJSON(p) else { return nil }
    return CorpusMeta(
        title: j["title"] as? String ?? "",
        identifier: j["identifier"] as? String ?? slug,
        comps: compsCount(j)
    )
}

/// Find News assetstore copy cached by our open; match id or title.
/// Returns (HIT/MISS, title, identifier, comps).
func cachedIdentity(title: String, slug: String, freshSecs: Double = 900)
    -> (cache: String, title: String, ident: String, comps: Int)
{
    let store = NSHomeDirectory()
        + "/Library/Containers/com.apple.news/Data/Library/Caches/News/shared-assets-assetstore/"
    let now = Date().timeIntervalSince1970
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: store) else {
        return ("MISS", "", "", -1)
    }
    var cands: [(Double, String)] = []
    var stale: [(Double, String)] = []
    for e in names where e.hasSuffix(":imgfile") {
        let fp = store + e
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: fp)) else { continue }
        let first = fh.readData(ofLength: 1)
        try? fh.close()
        guard first.count == 1, first[0] == 0x7B /* "{" */ else { continue }
        guard let mt = (try? FileManager.default.attributesOfItem(atPath: fp))?[.modificationDate]
            as? Date
        else { continue }
        let mtime = mt.timeIntervalSince1970
        if now - mtime < freshSecs {
            cands.append((mtime, fp))
        } else {
            stale.append((mtime, fp))
        }
    }
    for pool in [cands, stale] {
        var best: (String, String, Int)? = nil
        var bestMt = 0.0
        for (mtime, fp) in pool {
            guard let j = readJSON(fp) else { continue }
            let t = j["title"] as? String ?? ""
            if (j["identifier"] as? String) == slug
                || (!title.isEmpty && t.lowercased()
                    .contains(String(title.prefix(25)).lowercased()))
            {
                if mtime > bestMt {
                    best = (t, j["identifier"] as? String ?? "", compsCount(j))
                    bestMt = mtime
                }
            }
        }
        if let b = best { return ("HIT", b.0, b.1, b.2) }
    }
    return ("MISS", "", "", -1)
}

func clean(_ s: String, _ n: Int = 60) -> String {
    String(s.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ").prefix(n))
}

// MARK: - article order (round-robin over seed-shuffled dirs)

func loadOrder(manifest: String, seed: [UInt32]) -> (rows: [(String, String)], order: [(String, String)]) {
    let text = (try? String(contentsOfFile: manifest, encoding: .utf8)) ?? ""
    var lines = text.components(separatedBy: "\n")
    if !lines.isEmpty { lines.removeFirst() } // header
    var rows: [(String, String)] = []
    for line in lines {
        let ln = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let cols = ln.components(separatedBy: "\t")
        if cols.count >= 3 { rows.append((cols[1], cols[2])) }
    }
    var byDir: [String: [String]] = [:]
    var dirSeen: [String] = [] // first-seen (insertion) order, like Python dict
    for (d, slug) in rows {
        if byDir[d] == nil { dirSeen.append(d); byDir[d] = [] }
        byDir[d]!.append(slug)
    }
    var rng = MT19937(key: seed)
    var dirs = byDir.keys.sorted { // Python sorted(): code-point order
        $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
    rng.shuffle(&dirs)
    for d in dirSeen { rng.shuffle(&byDir[d]!) }
    var order: [(String, String)] = []
    var i = 0
    while order.count < rows.count {
        var added = false
        for d in dirs where i < byDir[d]!.count {
            order.append((d, byDir[d]![i]))
            added = true
        }
        if !added { break }
        i += 1
    }
    return (rows, order)
}

// MARK: - main

func out(_ s: String) {
    print(s)
    fflush(stdout)
}

#if PARITY_TEST
// Test hooks (compiled only with -D PARITY_TEST; absent from the shipped binary).
func parityMain() -> Bool {
    let argv = CommandLine.arguments
    if let k = argv.firstIndex(of: "--mt-check") {
        for s in argv[(k + 1)...] {
            guard let w = pythonSeedWords(s) else { continue }
            var r = MT19937(key: w)
            print("\(s) \(r.nextUInt32()) \(r.nextUInt32())")
        }
        return true
    }
    if let k = argv.firstIndex(of: "--dump-order") {
        var mf = ""
        var seed: [UInt32] = [7]
        var j = k + 1
        while j < argv.count {
            if argv[j] == "--manifest", j + 1 < argv.count { mf = argv[j + 1]; j += 2 } else
            if argv[j] == "--seed", j + 1 < argv.count {
                seed = pythonSeedWords(argv[j + 1]) ?? [7]; j += 2
            } else { j += 1 }
        }
        for (d, s) in loadOrder(manifest: mf, seed: seed).order { print("\(d)\t\(s)") }
        return true
    }
    if let k = argv.firstIndex(of: "--png-stats") {
        for p in argv[(k + 1)...] {
            if let d = discriminate(p) {
                print("\(p)\tok=\(d.ok ? 1 : 0) st=\(d.st) w=\(d.w) h=\(d.h)"
                    + String(format: " ink=%.4f var=%.0f", d.ink, d.variance))
            } else {
                print("\(p)\tMISSING")
            }
        }
        return true
    }
    if let k = argv.firstIndex(of: "--verdict"), argv.count > k + 3 {
        let png = argv[k + 1], corpusJson = argv[k + 2], slug = argv[k + 3]
        guard let j = readJSON(corpusJson) else { print("SKIP no-corpus-json"); return true }
        let meta = CorpusMeta(
            title: j["title"] as? String ?? "",
            identifier: j["identifier"] as? String ?? slug, comps: compsCount(j))
        guard let d = discriminate(png) else { print("CAPTURE-FAIL"); return true }
        let c = cachedIdentity(title: meta.title, slug: slug)
        let ident = c.cache == "HIT" && (c.ident == meta.identifier || c.ident == slug
            || (!meta.title.isEmpty && c.title.lowercased()
                .contains(String(meta.title.prefix(25)).lowercased())))
        let verdict = d.ok && ident ? "PASS" : (d.ok ? "IDENT-FAIL" : "BLANK-FAIL")
        print(verdict + String(format: " ink=%.4f var=%.0f", d.ink, d.variance)
            + " \(d.w)x\(d.h) cache=\(c.cache)")
        return true
    }
    return false
}
#endif

func main() -> Int32 {
    #if PARITY_TEST
        if parityMain() { return 0 }
    #endif
    let a = parseArgs()
    guard FileManager.default.isReadableFile(atPath: a.manifest) else {
        // Python tracebacks (FileNotFoundError, exit 1) here; same exit, clean message.
        fputs(
            "\(prog): error: argument --manifest: can't open '\(a.manifest)': No such file or directory\n",
            stderr)
        return 1
    }
    let corpusRoot = URL(fileURLWithPath: a.manifest).deletingLastPathComponent().path
    let newsCapture = (a.tools as NSString).appendingPathComponent("news-capture")
    try? FileManager.default.createDirectory(
        atPath: a.out, withIntermediateDirectories: true)

    let (rows, order) = loadOrder(manifest: a.manifest, seed: a.seed)
    _ = rows
    let maxAttempts = a.attempts != 0 ? a.attempts : a.count * 2

    let manPath = (a.out as NSString).appendingPathComponent("manifest.tsv")
    FileManager.default.createFile(atPath: manPath, contents: nil)
    guard let man = try? FileHandle(forWritingTo: URL(fileURLWithPath: manPath)) else {
        fputs("\(prog): error: cannot write \(manPath)\n", stderr)
        return 1
    }
    func manWrite(_ s: String) {
        man.write(Data(s.utf8))
        man.synchronizeFile()
    }
    manWrite("n\tdir\tslug\tpng\tpass\tink\tvar\tw\th\tcorpus_title\tcorpus_comps\tcache\tcache_title\tcache_comps\n")

    var passes = 0, n = 0
    for (d, slug) in order {
        if passes >= a.count || n >= maxAttempts { break }
        n += 1
        guard let meta = corpusMeta(corpusRoot: corpusRoot, dir: d, slug: slug) else {
            out("[\(n)] \(d)/\(slug): SKIP no-corpus-json")
            continue
        }
        var png = (a.out as NSString)
            .appendingPathComponent(String(format: "gt-%02d-%@.png", passes + 1, slug))
        out("[\(n)] \(d)/\(slug): opening...")
        sh("/usr/bin/open", "-b", "com.apple.news")
        Thread.sleep(forTimeInterval: 2.5)
        closeNewsWindows()
        sh("/usr/bin/open", "-a", "News", "https://apple.news/\(slug)")
        Thread.sleep(forTimeInterval: 11)
        out("[\(n)] capturing...")
        let r = sh(newsCapture, "-o", png, timeout: 240)
        if r == nil || !FileManager.default.fileExists(atPath: png) {
            out("[\(n)] \(d)/\(slug): CAPTURE-FAIL")
            manWrite("\(n)\t\(d)\t\(slug)\t-\tCAPTURE-FAIL\t-\t-\t-\t-\t\(clean(meta.title))\t\(meta.comps)\t-\t-\t-\n")
            continue
        }
        guard let dc = discriminate(png) else {
            out("[\(n)] \(d)/\(slug): CAPTURE-FAIL")
            manWrite("\(n)\t\(d)\t\(slug)\t-\tCAPTURE-FAIL\t-\t-\t-\t-\t\(clean(meta.title))\t\(meta.comps)\t-\t-\t-\n")
            continue
        }
        let c = cachedIdentity(title: meta.title, slug: slug)
        let ident = c.cache == "HIT" && (c.ident == meta.identifier || c.ident == slug
            || (!meta.title.isEmpty && c.title.lowercased()
                .contains(String(meta.title.prefix(25)).lowercased())))
        let verdict = dc.ok && ident ? "PASS" : (dc.ok ? "IDENT-FAIL" : "BLANK-FAIL")
        if verdict == "PASS" {
            passes += 1
            let final = (a.out as NSString)
                .appendingPathComponent(String(format: "gt-%02d-%@.png", passes, slug))
            if final != png {
                try? FileManager.default.moveItem(atPath: png, toPath: final)
                png = final
            }
        } else {
            let fail = (a.out as NSString)
                .appendingPathComponent(String(format: "FAIL-%02d-%@.png", n, slug))
            try? FileManager.default.moveItem(atPath: png, toPath: fail)
            png = String(format: "FAIL-%02d-%@.png", n, slug)
        }
        out(String(
            format: "[%d] %@/%@: %@ ink=%.3f var=%.0f %dx%d cache=%@",
            n, d, slug, verdict, dc.ink, dc.variance, dc.w, dc.h, c.cache))
        manWrite(String(
            format: "%d\t%@\t%@\t%@\t%@\t%.4f\t%.0f\t%d\t%d\t%@\t%d\t%@\t%@\t%d\n",
            n, d, slug, URL(fileURLWithPath: png).lastPathComponent, verdict,
            dc.ink, dc.variance, dc.w, dc.h, clean(meta.title), meta.comps,
            c.cache, clean(c.title), c.comps))
    }
    try? man.close()
    out("SCALE: \(passes)/\(a.count) PASS in \(n) attempts")
    return passes >= a.count ? 0 : 1
}

exit(main())
