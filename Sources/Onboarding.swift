import AppKit
import UserNotifications

/// Главный CTA онбординга. Нативный `NSButton` сохраняет Enter/VoiceOver,
/// а цвет берёт из Kelvin, а не из пользовательского системного accent macOS.
private final class OnboardingPrimaryButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.control
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = Design.Color.accent(dark).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Design.Color.accentBright(dark).withAlphaComponent(0.55).cgColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Design.Font.calloutEmph,
                .foregroundColor: dark ? Design.Color.accentInk(true) : NSColor.white,
            ]
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Welcome-экран при первом запуске: иконка, что умеет Kelvin, кнопка «Начать».
/// Показывается один раз (флаг в UserDefaults); живёт в стекле, как остальной UI.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: "onboarding.shown") }
    static func markShown() { UserDefaults.standard.set(true, forKey: "onboarding.shown") }

    // Ссылки на элементы секции «Разрешения» — по мере выдачи доступа кнопка сменяется зелёной галочкой.
    private var notifButton: GlassButton?
    private var notifStatus: NSStackView?
    private var axButton: GlassButton?
    private var axStatus: NSStackView?
    private var permTimer: Timer?

    private convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 780),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        buildContent()
    }

    // помечаем показанным при любом закрытии (крестик или «Начать»),
    // чтобы welcome не всплывал повторно. (pkill в скриншот-режиме сюда не доходит.)
    // + возврат в .accessory, если это было последнее окно Kelvin (см. WindowChrome).
    func windowWillClose(_ notification: Notification) {
        permTimer?.invalidate(); permTimer = nil
        OnboardingWindowController.markShown()
        WindowChrome.restoreAccessoryIfNoWindows(closing: window)
    }

    func present() {
        WindowChrome.becomeRegular()                // показать app-меню Kelvin вместо чужого
        window?.center()
        window?.level = .floating
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DispatchQueue.main.async { self.window?.level = .normal }
        startPermissionPolling()                    // отражаем текущий статус разрешений и следим за выдачей
    }

    /// Офскрин-снимок окна в PNG (BM_SNAP) — визуальный QA стартового окна, БЕЗ показа/TCC.
    func renderSnapshot(to dir: String, light: Bool) {
        guard let win = window, let root = win.contentView else { return }
        if light { win.appearance = NSAppearance(named: .aqua) }
        root.wantsLayer = true
        let appr = win.appearance ?? NSApp.effectiveAppearance
        appr.performAsCurrentDrawingAppearance {
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor   // офскрин материала нет — красим фон
        }
        root.layoutSubtreeIfNeeded()
        let r = root.bounds
        guard r.width > 1, r.height > 1, let rep = root.bitmapImageRepForCachingDisplay(in: r) else { return }
        root.cacheDisplay(in: r, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/Z_onboarding.png"))
        }
    }

    private func buildContent() {
        guard let win = window else { return }
        let bg = NSVisualEffectView()
        bg.material = .windowBackground; bg.blendingMode = .behindWindow; bg.state = .active

        let icon = NSImageView()
        if let p = Bundle.main.path(forResource: "AppIcon", ofType: "icns") { icon.image = NSImage(contentsOfFile: p) }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let title = NSTextField(labelWithString: L("Добро пожаловать в Kelvin"))
        title.font = Design.Font.title
        let sub = NSTextField(labelWithString: L("Мониторинг и управление вашим Mac — из строки меню"))
        sub.font = Design.Font.body; sub.textColor = .secondaryLabelColor

        let features = NSStackView(views: [
            feature("bolt.fill", Design.Color.accentAdaptive, L("Энергия и питание"),
                    L("Живая схема расхода, ватты, состояние батареи и лимит заряда.")),
            feature("thermometer.medium", Design.Color.accentAdaptive, L("Температуры и вентиляторы"),
                    L("Сенсоры всего железа и управление оборотами кулеров.")),
            feature("globe", Design.Color.accentAdaptive, L("Переключение языка"),
                    L("Авто-исправление раскладки и опечаток — как Punto, локально.")),
            feature("lock.shield.fill", Design.Color.accentAdaptive, L("Локально и безопасно"),
                    L("Всё считается на вашем Mac. Без телеметрии и облака.")),
        ])
        features.orientation = .vertical; features.alignment = .leading; features.spacing = 16

        // MARK: — секция «Разрешения» (кнопки реально запрашивают доступы)
        let permHeader = NSTextField(labelWithString: L("Разрешения"))
        permHeader.font = Design.Font.headline
        let permIntro = NSTextField(wrappingLabelWithString:
            L("Kelvin работает и без них — но с ними раскрывается полностью. Можно пропустить и включить позже в Настройках."))
        permIntro.font = Design.Font.caption; permIntro.textColor = .secondaryLabelColor
        permIntro.translatesAutoresizingMaskIntoConstraints = false
        permIntro.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let permHead = NSStackView(views: [permHeader, permIntro])
        permHead.orientation = .vertical; permHead.alignment = .leading; permHead.spacing = 4

        let (notifRow, nBtn, nStatus) = permissionRow(
            symbol: "bell.badge.fill", tint: Design.Color.accentAdaptive,
            title: L("Уведомления"),
            desc: L("Пороги температуры и заряда, новые сетевые подключения."),
            buttonTitle: L("Разрешить"), buttonSymbol: "bell.fill")
        nBtn.onClick = { [weak self] in
            AlertsEngine.shared.requestOrOpenSettings { [weak self] granted in
                guard let self, self.window?.isVisible == true else { return }
                self.setGranted(self.notifButton, self.notifStatus, granted)
            }
        }
        self.notifButton = nBtn; self.notifStatus = nStatus

        let (axRow, aBtn, aStatus) = permissionRow(
            symbol: "accessibility", tint: Design.Color.accentAdaptive,
            title: L("Доступ к системе"),
            desc: L("Переключение раскладки, сниппеты и горячие клавиши. Клавиши читаются только для автозамены — локально."),
            buttonTitle: L("Разрешить"), buttonSymbol: "hand.raised.fill")
        aBtn.onClick = { [weak self] in
            _ = LangSwitcher.shared.requestAccessibility()  // системная панель «Универсальный доступ»
            self?.startPermissionPolling()
        }
        self.axButton = aBtn; self.axStatus = aStatus

        let permSection = NSStackView(views: [permHead, notifRow, axRow])
        permSection.orientation = .vertical; permSection.alignment = .leading; permSection.spacing = 12

        let start = OnboardingPrimaryButton(title: L("Начать"), target: self, action: #selector(finish))
        start.keyEquivalent = "\r"
        start.translatesAutoresizingMaskIntoConstraints = false
        start.widthAnchor.constraint(equalToConstant: 200).isActive = true
        start.heightAnchor.constraint(equalToConstant: 38).isActive = true

        let note = NSTextField(labelWithString: L("Живёт в строке меню — без иконки в Dock"))
        note.font = Design.Font.caption; note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [icon, title, sub, features, permSection, start, note])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(24, after: sub)
        stack.setCustomSpacing(24, after: features)
        stack.setCustomSpacing(22, after: permSection)
        stack.setCustomSpacing(12, after: start)
        stack.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(stack)
        win.contentView = bg
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bg.centerXAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 44),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: bg.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: bg.trailingAnchor, constant: -36),
        ])
    }

    /// Строка-фича: цветная SF-иконка + заголовок + описание.
    private func feature(_ symbol: String, _ tint: NSColor, _ title: String, _ desc: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 30).isActive = true

        let t = NSTextField(labelWithString: title); t.font = Design.Font.calloutEmph
        let d = NSTextField(wrappingLabelWithString: desc)
        d.font = Design.Font.callout; d.textColor = .secondaryLabelColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 330).isActive = true

        let texts = NSStackView(views: [t, d]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 2
        let row = NSStackView(views: [icon, texts]); row.orientation = .horizontal; row.alignment = .top; row.spacing = 14
        return row
    }

    /// Строка секции «Разрешения»: цветная иконка + заголовок/описание + стеклянная кнопка «Разрешить».
    /// По выдаче доступа кнопка прячется, а на её место встаёт зелёная галочка «Разрешено» (см. setGranted).
    private func permissionRow(symbol: String, tint: NSColor, title: String, desc: String,
                               buttonTitle: String, buttonSymbol: String?)
        -> (row: NSView, button: GlassButton, status: NSStackView) {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let t = NSTextField(labelWithString: title); t.font = Design.Font.calloutEmph
        let d = NSTextField(wrappingLabelWithString: desc)
        d.font = Design.Font.caption; d.textColor = .secondaryLabelColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let texts = NSStackView(views: [t, d]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 2
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)   // тянется → кнопка прижата вправо

        let button = GlassButton(title: buttonTitle, symbol: buttonSymbol)

        let check = NSImageView()
        check.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        check.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        check.contentTintColor = .systemGreen
        let okLabel = NSTextField(labelWithString: L("Разрешено"))
        okLabel.font = Design.Font.callout; okLabel.textColor = .systemGreen
        let status = NSStackView(views: [check, okLabel])
        status.orientation = .horizontal; status.alignment = .centerY; status.spacing = 5
        status.isHidden = true                                          // до выдачи доступа видна кнопка

        let trailing = NSStackView(views: [button, status])
        trailing.orientation = .horizontal; trailing.alignment = .centerY; trailing.spacing = 0

        let row = NSStackView(views: [icon, texts, trailing])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12; row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return (row, button, status)
    }

    // MARK: — статус разрешений (пока окно открыто — следим за выдачей, кнопка → зелёная галочка)
    private func startPermissionPolling() {
        refreshPermissionStatus()
        guard permTimer == nil else { return }
        permTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshPermissionStatus()
        }
    }
    private func refreshPermissionStatus() {
        setGranted(axButton, axStatus, LangSwitcher.shared.isTrusted)       // Универсальный доступ — синхронно
        // Только кэш последнего явного выбора: getNotificationSettings на этом
        // экране приводил к SIGSEGV на старых macOS.
        let state = AlertsEngine.shared.authorizationState
        notifButton?.title = state == .denied ? L("Открыть настройки") : L("Разрешить")
        setGranted(notifButton, notifStatus, state.canPost)
    }
    private func setGranted(_ button: GlassButton?, _ status: NSStackView?, _ granted: Bool) {
        button?.isHidden = granted        // NSStackView сам исключает скрытые вьюхи из раскладки
        status?.isHidden = !granted
    }

    @objc private func finish() { window?.close() }   // markShown — в windowWillClose
}
