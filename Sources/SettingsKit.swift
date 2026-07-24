import AppKit

/// Лёгкий набор компонентов для окна настроек Kelvin.
///
/// Принципы:
/// - спокойный нативный вид вместо многослойного glassmorphism;
/// - минимум промежуточных NSStackView и обязательных constraints;
/// - адаптивная ширина без фиксированных 420/440 pt;
/// - замыкания вместо разросшегося target/action-кода;
/// - disclosure не требует пересборки всей секции;
/// - слайдеры объединяют слишком частые события, не забивая главный поток.

// MARK: - Closure controls

final class KSwitch: NSSwitch {
    var onChange: ((Bool) -> Void)?

    init(on: Bool) {
        super.init(frame: .zero)
        state = on ? .on : .off
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        onChange?(state == .on)
    }
}

/// Continuous-слайдер с coalescing событий. AppKit может присылать намного больше
/// событий, чем нужно интерфейсу; ограничение примерно до 30 Гц оставляет движение
/// плавным, но не запускает запись файлов/SMC/NotificationCenter сотни раз в секунду.
final class KSlider: NSSlider {
    var onChange: ((Double) -> Void)?
    var minimumCallbackInterval: TimeInterval = 1.0 / 30.0

    private var lastCallbackUptime: TimeInterval = 0
    private var pendingWork: DispatchWorkItem?
    private var pendingValue: Double?

    @objc private func fire() {
        emitOrSchedule(doubleValue)
    }

    private func emitOrSchedule(_ value: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastCallbackUptime

        if elapsed >= minimumCallbackInterval {
            pendingWork?.cancel()
            pendingWork = nil
            pendingValue = nil
            lastCallbackUptime = now
            onChange?(value)
            return
        }

        pendingValue = value
        pendingWork?.cancel()
        let delay = max(0, minimumCallbackInterval - elapsed)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let value = self.pendingValue else { return }
            self.pendingValue = nil
            self.pendingWork = nil
            self.lastCallbackUptime = ProcessInfo.processInfo.systemUptime
            self.onChange?(value)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func flushPendingValue() {
        pendingWork?.cancel()
        pendingWork = nil
        guard let value = pendingValue else { return }
        pendingValue = nil
        lastCallbackUptime = ProcessInfo.processInfo.systemUptime
        onChange?(value)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        flushPendingValue()
    }

    deinit {
        pendingWork?.cancel()
    }

    static func make(min: Double,
                     max: Double,
                     value: Double,
                     ticks: Int = 0,
                     onChange: @escaping (Double) -> Void) -> KSlider {
        let slider = KSlider()
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = Swift.max(min, Swift.min(max, value))
        slider.numberOfTickMarks = Swift.max(0, ticks)
        slider.allowsTickMarkValuesOnly = ticks > 0
        slider.isContinuous = true
        slider.target = slider
        slider.action = #selector(fire)
        slider.onChange = onChange
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }
}

final class KPopup: NSPopUpButton {
    var onSelect: ((Int) -> Void)?

    @objc private func fire() {
        onSelect?(indexOfSelectedItem)
    }

    static func make(_ options: [String],
                     selected: Int,
                     onSelect: @escaping (Int) -> Void) -> KPopup {
        let popup = KPopup(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.addItems(withTitles: options)
        if !options.isEmpty {
            popup.selectItem(at: Swift.max(0, Swift.min(options.count - 1, selected)))
        }
        popup.target = popup
        popup.action = #selector(fire)
        popup.onSelect = onSelect
        popup.translatesAutoresizingMaskIntoConstraints = false
        return popup
    }
}

private final class KSegment: NSSegmentedControl {
    var onSelect: ((Int) -> Void)?

    @objc private func fire() {
        guard selectedSegment >= 0 else { return }
        onSelect?(selectedSegment)
    }

