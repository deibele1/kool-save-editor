// KSEMac — a KotOR savegame editor for macOS.
// Image decoders for KotOR textures: TPC (uncompressed and S3TC DXT1/DXT5) and TGA.
// Swift port of xoreos-tools' Images::TPC, Images::TGA and the S3TC decompressor
// (https://github.com/xoreos/xoreos-tools). GNU GPL v3 or later.
//
// Differences from the C++ original:
// - Output is always top-down RGBA8; TPC data (stored bottom-up) and bottom-up TGAs are
//   flipped, and TGA's right-to-left flag is honoured.
// - 5/6-bit colors are expanded with bit replication and interpolated with rounding,
//   instead of truncating to 0xF8 and using 0.333333/0.666666 weights.
// - Only the first mip map of the first layer is decoded; tiny compressed images and
//   short data sizes are accepted when the pixel data itself is present.
// - Xbox swizzled textures, DXT3, TXI parsing and color-mapped TGAs are not supported.

import Foundation

public struct RGBAImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Row-major RGBA, 8 bits per channel, first row at the top.
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public mutating func flipVertically() {
        let stride = width * 4
        var top = 0
        var bottom = height - 1
        while top < bottom {
            for i in 0 ..< stride { pixels.swapAt(top * stride + i, bottom * stride + i) }
            top += 1
            bottom -= 1
        }
    }

    public mutating func flipHorizontally() {
        for y in 0 ..< height {
            var left = 0
            var right = width - 1
            while left < right {
                for c in 0 ..< 4 { pixels.swapAt((y * width + left) * 4 + c, (y * width + right) * 4 + c) }
                left += 1
                right -= 1
            }
        }
    }
}

enum S3TC {
    private static func expand(_ color: UInt16) -> (Int, Int, Int) {
        let r = Int(color >> 11) & 0x1F
        let g = Int(color >> 5) & 0x3F
        let b = Int(color) & 0x1F
        return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))
    }

    private static func palette(_ c0: UInt16, _ c1: UInt16, punchThrough: Bool) -> [(Int, Int, Int, Int)] {
        let a = expand(c0)
        let b = expand(c1)
        if !punchThrough || c0 > c1 {
            return [(a.0, a.1, a.2, 255), (b.0, b.1, b.2, 255),
                    ((2 * a.0 + b.0 + 1) / 3, (2 * a.1 + b.1 + 1) / 3, (2 * a.2 + b.2 + 1) / 3, 255),
                    ((a.0 + 2 * b.0 + 1) / 3, (a.1 + 2 * b.1 + 1) / 3, (a.2 + 2 * b.2 + 1) / 3, 255)]
        }
        return [(a.0, a.1, a.2, 255), (b.0, b.1, b.2, 255),
                ((a.0 + b.0 + 1) / 2, (a.1 + b.1 + 1) / 2, (a.2 + b.2 + 1) / 2, 255), (0, 0, 0, 0)]
    }

    static func blockSize(dxt5: Bool) -> Int { dxt5 ? 16 : 8 }

    static func dataSize(width: Int, height: Int, dxt5: Bool) -> Int {
        max(1, (width + 3) / 4) * max(1, (height + 3) / 4) * blockSize(dxt5: dxt5)
    }

    /// Decodes DXT1 or DXT5 blocks into RGBA rows in storage order.
    static func decode(_ source: [UInt8], at start: Int, width: Int, height: Int, dxt5: Bool) throws -> [UInt8] {
        let reader = BinaryReader(source)
        let blocksWide = max(1, (width + 3) / 4)
        let blocksHigh = max(1, (height + 3) / 4)
        var output = [UInt8](repeating: 0, count: width * height * 4)
        var cursor = start
        for by in 0 ..< blocksHigh {
            for bx in 0 ..< blocksWide {
                var alphas = [Int](repeating: 255, count: 16)
                if dxt5 {
                    let a0 = Int(try reader.uint8(at: cursor))
                    let a1 = Int(try reader.uint8(at: cursor + 1))
                    let bits = UInt64(try reader.uint32(at: cursor + 2)) | UInt64(try reader.uint16(at: cursor + 6)) << 32
                    var table = [a0, a1]
                    if a0 > a1 {
                        for i in 1 ... 6 { table.append(((7 - i) * a0 + i * a1 + 3) / 7) }
                    } else {
                        for i in 1 ... 4 { table.append(((5 - i) * a0 + i * a1 + 2) / 5) }
                        table += [0, 255]
                    }
                    for i in 0 ..< 16 { alphas[i] = table[Int((bits >> UInt64(3 * i)) & 7)] }
                    cursor += 8
                }
                let colors = palette(try reader.uint16(at: cursor), try reader.uint16(at: cursor + 2), punchThrough: !dxt5)
                let indices = try reader.uint32(at: cursor + 4)
                cursor += 8
                for y in 0 ..< 4 {
                    for x in 0 ..< 4 {
                        let px = bx * 4 + x
                        let py = by * 4 + y
                        guard px < width, py < height else { continue }
                        let i = y * 4 + x
                        let color = colors[Int((indices >> UInt32(2 * i)) & 3)]
                        let o = (py * width + px) * 4
                        output[o] = UInt8(color.0)
                        output[o + 1] = UInt8(color.1)
                        output[o + 2] = UInt8(color.2)
                        output[o + 3] = UInt8(dxt5 ? alphas[i] : color.3)
                    }
                }
            }
        }
        return output
    }
}

