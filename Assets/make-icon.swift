import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let bg = NSBezierPath(roundedRect: NSRect(x: 45, y: 45, width: 934, height: 934), xRadius: 210, yRadius: 210)
NSColor(calibratedRed: 0.06, green: 0.12, blue: 0.18, alpha: 1).setFill(); bg.fill()
let ring = NSBezierPath(ovalIn: NSRect(x: 220, y: 220, width: 584, height: 584))
NSColor(calibratedRed: 0.15, green: 0.30, blue: 0.35, alpha: 1).setStroke(); ring.lineWidth = 28; ring.stroke()
let line = NSBezierPath(); line.move(to: NSPoint(x: 165, y: 510))
for (x,y) in [(320,510),(402,683),(493,336),(589,601),(665,510),(856,510)] { line.line(to: NSPoint(x: x, y: y)) }
line.lineWidth = 48; line.lineCapStyle = .round; line.lineJoinStyle = .round
NSColor(calibratedRed: 0.24, green: 0.87, blue: 0.75, alpha: 1).setStroke(); line.stroke()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
