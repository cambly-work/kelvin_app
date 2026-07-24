import AppKit
import ApplicationServices

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

/// Ненавязчивое предложение у только что исправленного слова. Панель не
/// активирует Kelvin и поэтому не отнимает фокус у редактора/браузера.
final class CorrectionChoiceHUD {
    static let shared = CorrectionChoiceHUD()

    private let panel: NSPanel
    private let correctedLabel = NSTextField(labelWithString: "")
    private let originalLabel = NSTextField(labelWithString: "")
    private let keepButton = GlassButton(title: L("Оставить"), symbol: "checkmark")
    private let restoreButton = GlassButton(title: L("Вернуть"), symbol: "arrow.uturn.backward")
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 82),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 13
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false

        correctedLabel.font = Design.Font.calloutEmph
        correctedLabel.textColor = .labelColor
        correctedLabel.lineBreakMode = .byTruncatingMiddle
        originalLabel.font = Design.Font.callout
        originalLabel.textColor = .secondaryLabelColor
        originalLabel.lineBreakMode = .byTruncatingMiddle

        let arrow = NSTextField(labelWithString: "→")
        arrow.font = Design.Font.callout
        arrow.textColor = .tertiaryLabelColor
        let words = NSStackView(views: [correctedLabel, arrow, originalLabel])
        words.orientation = .horizontal
        words.alignment = .centerY
        words.spacing = 6

        keepButton.onClick = { [weak self] in
            self?.dismiss()
            LangSwitcher.shared.acceptLastSpellCorrection()
        }
        restoreButton.onClick = { [weak self] in
            self?.dismiss()
            LangSwitcher.shared.undoLastSpellCorrection()
        }
        let actions = NSStackView(views: [keepButton, restoreButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 7

        let row = NSStackView(views: [words, NSView(), actions])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(blur)
        blur.addSubview(row)
        panel.contentView = root
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            blur.topAnchor.constraint(equalTo: root.topAnchor),
            blur.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            keepButton.heightAnchor.constraint(equalToConstant: 32),
            restoreButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func show(original: String, corrected: String) {
        correctedLabel.stringValue = corrected
        originalLabel.stringValue = original

        let wordsWidth = min(
            190,
            correctedLabel.intrinsicContentSize.width
                + originalLabel.intrinsicContentSize.width + 22
        )
        let width = max(300, min(460, wordsWidth + 210))
        let size = NSSize(width: width, height: 58)
        let anchor = caretAnchor() ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        var x = anchor.x - 16
        var y = anchor.y - size.height - 10
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        if y < visible.minY + 8 { y = anchor.y + 22 }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        hideWork?.cancel()
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    private func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        panel.orderOut(nil)
    }

    /// Возвращает экранную точку каретки focused AX-текстового элемента.
    /// При неподдерживаемом редакторе show() безопасно привязывается к курсору.
    private func caretAnchor() -> NSPoint? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selected
        ) == .success,
              let selected,
              CFGetTypeID(selected) == AXValueGetTypeID()
        else { return nil }
        let rangeValue = unsafeBitCast(selected, to: AXValue.self)

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }
        let boundsAX = unsafeBitCast(boundsValue, to: AXValue.self)
        var rect = CGRect.zero
        guard AXValueGetValue(boundsAX, .cgRect, &rect) else { return nil }

        // Accessibility использует начало координат сверху основного дисплея,
        // AppKit — снизу. X уже находится в глобальном пространстве.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSPoint(x: rect.minX, y: primaryTop - rect.maxY)
    }
}
