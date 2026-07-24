import AppKit

/// Лёгкий всплывающий индикатор (как системный HUD смены раскладки): иконка + текст,
/// мягко появляется в верхней части экрана и гаснет. Для подсказки об автозамене языка/опечатки.
final class FeedbackHUD {
    static let shared = FeedbackHUD()

    private var panel: NSPanel?
    private let blur = NSVisualEffectView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private init() { setup() }

    private func setup() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.wantsLayer = true
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        label.font = Design.Font.headline
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal; stack.spacing = 9; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        let cv = NSView()
        cv.addSubview(blur); blur.addSubview(stack)
        p.contentView = cv
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            blur.topAnchor.constraint(equalTo: cv.topAnchor),
            blur.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        panel = p
    }

    func show(symbol: String, text: String, tint: NSColor) {
        guard let p = panel else { return }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        label.stringValue = text

        // размер под текст и позиция в верхней трети активного экрана
        let textW = label.intrinsicContentSize.width
        let w = max(132, textW + 22 + 9 + 40)
        let size = NSSize(width: w, height: 58)
        let scr = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let s = scr else { return }
        let x = s.frame.midX - size.width / 2
        let y = s.frame.minY + s.frame.height * 0.74
        let targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        hideWork?.cancel()
        let reduce = Motion.reduced   // «Уменьшить движение» — HUD остаётся функциональным, но появляется/гаснет мгновенно (без фейда)
        let animated = !reduce && SettingsStore.langFeedbackStyle != "compact"
        p.setFrame(animated ? targetFrame.offsetBy(dx: 0, dy: -10) : targetFrame, display: true)
        p.alphaValue = animated ? 0 : 1
        p.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
                p.animator().setFrame(targetFrame, display: true)
            }
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [0.82, 1.08, 1.0]
            pulse.keyTimes = [0, 0.62, 1]
            pulse.duration = 0.24
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            icon.layer?.add(pulse, forKey: "feedbackPulse")
        }
        let work = DispatchWorkItem { [weak p] in
            guard let p = p else { return }
            if !animated { p.orderOut(nil); return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }
}
