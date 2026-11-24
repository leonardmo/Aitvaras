import Foundation
import ImageIO
import UniformTypeIdentifiers

extension AgentAttachment {
    /// Preserve small supported images and downsample larger clipboard formats to fit the attachment budget.
    public static func pastedImage(from data: Data) throws -> Self {
        try Task.checkCancellation()
        if let original = try? Self(name: "Pasted image", data: data), original.kind == .image,
           let type = UTType(mimeType: original.mediaType), let ext = type.preferredFilenameExtension {
            return try Self(name: "Pasted image.\(ext)", data: data)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AgentAttachmentError.unsupportedType
        }
        for maxPixels in [1600, 1000, 640, 480] {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels
            ] as CFDictionary) else { throw AgentAttachmentError.unsupportedType }

            let type: UTType = image.alphaInfo == .none || image.alphaInfo == .noneSkipFirst || image.alphaInfo == .noneSkipLast
                ? .jpeg : .png
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
                throw AgentAttachmentError.unsupportedType
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
            if CGImageDestinationFinalize(destination), output.length <= maximumBytes {
                return try Self(name: type == .png ? "Pasted image.png" : "Pasted image.jpg", data: output as Data)
            }
        }
        throw AgentAttachmentError.tooLarge
    }
}