    static func make(_ options: [String],
                     selected: Int,
                     onSelect: @escaping (Int) -> Void) -> KSegment {
        let control = KSegment(labels: options,
                               trackingMode: .selectOne,
                               target: nil,
                               action: nil)
        control.controlSize = .small
        control.segmentStyle = .automatic
        control.target = control
        control.action = #selector(fire)
        control.onSelect = onSelect
        control.translatesAutoresizingMaskIntoConstraints = false
        if !options.isEmpty {
            control.selectedSegment = Swift.max(0, Swift.min(options.count - 1, selected))
        }
        return control
    }
}

private final class KActionButton: NSButton {
    var onClick: (() -> Void)?

    init(title: String = "") {
        super.init(frame: .zero)
        self.title = title
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func fire() {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }
}

// MARK: - Surfaces

/// Одна спокойная поверхность группы. Без дорогой тени и без ещё одного blur-слоя:
/// материал уже задаётся окном/сайдбаром, а десятки shadow layers заметно дорожают при скролле.
final class SettingsCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = Design.Radius.group
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.backgroundColor = Design.Color.surfaceFill(dark).cgColor
        layer?.borderColor = Design.Color.surfaceRim(dark).cgColor
        layer?.shadowOpacity = 0
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Маркер заголовка группы. `SK.scaffold` использует тип для вертикального ритма.
final class SKGroupHeader: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        font = Design.Font.calloutEmph
        textColor = NSColor.labelColor.withAlphaComponent(0.74)
        alignment = .left
        lineBreakMode = .byTruncatingTail
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class BadgePillView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = Design.Radius.chip
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.backgroundColor = Design.Color.controlFill(dark).cgColor
        layer?.borderColor = Design.Color.surfaceRim(dark).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Disclosure

private final class SettingsDisclosureView: NSView {
    private let header = NSView()
    private let titleLabel: NSTextField
    private let chevron = NSImageView()
    private let action = KActionButton()
    private let body = NSStackView()
    private let builder: () -> [NSView]
    private let onStateChange: (Bool) -> Void
    private var didBuild = false
    private var expanded: Bool

    init(title: String,
         expanded: Bool,
         onStateChange: @escaping (Bool) -> Void,
         builder: @escaping () -> [NSView]) {
        self.expanded = expanded
        self.builder = builder
        self.onStateChange = onStateChange
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        header.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Design.Font.body
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let naturalTitleWidth = min(600, ceil(titleLabel.intrinsicContentSize.width))

        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        action.isBordered = false
        action.focusRingType = .default
        action.setAccessibilityLabel(title)
        action.onClick = { [weak self] in self?.toggle() }

        let flexibleSpace = NSView()
        flexibleSpace.translatesAutoresizingMaskIntoConstraints = false
        flexibleSpace.setContentHuggingPriority(.init(1), for: .horizontal)
        flexibleSpace.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let headerRow = NSStackView(views: [titleLabel, flexibleSpace, chevron])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(headerRow)
        header.addSubview(action)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            headerRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerRow.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: naturalTitleWidth),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            action.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            action.topAnchor.constraint(equalTo: header.topAnchor),
            action.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 8
        body.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyState(buildIfNeeded: expanded)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func toggle() {
        expanded.toggle()
        applyState(buildIfNeeded: expanded)
        onStateChange(expanded)
    }

    private func applyState(buildIfNeeded: Bool) {
        chevron.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                accessibilityDescription: nil)
        if buildIfNeeded, !didBuild {
            didBuild = true
            for view in builder() {
                view.translatesAutoresizingMaskIntoConstraints = false
                body.addArrangedSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                ])
            }
        }
        body.isHidden = !expanded
        needsLayout = true
        superview?.needsLayout = true
    }
}

// MARK: - Factory

enum SK {
    static let rowHeight: CGFloat = 42
    static let inset: CGFloat = 14
    static let pageSideInset: CGFloat = 24
    static let pageMaxWidth: CGFloat = 820
    private static let verticalInset: CGFloat = 9

