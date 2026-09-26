#!/usr/bin/env swiftc
// mac-news-scale.swift — open corpus slugs in macOS News, capture, discriminate.
// Usage: mac-news-scale <queue.tsv> <outdir> <start> <count>
// queue.tsv: dir<TAB>slug per line. Appends manifest rows to outdir/manifest.tsv.
// Reads ONLY each article's title from the corpus JSON (selective, no bulk copy).
// Env: ANF_CORPUS=<dir of <publisher>/<slug>.json files> (required),
//      WINLIST_BIN_DIR=<dir holding the `winlist` binary> (default: this binary's dir;
//      build with: ./build.sh).
// Swift port of mac-news-scale.py — same CLI, stdout keywords, exit codes, verdicts.
// Hidden test hooks (not part of the CLI contract): --stats <png>, --match <c> <w>.
import Foundation
import CoreGraphics
import ImageIO

func eprint(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func oprint(_ s: String) { print(s); fflush(stdout) }

func envCorpus() -> String {
    if let c = ProcessInfo.processInfo.environment["ANF_CORPUS"], !c.isEmpty { return c }
    eprint("set ANF_CORPUS=<corpus dir> (contains <publisher>/<slug>.json)")
    exit(1)
}

func binDir() -> String {
    if let b = ProcessInfo.processInfo.environment["WINLIST_BIN_DIR"] { return b }
    let argv0 = CommandLine.arguments[0]
    if argv0.contains("/") {
        return URL(fileURLWithPath: argv0).deletingLastPathComponent().path
    }
    return FileManager.default.currentDirectoryPath
}

@discardableResult
func runCapture(_ path: String, _ args: [String] = []) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

// line format: "<wid> | News | <title>" (same regex as python: (\d+) \| News \| (.*))
func newsWindows(bin: String) -> [Int: String] {
    let out = runCapture("\(bin)/winlist")
    var wins: [Int: String] = [:]
    for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
        guard let r = line.range(of: " | News | ") else { continue }
        let idPart = line[..<r.lowerBound]
        if idPart.isEmpty || !idPart.allSatisfy({ $0.isNumber && $0.isASCII }) { continue }
        if let wid = Int(idPart) {
            wins[wid] = String(line[r.upperBound...])
        }
    }
    return wins
}

func norm(_ s: String) -> String {
    // [^a-z0-9]+ -> " ", lowercase, trim (same as python re.sub)
    var out = ""
    out.reserveCapacity(s.count)
    var inRun = false
    for scalar in s.lowercased().unicodeScalars {
        let v = scalar.value
        let ok = (v >= 97 && v <= 122) || (v >= 48 && v <= 57)
        if ok {
            out.append(Character(scalar))
            inRun = false
        } else if !inRun {
            out.append(" ")
            inRun = true
        }
    }
    var i = out.startIndex
    while i < out.endIndex && out[i] == " " { i = out.index(after: i) }
    var j = out.endIndex
    while j > i && out[out.index(before: j)] == " " { j = out.index(before: j) }
    return String(out[i..<j])
}

func titleMatch(_ ctitle: String, _ wtitle: String) -> Bool {
    let c = norm(ctitle), w = norm(wtitle)
    if c.isEmpty || w.isEmpty { return false }
    if w.contains(String(c.prefix(30))) { return true }
    if c.contains(String(w.prefix(30))) { return true }
    return c.split(separator: " ").prefix(4).elementsEqual(w.split(separator: " ").prefix(4))
}

// PIL Image.convert("L") luma: (R*299 + G*587 + B*114 + 500) / 1000 (verified vs Pillow).
// Alpha ignored, same as PIL RGBA->L.
func pilLuma(r: Int, g: Int, b: Int) -> UInt8 {
    return UInt8((r * 299 + g * 587 + b * 114 + 500) / 1000)
}

