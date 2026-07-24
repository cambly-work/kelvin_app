import AppKit

/// Дизайн-кит окна настроек в стиле приложения (Control Center / стекло, как поповер): стеклянные карточки
/// ГИБКОЙ ширины (тянутся по окну), живые контролы (свитч/слайдер/сегмент/поп-ап) через замыкания, компактные
/// строки вместо простыней плоских чекбоксов. Заменяет старые groupBox/boxRow фикс-440. Декуплен от
/// SettingsWindowController (всё на closures), чтобы жить в своём файле.

// MARK: - Замыкание-контролы (NSSwitch/NSSlider/NSPopUpButton без target/action-церемоний)

final class KSwitch: NSSwitch {
    var onChange: ((Bool) -> Void)?
    init(on: Bool) {
        super.init(frame: .zero)
        state = on ? .on : .off
        target = self; action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { onChange?(state == .on) }
}

final class KSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    @objc private func fire() { onChange?(doubleValue) }
    static func make(min: Double, max: Double, value: Double, ticks: Int = 0, onChange: @escaping (Double) -> Void) -> KSlider {
        let s = KSlider()
        s.minValue = min; s.maxValue = max; s.doubleValue = value
        if ticks > 0 { s.numberOfTickMarks = ticks; s.allowsTickMarkValuesOnly = true }
        s.isContinuous = true
        s.target = s; s.action = #selector(fire)
        s.onChange = onChange
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
}

final class KPopup: NSPopUpButton {
    var onSelect: ((Int) -> Void)?
    @objc private func fire() { onSelect?(indexOfSelectedItem) }
    static func make(_ options: [String], selected: Int, onSelect: @escaping (Int) -> Void) -> KPopup {
        let p = KPopup(frame: .zero, pullsDown: false)
        p.addItems(withTitles: options)
        if options.indices.contains(selected) { p.selectItem(at: selected) }
        p.target = p; p.action = #selector(fire)
        p.onSelect = onSelect
        p.translatesAutoresizingMaskIntoConstraints = false
        return p
    }
}

// MARK: - Стеклянная карточка

/// Карточка настроек: матовое стекло + световая кромка + мягкая тень (liquid glass depth),
/// перекрашивается под тему. Ширина — гибкая (тянется).
final class SettingsCard: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = Design.Radius.group
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.backgroundColor = Design.Color.surfaceFill(dark).cgColor
        layer?.borderColor = Design.Color.surfaceRim(dark).cgColor
        // тень для depth-эффекта «плавающих» карточек на glass-поверхности
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dark ? 0.12 : 0.08
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }
}

/// Заголовок группы настроек — маркер-тип, чтобы `SK.scaffold` задал ему «прижатый» к карточке
/// ритм (больше воздуха сверху, теснее снизу), как в Системных настройках macOS.
final class SKGroupHeader: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false; isSelectable = false
        isBezeled = false; isBordered = false; drawsBackground = false
        font = Design.Font.calloutEmph
        textColor = .secondaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Фабрика (SK.card / SK.toggleRow / …)

enum SK {
    static let rowHeight: CGFloat = 44      // больше воздуха между контролами
    static let inset: CGFloat = 14

    /// Стеклянная карточка со строками, разделёнными волосяной линией. Тянется по ширине родителя.
    static func card(_ rows: [NSView]) -> SettingsCard {
        let card = SettingsCard()
        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let sep = NSBox(); sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(sep)
                sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
                sep.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
                sep.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            stack.addArrangedSubview(r)
            r.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            r.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    /// Каркас строки: [иконка] заголовок … контрол справа. Тянется по ширине, мин. высота rowHeight.
    private static func row(icon: String?, leading: NSView, trailing: NSView?, minHeight: CGFloat = rowHeight) -> NSView {
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        var items: [NSView] = []
        if let icon {
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            iv.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            iv.contentTintColor = .secondaryLabelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 20).isActive = true
            items.append(iv)
        }
        items.append(leading)
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        items.append(spacer)
        if let trailing { items.append(trailing) }
        let hs = NSStackView(views: items)
        hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 10
        hs.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(hs)
        NSLayoutConstraint.activate([
            hs.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: inset),
            hs.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -inset),
            hs.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        return wrap
    }

