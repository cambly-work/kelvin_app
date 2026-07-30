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
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: L("Исправлено"))
    private let correctedLabel = NSTextField(labelWithString: "")
    private let originalLabel = NSTextField(labelWithString: "")
    private let restoreButton = GlassButton(title: "", symbol: "arrow.uturn.backward", accentText: true)
    private let closeButton = GlassButton(title: "", symbol: "xmark")
    private var hideWork: DispatchWorkItem?
    private var correctionID: UUID?

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
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

        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        statusIcon.contentTintColor = Design.Color.accentAdaptive
        statusIcon.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Design.Font.microStat
        statusLabel.textColor = .secondaryLabelColor

        correctedLabel.font = Design.Font.calloutEmph
        correctedLabel.textColor = .labelColor
        correctedLabel.lineBreakMode = .byTruncatingMiddle
        originalLabel.font = Design.Font.callout
        originalLabel.textColor = .tertiaryLabelColor
        originalLabel.lineBreakMode = .byTruncatingMiddle

        let arrow = NSTextField(labelWithString: "→")
        arrow.font = Design.Font.callout
        arrow.textColor = .tertiaryLabelColor
        // Нативное направление чтения: было → стало. Исходное слово тихое и зачёркнуто,
        // исправленное — единственный акцент.
        let words = NSStackView(views: [originalLabel, arrow, correctedLabel])
        words.orientation = .horizontal
        words.alignment = .centerY
        words.spacing = 5
        let caption = NSStackView(views: [statusLabel, words])
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = 1

        restoreButton.onClick = { [weak self] in
            guard let self, let id = self.correctionID else { return }
            self.dismiss()
            LangSwitcher.shared.undoLastSpellCorrection(id: id)
        }
        closeButton.onClick = { [weak self] in
            guard let self, let id = self.correctionID else { return }
            self.dismiss()
            LangSwitcher.shared.acceptLastSpellCorrection(id: id)
        }
        // Accessibility: the close button needs a label since title is ""
        closeButton.setAccessibilityLabel(L("Закрыть"))
        restoreButton.setAccessibilityLabel(L("Вернуть"))
        restoreButton.toolTip = L("Вернуть")
        closeButton.toolTip = L("Оставить исправление")

        let row = NSStackView(views: [statusIcon, caption, NSView(), restoreButton, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

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
            row.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 18),
            restoreButton.widthAnchor.constraint(equalToConstant: 30),
            restoreButton.heightAnchor.constraint(equalToConstant: 30),
            closeButton.widthAnchor.constraint(equalToConstant: 26),
            closeButton.heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    func show(original: String, corrected: String, id: UUID) {
        correctionID = id
        correctedLabel.stringValue = corrected
        originalLabel.attributedStringValue = NSAttributedString(
            string: original,
            attributes: [
                .foregroundColor: NSColor.tertiaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
        )

        let wordsWidth = min(
            220,
            correctedLabel.intrinsicContentSize.width
                + originalLabel.intrinsicContentSize.width + 22
        )
        let width = max(270, min(430, wordsWidth + 122))
        let size = NSSize(width: width, height: 60)
        let origin = positionForHUD()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(origin) }) ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        var x = origin.x - size.width / 2
        var y = origin.y - size.height - 12
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        if y < visible.minY + 8 { y = origin.y + 24 }
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)

        hideWork?.cancel()
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        // Таймер = неявное «Оставить» — принимает исправление.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let id = self.correctionID else { return }
            self.dismiss()
            LangSwitcher.shared.acceptLastSpellCorrection(id: id)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
    }

    /// Офскрин-снимок состояния исправления для визуального QA.
    @discardableResult
    func renderSnapshot(to directory: String, light: Bool) -> Bool {
        show(original: "превет", corrected: "привет", id: UUID())
        if light { panel.appearance = NSAppearance(named: .aqua) }
        guard let view = panel.contentView else { dismiss(); return false }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            dismiss(); return false
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])
        dismiss()
        guard let data else { return false }
        return (try? data.write(to: URL(fileURLWithPath: directory + "/Z_correction_hud.png"))) != nil
    }

    private func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        correctionID = nil
        panel.orderOut(nil)
    }

    // MARK: - Позиционирование

    /// Возвращает экранную точку под кареткой для позиционирования HUD.
    /// При неподдерживаемом редакторе (AX возвращает nil) безопасно привязывается
    /// к верхней части активного экрана, а не к курсору мыши.
    private func positionForHUD() -> NSPoint {
        if let rect = caretRect() {
            return NSPoint(x: rect.midX, y: rect.minY)
        }
        // Fallback: верхняя часть активного экрана, а не курсор мыши.
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let s = screen else { return NSEvent.mouseLocation }
        return NSPoint(x: s.visibleFrame.midX, y: s.visibleFrame.maxY - 40)
    }

    /// Возвращает прямоугольник каретки focused AX-текстового элемента в
    /// AppKit-координатах (bottom-left origin). При ошибке AX — nil.
    private func caretRect() -> CGRect? {
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

        // Accessibility использует начало координат сверху левого угла основного
        // дисплея. AppKit использует bottom-left. Конвертируем, учитывая
        // конкретный экран, а не только основной, для корректной работы с
        // несколькими мониторами.
        let midX = rect.midX
        let axTop = rect.maxY
        // Найти экран, содержащий эту точку
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: midX, y: axTop - 1)) }) {
            return CGRect(x: rect.minX, y: screen.frame.maxY - axTop, width: rect.width, height: rect.height)
        }
        // Fallback: использовать основной экран
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primaryTop - axTop, width: rect.width, height: rect.height)
    }
}
