import AppKit
// Renders the FoamMaster app icon (1024 px) to the path given as argument.
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 80, y: 80, width: size - 160, height: size - 160)
let path = NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190)
NSGradient(colors: [NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.14, alpha: 1),
                    NSColor(calibratedRed: 0.16, green: 0.09, blue: 0.32, alpha: 1)])!.draw(in: path, angle: -90)
NSGraphicsContext.current?.saveGraphicsState()
path.addClip()
NSGradient(colors: [NSColor(calibratedRed: 0.25, green: 0.78, blue: 1, alpha: 0.55), .clear])!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 60, y: 420, width: 700, height: 700)), relativeCenterPosition: .zero)
// Flying wing planform
let wing = NSBezierPath()
wing.move(to: NSPoint(x: 512, y: 760))
wing.line(to: NSPoint(x: 860, y: 420)); wing.line(to: NSPoint(x: 840, y: 340))
wing.line(to: NSPoint(x: 512, y: 520)); wing.line(to: NSPoint(x: 184, y: 340)); wing.line(to: NSPoint(x: 164, y: 420))
wing.close()
NSGradient(colors: [NSColor(calibratedRed: 0.3, green: 0.85, blue: 1, alpha: 1), NSColor(calibratedRed: 0.6, green: 0.45, blue: 1, alpha: 1)])!.draw(in: wing, angle: -60)
let elevons = NSBezierPath()
elevons.move(to: NSPoint(x: 600, y: 470)); elevons.line(to: NSPoint(x: 840, y: 340)); elevons.line(to: NSPoint(x: 852, y: 388)); elevons.line(to: NSPoint(x: 620, y: 515)); elevons.close()
elevons.move(to: NSPoint(x: 424, y: 470)); elevons.line(to: NSPoint(x: 184, y: 340)); elevons.line(to: NSPoint(x: 172, y: 388)); elevons.line(to: NSPoint(x: 404, y: 515)); elevons.close()
NSColor(calibratedRed: 1, green: 0.55, blue: 0.2, alpha: 1).setFill(); elevons.fill()
// Plan grid lines
NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
for i in stride(from: 140.0, to: 900, by: 64) {
    let l = NSBezierPath(); l.move(to: NSPoint(x: i, y: 80)); l.line(to: NSPoint(x: i, y: 944)); l.lineWidth = 2; l.stroke()
}
NSGraphicsContext.current?.restoreGraphicsState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
