import CoreGraphics

enum HeatmapStyle { case smooth, banded }

/// Build a premultiplied-RGBA CGImage from a state grid.
/// width = g.cols, height = g.rows, row 0 = north edge.
/// Cache the result per state — do not rebuild on every map pan.
func makeHeatmapImage(_ g: DVCStateGridInfo,
                      engine: DVCRiskModel,
                      style: HeatmapStyle = .smooth) -> CGImage? {
    let w = g.cols, h = g.rows
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cut = engine.bandCutoffs

    for i in 0..<(w * h) {
        let rel = Double(g.bytes[i]) / 255.0
        var r = 0.0, gr = 0.0, b = 0.0, a = 0.0

        switch style {
        case .smooth:
            if rel > 0.02 {
                // hue 0.33 (green) -> 0.0 (red) as rel goes 0.15 -> 0.9
                let t = min(max((rel - 0.15) / 0.75, 0), 1)
                (r, gr, b) = hsv(hue: 0.33 * (1 - t), s: 0.9, v: 0.95)
                a = min(max((rel - 0.05) / 0.6, 0), 0.65)
            }

        case .banded:
            let inten = engine.intensity(forRelative: rel)
            let rgba: (r: Double, g: Double, b: Double, a: Double)
            if inten >= cut.p99      { rgba = DVCRiskBand.severe.rgba   }
            else if inten >= cut.p95 { rgba = DVCRiskBand.high.rgba     }
            else if inten >= cut.p80 { rgba = DVCRiskBand.moderate.rgba }
            else if rel > 0.02       { rgba = DVCRiskBand.low.rgba      }
            else                     { rgba = (0, 0, 0, 0)             }
            (r, gr, b, a) = (rgba.r, rgba.g, rgba.b, rgba.a)
        }

        // premultiply
        px[i*4+0] = UInt8(min(r  * a * 255, 255))
        px[i*4+1] = UInt8(min(gr * a * 255, 255))
        px[i*4+2] = UInt8(min(b  * a * 255, 255))
        px[i*4+3] = UInt8(min(a  * 255, 255))
    }

    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(data: &px, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: cs, bitmapInfo: info) else { return nil }
    return ctx.makeImage()
}

// MARK: - HSV helper

/// Convert HSV (all 0…1) to linear RGB triple.
func hsv(hue h: Double, s: Double, v: Double) -> (Double, Double, Double) {
    let i = floor(h * 6), f = h * 6 - i
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch Int(i) % 6 {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}