    /// Заголовок(+подзаголовок) для левой части строки.
    private static func titleBlock(_ title: String, _ subtitle: String?) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = Design.Font.body; t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        guard let subtitle, !subtitle.isEmpty else { return t }
        let s = NSTextField(labelWithString: subtitle)
        s.font = Design.Font.caption
        s.textColor = .secondaryLabelColor
        s.lineBreakMode = .byWordWrapping
        s.maximumNumberOfLines = 2
        s.cell?.wraps = true
        s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let v = NSStackView(views: [t, s])
        v.orientation = .vertical; v.alignment = .leading; v.spacing = 1
        return v
    }

    /// Строка-переключатель: иконка+заголовок(+подзаголовок) слева, живой свитч справа.
    static func toggleRow(icon: String? = nil, title: String, subtitle: String? = nil,
                          isOn: Bool, enabled: Bool = true, onChange: @escaping (Bool) -> Void) -> NSView {
        let sw = KSwitch(on: isOn); sw.onChange = onChange; sw.isEnabled = enabled
        let r = row(icon: icon, leading: titleBlock(title, subtitle), trailing: sw)
        r.alphaValue = enabled ? 1 : 0.5
        return r
    }

    /// Строка-слайдер: заголовок слева, слайдер тянется, значение справа.
    static func sliderRow(icon: String? = nil, title: String, min: Double, max: Double, value: Double,
                          ticks: Int = 0, unit: String = "", enabled: Bool = true,
                          onChange: @escaping (Double, NSTextField) -> Void) -> NSView {
        let valLabel = NSTextField(labelWithString: String(format: "%.0f%@", value, unit))
        valLabel.font = Design.Font.numericBody; valLabel.textColor = .secondaryLabelColor
        valLabel.alignment = .right; valLabel.translatesAutoresizingMaskIntoConstraints = false
        valLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let slider = KSlider.make(min: min, max: max, value: value, ticks: ticks) { v in onChange(v, valLabel) }
        slider.isEnabled = enabled
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        let t = NSTextField(labelWithString: title); t.font = Design.Font.body
        t.setContentCompressionResistancePriority(.required, for: .horizontal)
        t.setContentHuggingPriority(.required, for: .horizontal)
        let hs = NSStackView(views: [t, slider, valLabel])
        hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 12
        let r = row(icon: icon, leading: hs, trailing: nil)
        r.alphaValue = enabled ? 1 : 0.5
        return r
    }

    /// Строка-сегменты (2-5 вариантов): заголовок слева, пилюли справа (PillTabBar-стиль).
    static func segmentRow(icon: String? = nil, title: String, options: [String], selected: Int,
                           onSelect: @escaping (Int) -> Void) -> NSView {
        let bar = PillTabBar(labels: options, selected: selected)
        bar.onSelect = onSelect
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(options.count) * 62).isActive = true
        return row(icon: icon, leading: titleBlock(title, nil), trailing: bar)
    }

    /// Строка-поп-ап (длинный список): заголовок слева, NSPopUpButton справа.
    static func selectRow(icon: String? = nil, title: String, options: [String], selected: Int,
                          onSelect: @escaping (Int) -> Void) -> NSView {
        let p = KPopup.make(options, selected: selected, onSelect: onSelect)
        return row(icon: icon, leading: titleBlock(title, nil), trailing: p)
    }

    /// Строка с произвольным контролом справа (кнопка/поле/чип).
    static func controlRow(icon: String? = nil, title: String, subtitle: String? = nil, control: NSView) -> NSView {
        control.translatesAutoresizingMaskIntoConstraints = false
        return row(icon: icon, leading: titleBlock(title, subtitle), trailing: control)
    }

    /// Обернуть произвольный вид в строку карточки с инсетом (нестандартный контент: хедер, ряд кнопок, кредиты).
    /// fill: true — контент тянется на всю ширину строки (единая правая кромка со всеми карточками);
    /// false (по умолч.) — жмётся к содержимому (для одиночных контролов, которым растяжка не нужна).
    static func customRow(_ view: NSView, minHeight: CGFloat = rowHeight, fill: Bool = false) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        let trailing = fill
            ? view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -inset)
            : view.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -inset)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: inset),
            trailing,
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
            wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        return wrap
    }

    /// Строка с текстовым полем во всю ширину (плейсхолдер как подпись). Поле тянется по строке.
    static func textFieldRow(icon: String? = nil, field: NSTextField, placeholder: String? = nil) -> NSView {
        if let placeholder { field.placeholderString = placeholder }
        field.font = Design.Font.body
        field.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        var lead: CGFloat = inset
        if let icon {
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            iv.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            iv.contentTintColor = .secondaryLabelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(iv)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: inset),
                iv.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 20),
            ])
            lead = inset + 20 + 10
        }
        wrap.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: lead),
            field.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -inset),
            field.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight),
        ])
        return wrap
    }

    /// Вид во всю ширину карточки с инсетом и по вертикали (для многострочных редакторов: NSScrollView/NSTextView).
    static func stretchRow(_ view: NSView, height: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 10),
            view.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -10),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
        return wrap
    }

    /// Информационная строка: иконка + текст (может переноситься), тон по смыслу.
    static func infoRow(icon: String, text: String, tint: NSColor = .secondaryLabelColor) -> NSView {
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iv.contentTintColor = tint
        iv.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = Design.Font.caption; l.textColor = tint
        let hs = NSStackView(views: [iv, l])
        hs.orientation = .horizontal; hs.alignment = .top; hs.spacing = 8
        let r = row(icon: nil, leading: hs, trailing: nil, minHeight: 38)
        return r
    }

    /// Строка с цветным бейджем справа: иконка + заголовок, бейдж (фоновая плашка + текст) прижат вправо.
    /// Используется для статусов: «Активен», «Отключено», «Pro» и т.д.
    static func badgeRow(icon: String? = nil, title: String, badgeText: String, badgeColor: NSColor = .secondaryLabelColor) -> NSView {
        let badge = NSTextField(labelWithString: badgeText)
        badge.font = Design.Font.caption; badge.textColor = badgeColor
        badge.alignment = .center; badge.translatesAutoresizingMaskIntoConstraints = false
        let badgeWrap = BadgePillView()
        badgeWrap.translatesAutoresizingMaskIntoConstraints = false
        badgeWrap.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: badgeWrap.leadingAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: badgeWrap.trailingAnchor, constant: -8),
            badge.topAnchor.constraint(equalTo: badgeWrap.topAnchor, constant: 4),
            badge.bottomAnchor.constraint(equalTo: badgeWrap.bottomAnchor, constant: -4),
        ])
        return row(icon: icon, leading: titleBlock(title, nil), trailing: badgeWrap)
    }

    /// Строка-ридаут: иконка + крупное моноширинное значение + подпись. Для зарядов, температур, процентов.
    static func readoutRow(icon: String, value: String, caption: String? = nil) -> NSView {
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        iv.contentTintColor = .secondaryLabelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 26).isActive = true
        let val = NSTextField(labelWithString: value)
        val.font = Design.Font.numericLarge; val.textColor = .labelColor
        let cap = NSTextField(labelWithString: caption ?? "")
        cap.font = Design.Font.caption; cap.textColor = .secondaryLabelColor
        let valCol = NSStackView(views: [val, cap]); valCol.orientation = .vertical; valCol.alignment = .leading; valCol.spacing = 0
        let hs = NSStackView(views: [iv, valCol]); hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 10
        return customRow(hs, minHeight: 52)
    }

    /// Навигационная строка: иконка + заголовок(+подзаголовок) + чеврон справа. Клик → onClick.
    static func linkRow(icon: String? = nil, title: String, subtitle: String? = nil,
                        onClick: @escaping () -> Void) -> NSView {
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let r = row(icon: icon, leading: titleBlock(title, subtitle), trailing: chevron)
        let catcher = ClickCatcher()
        catcher.translatesAutoresizingMaskIntoConstraints = false
        r.addSubview(catcher)
        NSLayoutConstraint.activate([
            catcher.leadingAnchor.constraint(equalTo: r.leadingAnchor),
            catcher.trailingAnchor.constraint(equalTo: r.trailingAnchor),
            catcher.topAnchor.constraint(equalTo: r.topAnchor),
            catcher.bottomAnchor.constraint(equalTo: r.bottomAnchor),
        ])
        catcher.onClick = onClick
        return r
    }

    /// Раскрывающаяся группа «Расширенно»: заголовок-кнопка со стрелкой прячет/показывает контент.
    /// Само-содержится (без пересборки секции) — переключает isHidden контента в стеке.
    /// Запомненное состояние раскрытий (ключ = заголовок): чтобы пересборка секции от тумблера
    /// не схлопывала открытый блок обратно. Живёт на время сессии.
    static var disclosureState: [String: Bool] = [:]

    static func disclosure(title: String, expanded: Bool = false, rows: [NSView]) -> NSView {
        let key = title
        let isOpen = disclosureState[key] ?? expanded
        let content = NSStackView(views: rows)
        content.orientation = .vertical; content.alignment = .width; content.spacing = 8
        content.isHidden = !isOpen
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .secondaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let lbl = NSTextField(labelWithString: title); lbl.font = Design.Font.calloutEmph; lbl.textColor = .secondaryLabelColor
        let head = NSStackView(views: [chevron, lbl])
        head.orientation = .horizontal; head.alignment = .centerY; head.spacing = 6
        let btn = ClickCatcher()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.addSubview(head)
        head.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: btn.leadingAnchor),
            head.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            btn.heightAnchor.constraint(equalToConstant: 28),
        ])
        btn.onClick = { [weak content, weak chevron] in
            guard let content, let chevron else { return }
            let show = content.isHidden
            content.isHidden = !show
            chevron.image = NSImage(systemSymbolName: show ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
            SK.disclosureState[key] = show
        }
        let v = NSStackView(views: [btn, content])
        v.orientation = .vertical; v.alignment = .width; v.spacing = 8
        return v
    }

    /// Каркас секции: заголовок(+подзаголовок) + карточки, во всю ГИБКУЮ ширину контента.
    static func scaffold(_ title: String, _ subtitle: String? = nil, _ items: [NSView]) -> NSView {
        let head = NSTextField(labelWithString: title); head.font = Design.Font.title
        var views: [NSView] = [head]
        var subtitleLabel: NSTextField?
        if let subtitle, !subtitle.isEmpty {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = Design.Font.caption; s.textColor = .secondaryLabelColor
            subtitleLabel = s
            views.append(s)
        }
        views.append(contentsOf: items)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Всё тянется во всю ширину стека, КРОМЕ заголовков групп (SKGroupHeader сидит слева).
        for v in views where !(v is SKGroupHeader) {
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        // Ритм как в Системных настройках macOS: подзаголовок прижат к заголовку раздела; заголовок
        // группы «сидит» на своей карточке — воздух над ним, теснее под ним.
        if let subtitleLabel {
            stack.setCustomSpacing(6, after: head)                     // 6pt: подзаголовок под титулом
            stack.setCustomSpacing(Design.Space.s5, after: subtitleLabel) // 20pt: воздух перед 1-й группой
        }
        for (i, v) in views.enumerated() where i > 0 && v is SKGroupHeader {
            stack.setCustomSpacing(Design.Space.s5, after: views[i - 1]) // 20pt перед заголовком группы
            stack.setCustomSpacing(8, after: v)                          // 8pt: прижать карточку к нему
        }
        return stack
    }
}

/// Стеклянная плашка-бейдж для SK.badgeRow: controlFill + surfaceRim, тема-зависимая.
private final class BadgePillView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = Design.Radius.chip; layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = Design.Color.controlFill(dark).cgColor
        layer?.borderColor = Design.Color.surfaceRim(dark).cgColor
    }
}

/// Прозрачная кликабельная область (для disclosure-заголовка).
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
