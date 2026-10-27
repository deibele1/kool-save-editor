import AppKit
import Aurora
import KotORSave
import SwiftUI

extension RGBAImage {
    var cgImage: CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    var nsImage: NSImage? {
        cgImage.map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) }
    }
}

/// Artwork from the game's texture packs, loaded on demand.
struct GameImage: View {
    let name: String?
    let assets: GameAssets?
    var placeholder = "photo"

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium)
            } else {
                Image(systemName: placeholder)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: name) {
            image = nil
            guard let name, let assets else { return }
            image = await assets.image(name)?.nsImage
        }
    }
}
