import Foundation
import ImageIO
import CoreGraphics

// discriminate — compare candidate render PNG vs known-blank refs.
// Metrics: mean abs diff, % pixels differing >12 gray levels, non-white ratio.
// Exit 0 + DISTINCT iff candidate differs from EVERY blank ref beyond thresholds.
// Usage: discriminate <candidate.png> <blank1.png> [blank2.png ...]
// Swift port of discriminate.py: same CLI, stdout keywords, exit codes.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

func grayPixels(_ path: String) -> (Int, Int, [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fail("cannot decode png: \(path)")
    }
    let w = img.width, h = img.height
    let cs = CGColorSpaceCreateDeviceRGB()
    let bpr = w * 4
    var buf = [UInt8](repeating: 0, count: h * bpr)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bpr, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                | CGBitmapInfo.byteOrder32Big.rawValue) else {
        fail("cannot make bitmap context for: \(path)")
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var px = [UInt8](repeating: 0, count: w * h)
    for i in 0 ..< w * h {
        // Unpremultiply to match raw PNG RGB (screenshots are opaque; a==255 fast path exact).
        let a = UInt32(buf[i * 4 + 3])
        let r = UInt32(buf[i * 4]), g = UInt32(buf[i * 4 + 1]), b = UInt32(buf[i * 4 + 2])
        let ru = a >= 255 ? r : (a == 0 ? r : (r * 255 + a / 2) / a)
        let gu = a >= 255 ? g : (a == 0 ? g : (g * 255 + a / 2) / a)
        let bu = a >= 255 ? b : (a == 0 ? b : (b * 255 + a / 2) / a)
        px[i] = UInt8((ru * 77 + gu * 150 + bu * 29) >> 8)
    }
    return (w, h, px)
}

func median(_ px: [UInt8]) -> Int {
    let s = px.sorted()
    return Int(s[s.count / 2])
}

// Returns (nMAD, ndiffpct, rawMAD).
func stats(_ a: [UInt8], _ b: [UInt8]) -> (Double, Double, Double) {
    precondition(a.count == b.count, "size mismatch")
    let n = a.count
    let ma = median(a), mb = median(b)
    var rawSum = 0, madSum = 0, diff = 0
    for i in 0 ..< n {
        let ai = Int(a[i]), bi = Int(b[i])
        rawSum += abs(ai - bi)
        let d = abs((ai - ma) - (bi - mb))
        madSum += d
        if d > 12 { diff += 1 }
    }
    return (Double(madSum) / Double(n), 100.0 * Double(diff) / Double(n),
            Double(rawSum) / Double(n))
}

func nonwhite(_ px: [UInt8]) -> Double {
    var c = 0
    for v in px { if v < 235 { c += 1 } }
    return 100.0 * Double(c) / Double(px.count)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("Usage: discriminate <candidate.png> <blank1.png> [blank2.png ...]")
}
let cand = args[1]
let blanks = Array(args[2...])
let (cw, chh, cpx) = grayPixels(cand)
print(String(format: "candidate %@ %dx%d nonwhite=%.2f%%", cand, cw, chh, nonwhite(cpx)))
var distinctAll = true
for b in blanks {
    let (bw, bh, bpx) = grayPixels(b)
    if bw != cw || bh != chh {
        print("  vs \((b as NSString).lastPathComponent): SIZE-DIFFERS (\(bw)x\(bh)) -> distinct")
        continue
    }
    let (mad, pct, raw) = stats(cpx, bpx)
    let distinct = mad > 3.0 && pct > 2.0
    distinctAll = distinctAll && distinct
    print(String(format: "  vs %@: nMAD=%.2f ndiffpct=%.2f%% rawMAD=%.2f -> %@",
                 (b as NSString).lastPathComponent, mad, pct, raw,
                 distinct ? "DISTINCT" : "SAME-AS-BLANK"))
}
print("VERDICT: \(distinctAll ? "DISTINCT-RENDER" : "BLANK-SHELL")")
exit(distinctAll ? 0 : 1)
