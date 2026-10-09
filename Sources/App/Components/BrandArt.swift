// BrandArt.swift: HeatBox's artwork inside the app.
//
// The approved illustration, unchanged: never stretched, recoloured or
// cropped, never under text, and never drawn smaller than 64 points, below
// which its label cannot be read.

import AppKit
import Engine
import SwiftUI

struct BrandArt: View {
    var height: CGFloat = 96

    /// The picture in the app's bundle. A bare program (`swift run`) has no
    /// bundle, and shows the app's icon in its place.
    private static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "HeatBoxArt", withExtension: "png"), let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }()

    var body: some View {
        Image(nsImage: Self.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: max(height, 64))
            .accessibilityHidden(true)
    }
}

/// What a screen shows when it has nothing to list yet.
struct EmptyState: View {
    let title: String
    let text: String
    @Environment(\.palette) private var p

    var body: some View {
        VStack(spacing: 10) {
            BrandArt(height: 128)
                .padding(.bottom, 4)
            Text(title)
                .font(p.font(17, .semibold))
                .foregroundColor(p.text)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(p.font(13))
                .foregroundColor(p.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}
