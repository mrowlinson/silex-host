import Foundation
import ImageIO
import CoreGraphics

// pngvar — pixel-variance discriminator. Prints '<variance> <ncolors>'.
// Swift port of pngvar.py: same CLI, stdout, exit codes.
// Blank-shell failure mode: near-white screen + back chevron + tab bar =>
// low variance, few distinct colors. Rendered article => high variance,
// many colors. Cutoff: var > 1500 AND colors > 500.
// Pixels are raw decoded samples (same bytes PIL sees; no colorspace draw).
// Downscale replicates PIL resize (BICUBIC default): Keys a=-0.5, support
// widened by 1/scale when downscaling, out-of-range taps dropped with
// weights renormalized, horizontal intermediate rounded+clipped to 8-bit.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}

// Returns w, h, and packed RGB bytes. Alpha ignored, same as PIL RGBA->L/RGB.
func rgbPixels(_ path: String) -> (Int, Int, [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let dp = img.dataProvider,
          let cf = dp.data,
          let base = CFDataGetBytePtr(cf) else {
        fail("cannot decode png: \(path)")
    }
    let w = img.width, h = img.height
    guard img.bitsPerComponent == 8 else {
        fail("unsupported depth (\(img.bitsPerComponent)bpc): \(path)")
    }
    guard CFDataGetLength(cf) >= h * img.bytesPerRow else {
        fail("short pixel data: \(path)")
    }
    let bpr = img.bytesPerRow
    let bpp = img.bitsPerPixel
    var out = [UInt8](repeating: 0, count: w * h * 3)
    if img.colorSpace?.model == .monochrome {
        let step = bpp / 8
        guard bpp == 8 || bpp == 16 else { fail("unsupported gray bpp \(bpp): \(path)") }
        for y in 0 ..< h {
            let row = base + y * bpr
            for x in 0 ..< w {
                let g = row[x * step]
                let o = (y * w + x) * 3
                out[o] = g; out[o + 1] = g; out[o + 2] = g
            }
        }
        return (w, h, out)
    }
    guard img.colorSpace?.model == .rgb else {
        fail("unsupported colorspace: \(path)")
    }
    if bpp == 24 {
        for y in 0 ..< h {
            let row = base + y * bpr
            for x in 0 ..< w {
                let o = (y * w + x) * 3
                out[o] = row[x * 3]; out[o + 1] = row[x * 3 + 1]; out[o + 2] = row[x * 3 + 2]
            }
        }
        return (w, h, out)
    }
    guard bpp == 32 else { fail("unsupported rgb bpp \(bpp): \(path)") }
    let alpha = img.alphaInfo
    if alpha == .premultipliedLast || alpha == .premultipliedFirst {
        fail("premultiplied source, refusing (would skew vs PIL): \(path)")
    }
    let order = CGBitmapInfo(rawValue: img.bitmapInfo.rawValue).intersection(.byteOrderMask)
    let little = (order == .byteOrder32Little)
    // Channel offsets for 32-bit words given alpha placement + byte order.
    var ro = 0, go = 1, bo = 2
    switch (alpha, little) {
    case (.first, false), (.noneSkipFirst, false): ro = 1; go = 2; bo = 3
    case (.first, true), (.noneSkipFirst, true): ro = 2; go = 1; bo = 0
    case (.last, true), (.noneSkipLast, true): ro = 3; go = 2; bo = 1
    default: ro = 0; go = 1; bo = 2 // last/none/skip-last, big-endian/default
    }
    for y in 0 ..< h {
        let row = base + y * bpr
        for x in 0 ..< w {
            let s = x * 4
            let o = (y * w + x) * 3
            out[o] = row[s + ro]; out[o + 1] = row[s + go]; out[o + 2] = row[s + bo]
        }
    }
    return (w, h, out)
}

// PIL Image.convert("L") luma: (R*299 + G*587 + B*114 + 500) / 1000.
func luma(_ r: Int, _ g: Int, _ b: Int) -> Int {
    return (r * 299 + g * 587 + b * 114 + 500) / 1000
}

// Keys bicubic, a=-0.5 (PIL BicubicFilter).
func kbc(_ x: Double) -> Double {
    let a = -0.5
    let x = abs(x)
    if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
    if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
    return 0
}

// Per-output tap (index, weight) lists for one axis.
func bicubicCoeffs(nin: Int, nout: Int) -> [(idx: [Int], w: [Double])] {
    let scale = Double(nout) / Double(nin)
    let s = scale < 1 ? scale : 1.0
    let sup = 2.0 / s
    var out: [(idx: [Int], w: [Double])] = []
    out.reserveCapacity(nout)
    for o in 0 ..< nout {
        let c = (Double(o) + 0.5) / scale - 0.5
        let lo = Int(floor(c - sup + 1e-9)) + 1
        let hi = Int(ceil(c + sup - 1e-9))
        var idx: [Int] = []
        var w: [Double] = []
        for t in lo ..< hi {
            if t < 0 || t >= nin { continue } // drop out-of-range taps
            let wt = kbc((Double(t) - c) * s)
            if wt == 0 { continue }
            idx.append(t)
            w.append(wt)
        }
        let sum = w.reduce(0, +)
        if sum != 0 {
            for i in 0 ..< w.count { w[i] /= sum }
        }
        out.append((idx, w))
    }
    return out
}

func clip8(_ v: Double) -> UInt8 {
    return UInt8(min(255, max(0, Int(v + 0.5))))
}

// Separable bicubic resample of one 8-bit band; horizontal pass rounds to 8-bit.
func resampleBand(_ px: [UInt8], sw: Int, sh: Int, dw: Int, dh: Int) -> [UInt8] {
    let cx = bicubicCoeffs(nin: sw, nout: dw)
    let cy = bicubicCoeffs(nin: sh, nout: dh)
    var tmp = [UInt8](repeating: 0, count: sh * dw)
    for y in 0 ..< sh {
        for o in 0 ..< dw {
            var acc = 0.0
            let taps = cx[o]
            for k in 0 ..< taps.idx.count {
                acc += Double(px[y * sw + taps.idx[k]]) * taps.w[k]
            }
            tmp[y * dw + o] = clip8(acc)
        }
    }
    var dst = [UInt8](repeating: 0, count: dw * dh)
    for o in 0 ..< dh {
        for x in 0 ..< dw {
            var acc = 0.0
            let taps = cy[o]
            for k in 0 ..< taps.idx.count {
                acc += Double(tmp[taps.idx[k] * dw + x]) * taps.w[k]
            }
            dst[o * dw + x] = clip8(acc)
        }
    }
    return dst
}

let args = CommandLine.arguments
guard args.count == 2 else {
    fail("Usage: pngvar <image.png>")
}
let (sw, sh, rgb) = rgbPixels(args[1])

// L frame 200x400, population variance (PIL ImageStat.Stat.var).
var gray = [UInt8](repeating: 0, count: sw * sh)
for i in 0 ..< sw * sh {
    gray[i] = UInt8(luma(Int(rgb[i * 3]), Int(rgb[i * 3 + 1]), Int(rgb[i * 3 + 2])))
}
let small = resampleBand(gray, sw: sw, sh: sh, dw: 200, dh: 400)
var sum = 0.0
var sumSq = 0.0
for v in small {
    let d = Double(v)
    sum += d
    sumSq += d * d
}
let n = Double(small.count)
let mean = sum / n
let variance = sumSq / n - mean * mean

// RGB frame 100x200, distinct-color count (PIL getcolors).
var r = [UInt8](repeating: 0, count: sw * sh)
var g = [UInt8](repeating: 0, count: sw * sh)
var b = [UInt8](repeating: 0, count: sw * sh)
for i in 0 ..< sw * sh {
    r[i] = rgb[i * 3]; g[i] = rgb[i * 3 + 1]; b[i] = rgb[i * 3 + 2]
}
let rs = resampleBand(r, sw: sw, sh: sh, dw: 100, dh: 200)
let gs = resampleBand(g, sw: sw, sh: sh, dw: 100, dh: 200)
let bs = resampleBand(b, sw: sw, sh: sh, dw: 100, dh: 200)
var colors = Set<Int32>()
colors.reserveCapacity(100 * 200)
for i in 0 ..< 100 * 200 {
    colors.insert(Int32(rs[i]) << 16 | Int32(gs[i]) << 8 | Int32(bs[i]))
}

// Python f"{var:.0f}" = round-half-even.
let varInt = Int(variance.rounded(.toNearestOrEven))
print("\(varInt) \(colors.count)")
