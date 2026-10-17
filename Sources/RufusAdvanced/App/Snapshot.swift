import AppKit
import SwiftUI
import BootKit

/// Developer aid: `RUFUSADV_SNAPSHOT=/path/shot.png RufusAdvanced.app/Contents/MacOS/RufusAdvanced`
/// renders the main window to a PNG (no screen recording permission needed) and quits.
/// `RUFUSADV_SNAPSHOT_IMAGE=/path/to.iso` pre-selects an image first.
enum Snapshot {
    @MainActor
    static func scheduleIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["RUFUSADV_SNAPSHOT"] else { return }
        if let img = env["RUFUSADV_SNAPSHOT_IMAGE"] { model.selectImage(path: img) }
        if env["RUFUSADV_SNAPSHOT_EXPAND"] != nil {
            AppSettings.shared.showAdvancedDrive = true
            AppSettings.shared.showAdvancedFormat = true
        }
        let delay = Double(env["RUFUSADV_SNAPSHOT_DELAY"] ?? "4") ?? 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let title = env["RUFUSADV_SNAPSHOT_WINDOW"]
            let windows = NSApp.windows.filter { $0.isVisible }
            guard let w = title.flatMap({ t in windows.first { $0.title == t } }) ?? windows.first,
                  let frameView = w.contentView?.superview else { NSApp.terminate(nil); return }
            if env["RUFUSADV_SNAPSHOT_VIEW"] == "macassistant" {
                let content = MacInstallerAssistantSheet(assistant: model.macInstallers).environmentObject(model)
                    .background(Color(nsColor: .windowBackgroundColor))
                let r = ImageRenderer(content: content)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
            } else if env["RUFUSADV_SNAPSHOT_SWIFTUI"] != nil {
                let content = VStack(alignment: .leading, spacing: 16) {
                    DriveSection(); BootSection()
                    if !model.layoutLocked { PropertiesSection(); FormatSection() } else { LockedLayoutNote() }
                    StatusBar()
                }
                .padding(18).frame(width: 600).environmentObject(model)
                .background(Color(nsColor: .windowBackgroundColor))
                let r = ImageRenderer(content: content)
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
            } else {
                write(frameView, to: out)
            }
            if env["RUFUSADV_SNAPSHOT_KEEP"] == nil { NSApp.terminate(nil) }
        }
    }

    static func write(_ view: NSView, to path: String) {
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let layer = view.layer,
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if !view.isFlipped {
            // layer coordinates are bottom-left already
        }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
