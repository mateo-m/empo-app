// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

import AppKit
import SwiftUI

// The shared library code names its image type UIImage. On the Mac,
// that name is NSImage.
typealias UIImage = NSImage

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func pngData() -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

extension Image {
    init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}

extension NSImage {
    var scale: CGFloat { 1 }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func resizedToFit(maxDimension: CGFloat) -> NSImage {
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return self }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return NSImage(size: newSize, flipped: false) { rect in
            self.draw(in: rect)
            return true
        }
    }
}
