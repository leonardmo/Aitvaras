#!/usr/bin/env swift
import AppKit

// Rebuilds AppIcon.appiconset from the vector source: the coloured dragon
// centred on the white macOS icon square. Run after changing the artwork:
//   swift scripts/generate-app-icon.swift \
//     App/Resources/icon-source/dragon-color.svg \
//     App/Resources/Assets.xcassets/AppIcon.appiconset

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: generate-app-icon.swift <source.svg> <appiconset>\n".utf8))
    exit(2)
}
guard let source = NSImage(contentsOfFile: arguments[1]) else {
    FileHandle.standardError.write(Data("could not read \(arguments[1])\n".utf8))
    exit(1)
}
let destination = URL(fileURLWithPath: arguments[2], isDirectory: true)

// Apple's macOS grid: the rounded square covers 824 of a 1024 canvas, with a
// 185.4 corner radius on that square. The artwork keeps a margin inside it.
let squareRatio = 824.0 / 1024.0
let cornerRatio = 185.4 / 824.0
let artworkRatio = 0.76

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, pixels) in sizes {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else {
        FileHandle.standardError.write(Data("could not allocate \(name)\n".utf8))
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let canvas = Double(pixels)
    let side = canvas * squareRatio
    let origin = (canvas - side) / 2
    let square = NSRect(x: origin, y: origin, width: side, height: side)
    let radius = side * cornerRatio
    NSColor.white.setFill()
    NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius).fill()

    let artwork = side * artworkRatio
    source.draw(in: NSRect(x: (canvas - artwork) / 2, y: (canvas - artwork) / 2,
                           width: artwork, height: artwork),
                from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: destination.appendingPathComponent("\(name).png"))
    print("wrote \(name).png (\(pixels)px)")
}
