import AppKit

/// Final-size SVG rasterizations share the previous crop, visible size and 21×22pt status-item footprint.
/// Explicit 1x/2x representations avoid resampling the antialiased 128px intermediates at runtime.
struct MenuBarIconImages {
    static let badgeRadius: CGFloat = 3.63
    let size = NSSize(width: 21, height: 22)
    // Frozen geometry from Scripts/menubar-icons.swift (the original shared alpha crop).
    let bodyRect = CGRect(x: 0.3853211009174312, y: 4.824561403508772,
                          width: 19.26605504587156, height: 12.350877192982455)
    let badgeCenter = CGPoint(x: 17.17, y: 6.276561403508772)
    private let idle: NSImage
    private let restoring: NSImage
    private let notReady: NSImage

    func image(for frame: MenuBarIconFrame) -> NSImage {
        switch frame {
        case .idle: idle
        case .restoring: restoring
        case .notReady: notReady
        }
    }

    /// Missing either backing scale of any frame fails as a unit; caller retains its existing fallback.
    static func make(bundle: Bundle = .main) -> MenuBarIconImages? {
        func image(_ art: BrandAssets.MenuBarArt, description: String) -> NSImage? {
            let image = NSImage(size: NSSize(width: 21, height: 22))
            for scale in [1, 2] {
                guard let rep = BrandAssets.menuBarRepresentation(art, scale: scale, bundle: bundle),
                      rep.pixelsWide == 21 * scale, rep.pixelsHigh == 22 * scale, rep.hasAlpha else { return nil }
                rep.size = image.size
                image.addRepresentation(rep)
            }
            image.isTemplate = true
            image.accessibilityDescription = description
            return image
        }
        guard let idle = image(.idle, description: "Winductor"),
              let restoring = image(.restoring, description: "Winductor（恢复中）"),
              let notReady = image(.notReady, description: "Winductor（未就绪）") else { return nil }
        return MenuBarIconImages(idle: idle, restoring: restoring, notReady: notReady)
    }
}