func grayPixels(png: String) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    let n = w * h
    // Fast path: read the decoded 8-bit buffer directly (exact, no colorspace math).
    if img.bitsPerComponent == 8,
       let data = img.dataProvider?.data as Data?, !data.isEmpty {
        let bpr = img.bytesPerRow
        if img.colorSpace?.numberOfComponents == 1 && img.bitsPerPixel == 8 && bpr >= w {
            var px = [UInt8](repeating: 0, count: n)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h {
                    let row = base.advanced(by: y * bpr)
                    for x in 0..<w { px[y * w + x] = row[x] }
                }
            }
            return (w, h, px)
        }
        if img.bitsPerPixel == 32 && bpr >= w * 4 {
            let ai = img.alphaInfo
            let alphaFirst = (ai == .first || ai == .premultipliedFirst)
            let prem = (ai == .premultipliedFirst || ai == .premultipliedLast)
            let little = img.bitmapInfo.contains(.byteOrder32Little)
            func comp(_ o: Int) -> Int { little ? 3 - o : o }
            let ri = comp(alphaFirst ? 1 : 0), gi = comp(alphaFirst ? 2 : 1),
                bi = comp(alphaFirst ? 3 : 2), aai = comp(alphaFirst ? 0 : 3)
            var px = [UInt8](repeating: 0, count: n)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h {
                    let row = base.advanced(by: y * bpr)
                    for x in 0..<w {
                        let p = row.advanced(by: x * 4)
                        var r = Int(p[ri]), g = Int(p[gi]), b = Int(p[bi])
                        if prem {
                            let a = Int(p[aai])
                            if a == 0 { r = 0; g = 0; b = 0 }
                            else if a < 255 {
                                r = min(255, (r * 255 + a / 2) / a)
                                g = min(255, (g * 255 + a / 2) / a)
                                b = min(255, (b * 255 + a / 2) / a)
                            }
                        }
                        px[y * w + x] = pilLuma(r: r, g: g, b: b)
                    }
                }
            }
            return (w, h, px)
        }
    }
    // Fallback: rasterize through a premultiplied RGBA context (16-bit/odd formats).
    var rgba = [UInt8](repeating: 0, count: n * 4)
    guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var px = [UInt8](repeating: 0, count: n)
    for i in 0..<n {
        px[i] = pilLuma(r: Int(rgba[i * 4]), g: Int(rgba[i * 4 + 1]), b: Int(rgba[i * 4 + 2]))
    }
    return (w, h, px)
}

// python round(x, 1): banker's rounding on the decimal repr
func pyRound1(_ x: Double) -> Double {
    return (x * 10).rounded(.toNearestOrEven) / 10
}

func fmtNum(_ x: Double) -> String {
    // match python str(round(x,1)): shortest repr, always shows .0 for integral
    let r = pyRound1(x)
    if r == r.rounded(.towardZero) && abs(r) < 1e15 {
        return String(format: "%.1f", r)
    }
    return String(r)
}

func stats(png: String) -> (w: Int, h: Int, mean: Double, stdev: Double)? {
    guard let (w, h, px) = grayPixels(png: png) else { return nil }
    let step = max(1, px.count / 200000)
    var n = 0
    var sum = 0.0
    var i = 0
    while i < px.count { sum += Double(px[i]); n += 1; i += step }
    let mean = sum / Double(n)
    var ss = 0.0
    i = 0
    while i < px.count { let d = Double(px[i]) - mean; ss += d * d; i += step }
    let stdev = n > 1 ? (ss / Double(n - 1)).squareRoot() : 0.0
    return (w, h, pyRound1(mean), pyRound1(stdev))
}

func corpusTitle(corpus: String, dir d: String, slug: String) throws -> String {
    let url = URL(fileURLWithPath: "\(corpus)/\(d)/\(slug).json")
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return obj?["title"] as? String ?? ""
}

