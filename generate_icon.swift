import Cocoa
import Foundation

func createIcon() {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size)
    
    image.lockFocus()
    defer { image.unlockFocus() }
    guard let context = NSGraphicsContext.current?.cgContext else {
        fputs("Unable to create drawing context.\n", stderr)
        return
    }
    
    // Setup standard macOS squircle path
    let rect = NSRect(origin: .zero, size: size).insetBy(dx: 50, dy: 50)
    let cornerRadius: CGFloat = 210
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    
    // 1. Base Vibrant Gradient (Liquid/Glassy foundation)
    context.saveGState()
    path.addClip()
    
    // Bright, vibrant cyan to deep purple/magenta
    let baseColors = [
        NSColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0).cgColor,
        NSColor(red: 0.5, green: 0.2, blue: 0.9, alpha: 1.0).cgColor
    ] as CFArray
    guard let baseGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: baseColors, locations: [0.0, 1.0]) else {
        fputs("Unable to create base gradient.\n", stderr)
        return
    }
    // Angled gradient for dynamic light
    context.drawLinearGradient(baseGradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
    context.restoreGState()
    
    // 2. Liquid Glass Highlight (Top diagonal reflection)
    context.saveGState()
    path.addClip()
    
    let highlightPath = NSBezierPath()
    highlightPath.move(to: NSPoint(x: 0, y: 1024))
    highlightPath.line(to: NSPoint(x: 1024, y: 1024))
    highlightPath.line(to: NSPoint(x: 1024, y: 400))
    // Create a smooth swooping curve across the icon
    highlightPath.curve(to: NSPoint(x: 0, y: 700), controlPoint1: NSPoint(x: 600, y: 600), controlPoint2: NSPoint(x: 300, y: 800))
    highlightPath.close()
    highlightPath.addClip()
    
    let highlightColors = [
        NSColor.white.withAlphaComponent(0.45).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    guard let highlightGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: highlightColors, locations: [0.0, 1.0]) else {
        fputs("Unable to create highlight gradient.\n", stderr)
        return
    }
    context.drawLinearGradient(highlightGradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 400), options: [])
    context.restoreGState()

    // 3. Inner glass bezel (3D edge thickness)
    context.saveGState()
    path.lineWidth = 14
    NSColor.white.withAlphaComponent(0.5).setStroke()
    path.stroke()
    context.restoreGState()

    // 4. Draw Symbol (moon.stars.fill)
    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .bold)
    guard let symbol = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
        fputs("Unable to create SF Symbol image.\n", stderr)
        return
    }

    context.saveGState()

    // Deep drop shadow for floating 3D effect inside the glass
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -20)
    shadow.shadowBlurRadius = 30
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
    shadow.set()

    // Add a subtle white inner glow to the symbol itself to make it pop against the background
    context.setShadow(offset: .zero, blur: 40, color: NSColor.white.withAlphaComponent(0.8).cgColor)

    let symbolSize = NSSize(width: 600, height: 600)
    let symbolRect = NSRect(x: (size.width - symbolSize.width) / 2,
                            y: (size.height - symbolSize.height) / 2 - 20,
                            width: symbolSize.width,
                            height: symbolSize.height)

    // Draw the symbol white
    let renderedSymbol = symbol
    renderedSymbol.isTemplate = true
    NSColor.white.set()
    renderedSymbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    context.restoreGState()
    
    // 5. Save as PNG
    if let tiffData = image.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiffData),
       let pngData = bitmap.representation(using: .png, properties: [:]) {
        try? pngData.write(to: URL(fileURLWithPath: "icon_raw.png"))
    } else {
        fputs("Unable to write PNG output.\n", stderr)
    }
}

createIcon()
