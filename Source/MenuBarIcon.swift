import Cocoa

enum MenuBarIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: false) { bounds in
            let mark = NSAttributedString(string: "а/я", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.black
            ])
            let size = mark.size()
            mark.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: (bounds.height - size.height) / 2))
            return true
        }
        // macOS supplies black or white to match the menu bar and its highlight.
        image.isTemplate = true
        return image
    }
}
