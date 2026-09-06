#!/usr/bin/env swift
import Vision
import AppKit
import CoreImage

guard CommandLine.arguments.count >= 3 else {
    print("Usage: ./removebg.swift input.png output.png")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

let url = URL(fileURLWithPath: inputPath)
guard let ciImage = CIImage(contentsOf: url) else {
    print("Error: Could not load image from \(inputPath)")
    exit(1)
}

let handler = VNImageRequestHandler(ciImage: ciImage)
let request = VNGenerateForegroundInstanceMaskRequest()

do {
    try handler.perform([request])
} catch {
    print("Error performing request: \(error)")
    exit(1)
}

guard let result = request.results?.first else {
    print("Error: No results from Vision request")
    exit(1)
}

do {
    let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
    let maskCI = CIImage(cvPixelBuffer: mask)

    let context = CIContext()

    // Use CIFilter with name instead of convenience method
    guard let blendFilter = CIFilter(name: "CIBlendWithMask") else {
        print("Error: Could not create blend filter")
        exit(1)
    }

    blendFilter.setValue(ciImage, forKey: kCIInputImageKey)
    blendFilter.setValue(maskCI, forKey: kCIInputMaskImageKey)
    blendFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)

    if let output = blendFilter.outputImage,
       let cgImage = context.createCGImage(output, from: output.extent) {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        if let tiff = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: outputPath))
            print("Success! Saved to \(outputPath)")
        }
    }
} catch {
    print("Error generating mask: \(error)")
    exit(1)
}