func main() {
    let args = CommandLine.arguments
    // hidden test hooks
    if args.count == 3 && args[1] == "--stats" {
        guard let s = stats(png: args[2]) else { eprint("STAT-FAIL \(args[2])"); exit(1) }
        print("\(s.w)x\(s.h) mean=\(fmtNum(s.mean)) stdev=\(fmtNum(s.stdev))")
        return
    }
    if args.count == 4 && args[1] == "--match" {
        print("c=[\(norm(args[2]))] w=[\(norm(args[3]))] \(titleMatch(args[2], args[3]) ? "MATCH" : "NOMATCH")")
        return
    }
    // env checked before argc, same order as the python (module-level exit)
    let corpus = (args.count == 3 && args[1] == "--stats") ||
        (args.count == 4 && args[1] == "--match") ? "" : envCorpus()
    if args.count != 5 {
        eprint("Usage: mac-news-scale <queue.tsv> <outdir> <start> <count>")
        exit(1)
    }
    let bin = binDir()
    let queue = args[1], outdir = args[2]
    guard let start = Int(args[3]), let count = Int(args[4]) else {
        eprint("Usage: mac-news-scale <queue.tsv> <outdir> <start> <count>")
        exit(1)
    }
    guard let qtext = try? String(contentsOfFile: queue, encoding: .utf8) else {
        eprint("[Errno 2] No such file or directory: '\(queue)'")
        exit(1)
    }
    var rows: [[String]] = []
    for raw in qtext.components(separatedBy: "\n") {
        var line = raw
        if line.hasSuffix("\r") { line = String(line.dropLast()) }
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
        rows.append(line.components(separatedBy: "\t"))
    }
    let fm = FileManager.default
    try? fm.createDirectory(atPath: "\(outdir)/pngs", withIntermediateDirectories: true)
    if !fm.fileExists(atPath: "\(outdir)/manifest.tsv") {
        fm.createFile(atPath: "\(outdir)/manifest.tsv", contents: nil)
    }
    guard let man = FileHandle(forWritingAtPath: "\(outdir)/manifest.tsv") else {
        eprint("cannot open \(outdir)/manifest.tsv for append")
        exit(1)
    }
    man.seekToEndOfFile()
    func emit(_ s: String) {
        man.write((s + "\n").data(using: .utf8)!)
    }
    let end = min(start + count, rows.count)
    if start < end {
        for idx in start..<end {
            let cols = rows[idx]
            if cols.count < 2 {
                eprint("ValueError: row \(idx) has no tab-separated dir/slug")
                exit(1)
            }
            let d = cols[0], slug = cols[1]
            let ctitle: String
            do {
                ctitle = try corpusTitle(corpus: corpus, dir: d, slug: slug)
            } catch {
                oprint("[\(idx)] \(slug) CORPUS-READ-FAIL \((error as NSError).localizedDescription)")
                continue
            }
            let before = newsWindows(bin: bin)
            runCapture("/usr/bin/open", ["-a", "News", "https://apple.news/\(slug)"])
            Thread.sleep(forTimeInterval: 9)
            let after = newsWindows(bin: bin)
            let new = after.keys.filter { before[$0] == nil }.sorted()
            if new.isEmpty {
                oprint("[\(idx)] \(slug) NO-WINDOW")
                emit("\(idx)\t\(d)\t\(slug)\tNO-WINDOW\t\t\t\t")
                continue
            }
            let wid = new.last!
            let png = "\(outdir)/pngs/\(String(format: "%02d", idx))-\(slug).png"
            runCapture("/usr/bin/screencapture", ["-l\(wid)", "-x", png])
            Thread.sleep(forTimeInterval: 1)
            guard let s = stats(png: png) else {
                oprint("[\(idx)] \(slug) CAP-FAIL cannot decode \(png)")
                continue
            }
            let kb: Int
            do {
                let attrs = try fm.attributesOfItem(atPath: png)
                kb = (attrs[.size] as? Int ?? 0) / 1024
            } catch {
                oprint("[\(idx)] \(slug) CAP-FAIL \((error as NSError).localizedDescription)")
                continue
            }
            let wtitle = after[wid] ?? ""
            let m = titleMatch(ctitle, wtitle) ? "MATCH" : "NOMATCH"
            let ok = (m == "MATCH" && s.stdev > 40 && kb > 100) ? "PASS" : "REVIEW"
            oprint("[\(idx)] \(slug) \(ok) \(m) \(s.w)x\(s.h) sd=\(fmtNum(s.stdev)) \(kb)KB :: \(String(wtitle.prefix(60)))")
            emit("\(idx)\t\(d)\t\(slug)\t\(ok)\t\(m)\t\(s.w)x\(s.h)\t\(fmtNum(s.stdev))\t\(kb)KB\t\(wtitle)")
        }
    }
    man.closeFile()
}

main()