    /// Группа строк с одним фоном и простыми separators. Без constraints ширины на каждом
    /// arrangedSubview: `.alignment = .width` уже делает это и создаёт меньше работы Auto Layout.
    static func card(_ rows: [NSView]) -> SettingsCard {
        let card = SettingsCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.defaultLow, for: .horizontal)
        card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = NSBox()
                separator.boxType = .separator
                separator.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(separator)
                separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
            }
            stack.addArrangedSubview(row)
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

    /// Базовая адаптивная строка. В отличие от spacer+stack схемы здесь нет лишнего
    /// промежуточного view, а длинная локализация переносится вместо распирания окна.
    private static func row(icon: String?,
                            leading: NSView,
                            trailing: NSView?,
                            minHeight: CGFloat = rowHeight) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        leading.translatesAutoresizingMaskIntoConstraints = false
        leading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(leading)

        var horizontalStart = container.leadingAnchor
        var horizontalConstant = inset

        if let icon {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            image.setContentHuggingPriority(.required, for: .horizontal)
            image.setContentCompressionResistancePriority(.required, for: .horizontal)
            container.addSubview(image)

            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
                image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
            ])
            horizontalStart = image.trailingAnchor
            horizontalConstant = 10
        }

        var constraints: [NSLayoutConstraint] = [
            leading.leadingAnchor.constraint(equalTo: horizontalStart, constant: horizontalConstant),
            leading.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            leading.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: verticalInset),
            leading.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -verticalInset),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ]

        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            container.addSubview(trailing)
            constraints.append(contentsOf: [
                trailing.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
                trailing.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                trailing.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: verticalInset),
                trailing.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -verticalInset),
                leading.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            ])
        } else {
            constraints.append(leading.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset))
        }

        NSLayoutConstraint.activate(constraints)
        return container
    }

    private static func titleBlock(_ title: String, _ subtitle: String?) -> NSView {
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = Design.Font.body
        titleLabel.alignment = .left
        titleLabel.baseWritingDirection = .natural
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        guard let subtitle, !subtitle.isEmpty else {
            return titleLabel
        }

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = Design.Font.caption
        subtitleLabel.textColor = NSColor.labelColor.withAlphaComponent(0.64)
        subtitleLabel.alignment = .left
        subtitleLabel.baseWritingDirection = .natural
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.setContentHuggingPriority(.required, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            subtitleLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
        ])
        return stack
    }

    static func toggleRow(icon: String? = nil,
                          title: String,
                          subtitle: String? = nil,
                          isOn: Bool,
                          enabled: Bool = true,
                          onChange: @escaping (Bool) -> Void) -> NSView {
        let control = KSwitch(on: isOn)
        control.onChange = onChange
        control.isEnabled = enabled
        let result = row(icon: icon,
                         leading: titleBlock(title, subtitle),
                         trailing: control)
        result.alphaValue = enabled ? 1 : 0.48
        return result
    }

    static func sliderRow(icon: String? = nil,
                          title: String,
                          min: Double,
                          max: Double,
                          value: Double,
                          ticks: Int = 0,
                          unit: String = "",
                          enabled: Bool = true,
                          onChange: @escaping (Double, NSTextField) -> Void) -> NSView {
        let valueLabel = NSTextField(labelWithString: String(format: "%.0f%@", value, unit))
        valueLabel.font = Design.Font.numericBody
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let slider = KSlider.make(min: min, max: max, value: value, ticks: ticks) { changed in
            onChange(changed, valueLabel)
        }
        slider.isEnabled = enabled
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        let controls = NSStackView(views: [slider, valueLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.widthAnchor.constraint(greaterThanOrEqualToConstant: 178).isActive = true
        let maxWidth = controls.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        maxWidth.priority = .defaultHigh
        maxWidth.isActive = true

        let result = row(icon: icon,
                         leading: titleBlock(title, nil),
                         trailing: controls)
        let preferred = controls.widthAnchor.constraint(equalTo: result.widthAnchor,
                                                         multiplier: 0.48,
                                                         constant: -20)
        preferred.priority = .defaultHigh
        preferred.isActive = true
        result.alphaValue = enabled ? 1 : 0.48
        return result
    }

    /// До трёх коротких вариантов показываются нативными сегментами. Длинные или
    /// многочисленные варианты автоматически становятся popup и не распирают окно.
    static func segmentRow(icon: String? = nil,
                           title: String,
                           options: [String],
                           selected: Int,
                           onSelect: @escaping (Int) -> Void) -> NSView {
        let totalCharacters = options.reduce(0) { $0 + $1.count }
        let control: NSView
        if options.count <= 3, totalCharacters <= 30 {
            control = KSegment.make(options, selected: selected, onSelect: onSelect)
        } else {
            control = KPopup.make(options, selected: selected, onSelect: onSelect)
        }
        return row(icon: icon,
                   leading: titleBlock(title, nil),
                   trailing: control)
    }

    static func selectRow(icon: String? = nil,
                          title: String,
                          options: [String],
                          selected: Int,
                          onSelect: @escaping (Int) -> Void) -> NSView {
        let popup = KPopup.make(options, selected: selected, onSelect: onSelect)
        return row(icon: icon,
                   leading: titleBlock(title, nil),
                   trailing: popup)
    }

    static func controlRow(icon: String? = nil,
                           title: String,
                           subtitle: String? = nil,
                           control: NSView) -> NSView {
        return row(icon: icon,
                   leading: titleBlock(title, subtitle),
                   trailing: control)
    }

    static func customRow(_ view: NSView,
                          minHeight: CGFloat = rowHeight,
                          fill: Bool = false) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)

        let trailing = fill
            ? view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset)
            : view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -inset)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            trailing,
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ])
        return container
    }

    static func textFieldRow(icon: String? = nil,
                             field: NSTextField,
                             placeholder: String? = nil) -> NSView {
        if let placeholder {
            field.placeholderString = placeholder
        }
        field.font = Design.Font.body
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

        var leadingAnchor = container.leadingAnchor
        var leadingConstant = inset

        if let icon {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(image)
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
                image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 18),
                image.heightAnchor.constraint(equalToConstant: 18),
            ])
            leadingAnchor = image.trailingAnchor
            leadingConstant = 10
        }

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingConstant),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: rowHeight),
        ])
        return container
    }

    static func stretchRow(_ view: NSView, height: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: verticalInset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -verticalInset),
            view.heightAnchor.constraint(equalToConstant: height),
        ])
        return container
    }

    static func infoRow(icon: String,
                        text: String,
                        tint: NSColor = NSColor.labelColor.withAlphaComponent(0.66)) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        image.contentTintColor = tint
        image.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true
        image.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Design.Font.caption
        label.textColor = tint
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [image, label])
        content.orientation = .horizontal
        content.alignment = .top
        content.spacing = 7
        return row(icon: nil, leading: content, trailing: nil, minHeight: 36)
    }

    static func badgeRow(icon: String? = nil,
                         title: String,
                         badgeText: String,
                         badgeColor: NSColor = .secondaryLabelColor) -> NSView {
        let badge = NSTextField(labelWithString: badgeText)
        badge.font = Design.Font.caption
        badge.textColor = badgeColor
        badge.alignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false

        let pill = BadgePillView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            badge.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            badge.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
        ])
        return row(icon: icon,
                   leading: titleBlock(title, nil),
                   trailing: pill)
    }

    static func readoutRow(icon: String,
                           value: String,
                           caption: String? = nil) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        image.symbolConfiguration = .init(pointSize: 19, weight: .regular)
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        image.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = Design.Font.numericLarge
        valueLabel.textColor = .labelColor

        var labels: [NSView] = [valueLabel]
        if let caption, !caption.isEmpty {
            let captionLabel = NSTextField(wrappingLabelWithString: caption)
            captionLabel.font = Design.Font.caption
            captionLabel.textColor = .secondaryLabelColor
            captionLabel.maximumNumberOfLines = 2
            labels.append(captionLabel)
        }

        let column = NSStackView(views: labels)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1

        let content = NSStackView(views: [image, column])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        return customRow(content, minHeight: 52)
    }

    static func linkRow(icon: String? = nil,
                        title: String,
                        subtitle: String? = nil,
                        onClick: @escaping () -> Void) -> NSView {
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let result = row(icon: icon,
                         leading: titleBlock(title, subtitle),
                         trailing: chevron)

        let action = KActionButton()
        action.isBordered = false
        action.focusRingType = .default
        action.setAccessibilityLabel(title)
        action.onClick = onClick
        result.addSubview(action)
        NSLayoutConstraint.activate([
            action.leadingAnchor.constraint(equalTo: result.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: result.trailingAnchor),
            action.topAnchor.constraint(equalTo: result.topAnchor),
            action.bottomAnchor.constraint(equalTo: result.bottomAnchor),
        ])
        return result
    }

    /// Состояние сохраняется на время сессии. Для новых мест лучше передавать стабильный `key`,
    /// потому что локализованный title может совпасть в разных разделах.
    static var disclosureState: [String: Bool] = [:]

    static func disclosure(key: String? = nil,
                           title: String,
                           expanded: Bool = false,
                           rows: [NSView]) -> NSView {
        disclosure(key: key,
                   title: title,
                   expanded: expanded,
                   builder: { rows })
    }

    /// Реально ленивое раскрытие: `builder` вызывается только при первом открытии.
    static func lazyDisclosure(key: String,
                               title: String,
                               expanded: Bool = false,
                               builder: @escaping () -> [NSView]) -> NSView {
        disclosure(key: key,
                   title: title,
                   expanded: expanded,
                   builder: builder)
    }

    private static func disclosure(key: String?,
                                   title: String,
                                   expanded: Bool,
                                   builder: @escaping () -> [NSView]) -> NSView {
        let stateKey = key ?? title
        let isExpanded = disclosureState[stateKey] ?? expanded
        return SettingsDisclosureView(title: title,
                                      expanded: isExpanded,
                                      onStateChange: { disclosureState[stateKey] = $0 },
                                      builder: builder)
    }

    /// Каркас раздела без ручного приколачивания каждого arrangedSubview к ширине стека.
    static func scaffold(_ title: String,
                         _ subtitle: String? = nil,
                         _ items: [NSView]) -> NSView {
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: 23, weight: .bold)
        heading.alignment = .left
        heading.baseWritingDirection = .natural
        heading.maximumNumberOfLines = 2

        var views: [NSView] = [heading]
        var subtitleLabel: NSTextField?

        if let subtitle, !subtitle.isEmpty {
            let label = NSTextField(wrappingLabelWithString: subtitle)
            label.font = Design.Font.caption
            label.textColor = NSColor.labelColor.withAlphaComponent(0.64)
            label.alignment = .left
            label.maximumNumberOfLines = 3
            subtitleLabel = label
            views.append(label)
        }
        views.append(contentsOf: items)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Width-only constraints leave the horizontal origin ambiguous for an
        // NSStackView with `.leading` alignment; `.width` alignment, in turn,
        // has unstable intrinsic sizing for cards. Pin both edges explicitly.
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            if view is NSTextField {
                view.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor).isActive = true
            } else {
                view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
        }

        if let subtitleLabel {
            stack.setCustomSpacing(5, after: heading)
            stack.setCustomSpacing(Design.Space.s5, after: subtitleLabel)
        } else {
            stack.setCustomSpacing(Design.Space.s5, after: heading)
        }

        for (index, view) in views.enumerated() where view is SKGroupHeader {
            if index > 0 {
                stack.setCustomSpacing(Design.Space.s5, after: views[index - 1])
            }
            stack.setCustomSpacing(7, after: view)
        }
        return stack
    }
}

/// Сохранён для совместимости с кодом, который мог использовать этот тип напрямую.
/// Новые `SK.linkRow` и `SK.disclosure` используют клавиатурно-доступные NSButton.
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