public enum TPCDecoder {
    public static func decode(_ bytes: [UInt8]) throws -> RGBAImage {
        let reader = BinaryReader(bytes)
        guard bytes.count >= 128 else { throw AuroraError.truncated("TPC header") }
        let dataSize = Int(try reader.uint32(at: 0))
        let width = Int(try reader.uint16(at: 8))
        var height = Int(try reader.uint16(at: 10))
        let encoding = try reader.uint8(at: 12)
        guard width > 0, height > 0, width < 0x8000, height < 0x8000 else {
            throw AuroraError.invalidFormat("TPC dimensions \(width)x\(height)")
        }
        let compressed = dataSize != 0
        if compressed, height / width == 6 { height = width }

        var image: RGBAImage
        switch (compressed, encoding) {
        case (false, 1):
            let gray = try reader.bytes(at: 128, count: width * height)
            image = RGBAImage(width: width, height: height, pixels: gray.flatMap { [$0, $0, $0, 255] })
        case (false, 2):
            let rgb = try reader.bytes(at: 128, count: width * height * 3)
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0 ..< width * height {
                pixels[i * 4] = rgb[i * 3]
                pixels[i * 4 + 1] = rgb[i * 3 + 1]
                pixels[i * 4 + 2] = rgb[i * 3 + 2]
            }
            image = RGBAImage(width: width, height: height, pixels: pixels)
        case (false, 4):
            image = RGBAImage(width: width, height: height, pixels: try reader.bytes(at: 128, count: width * height * 4))
        case (true, 2), (true, 4):
            let dxt5 = encoding == 4
            guard S3TC.dataSize(width: width, height: height, dxt5: dxt5) <= bytes.count - 128 else {
                throw AuroraError.truncated("TPC pixel data")
            }
            image = RGBAImage(width: width, height: height,
                              pixels: try S3TC.decode(bytes, at: 128, width: width, height: height, dxt5: dxt5))
        default:
            throw AuroraError.unsupportedVersion("TPC encoding \(encoding)\(compressed ? " (compressed)" : "")")
        }
        image.flipVertically()
        return image
    }
}

public enum TGADecoder {
    public static func decode(_ bytes: [UInt8]) throws -> RGBAImage {
        let reader = BinaryReader(bytes)
        let idLength = Int(try reader.uint8(at: 0))
        let colorMapType = try reader.uint8(at: 1)
        let imageType = try reader.uint8(at: 2)
        let width = Int(try reader.uint16(at: 12))
        let height = Int(try reader.uint16(at: 14))
        let depth = Int(try reader.uint8(at: 16))
        let descriptor = try reader.uint8(at: 17)
        guard colorMapType == 0 else { throw AuroraError.unsupportedVersion("color-mapped TGA") }
        guard [2, 3, 10, 11].contains(imageType) else { throw AuroraError.unsupportedVersion("TGA image type \(imageType)") }
        guard width > 0, height > 0 else { throw AuroraError.invalidFormat("TGA dimensions \(width)x\(height)") }
        let gray = imageType == 3 || imageType == 11
        guard gray ? depth == 8 : [16, 24, 32].contains(depth) else {
            throw AuroraError.unsupportedVersion("TGA depth \(depth)")
        }

        let bytesPerPixel = depth / 8
        let pixelCount = width * height
        var cursor = 18 + idLength
        var pixels = [UInt8](repeating: 255, count: pixelCount * 4)

        func readPixel(into index: Int) throws {
            let o = index * 4
            switch bytesPerPixel {
            case 1:
                let v = try reader.uint8(at: cursor)
                pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v
            case 2:
                let v = try reader.uint16(at: cursor)
                let r = Int(v >> 10) & 0x1F, g = Int(v >> 5) & 0x1F, b = Int(v) & 0x1F
                pixels[o] = UInt8((r << 3) | (r >> 2))
                pixels[o + 1] = UInt8((g << 3) | (g >> 2))
                pixels[o + 2] = UInt8((b << 3) | (b >> 2))
                pixels[o + 3] = (descriptor & 0x0F) > 0 && v & 0x8000 == 0 ? 0 : 255
            default:
                pixels[o] = try reader.uint8(at: cursor + 2)
                pixels[o + 1] = try reader.uint8(at: cursor + 1)
                pixels[o + 2] = try reader.uint8(at: cursor)
                if bytesPerPixel == 4 { pixels[o + 3] = try reader.uint8(at: cursor + 3) }
            }
        }

        if imageType == 2 || imageType == 3 {
            for i in 0 ..< pixelCount {
                try readPixel(into: i)
                cursor += bytesPerPixel
            }
        } else {
            var i = 0
            while i < pixelCount {
                let packet = Int(try reader.uint8(at: cursor))
                cursor += 1
                let run = (packet & 0x7F) + 1
                if packet & 0x80 != 0 {
                    try readPixel(into: i)
                    cursor += bytesPerPixel
                    for j in 1 ..< run where i + j < pixelCount {
                        for c in 0 ..< 4 { pixels[(i + j) * 4 + c] = pixels[i * 4 + c] }
                    }
                } else {
                    for j in 0 ..< run where i + j < pixelCount {
                        try readPixel(into: i + j)
                        cursor += bytesPerPixel
                    }
                }
                i += run
            }
        }

        var image = RGBAImage(width: width, height: height, pixels: pixels)
        if descriptor & 0x20 == 0 { image.flipVertically() }
        if descriptor & 0x10 != 0 { image.flipHorizontally() }
        return image
    }
}
