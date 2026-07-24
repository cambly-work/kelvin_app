import AppKit

/// Редактор раскладки поповера для окна настроек:
/// слева — список модулей с галочками и перетаскиванием (настоящий drag-and-drop),
/// справа — живой мини-превью поповера, который обновляется сразу при изменениях.
final class PopoverLayoutEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {
    // ЗЕРКАЛО живого таб-бара поповера (main.swift ~596): все 6 = иконки-вкладки, остальное — верхние плитки.
    // Держать в синхроне с реальным баром, иначе превью врёт (privacy/maintenance/history в defaultOn).
    static let tabIDs: Set<String> = ["flow", "hardware", "apps", "privacy", "maintenance", "history"]
    private static let rowType = NSPasteboard.PasteboardType("com.trykelvin.kelvin.popover.row")

    private var items: [PopoverItem] = SettingsStore.popoverLayout
    private let table = NSTableView()
    private let preview = PopoverMiniPreview()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private func build() {
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .none
        table.usesAutomaticRowHeights = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("module"))
        col.width = 240
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap

        let scroll = NSScrollView()
        scroll.documentView = table
        // 12 модулей × ~34pt ≈ 408pt не влезают в 214pt-контейнер: БЕЗ скроллера нижние ~5 модулей
        // (обслуживание/история/диск/BT/звук) были недостижимы. Overlay-скроллер даёт аффорданс + долистывание.
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.render(items)

        let cap = NSTextField(labelWithString: L("Превью"))
        cap.font = Design.Font.micro
        cap.textColor = .tertiaryLabelColor
        cap.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll); addSubview(cap); addSubview(preview)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 420),
            heightAnchor.constraint(equalToConstant: 214),

            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 248),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            cap.topAnchor.constraint(equalTo: topAnchor),
            cap.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 18),

            preview.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 6),
            preview.leadingAnchor.constraint(equalTo: cap.leadingAnchor),
            preview.widthAnchor.constraint(equalToConstant: 150),
            preview.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    private func save() {
        SettingsStore.popoverLayout = items
        NotificationCenter.default.post(name: Notification.Name("BMPopoverChanged"), object: nil)
        preview.render(items)
    }

    @objc private func toggleRow(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        items[sender.tag].on = (sender.state == .on)
        save()
    }

    // MARK: data source / delegate
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let grip = NSImageView(image: NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: L("перетащить")) ?? NSImage())
        grip.contentTintColor = .tertiaryLabelColor
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let cb = NSButton(checkboxWithTitle: PopoverModules.title(item.id), target: self, action: #selector(toggleRow(_:)))
        cb.state = item.on ? .on : .off
        cb.tag = row
        cb.font = Design.Font.body
        let cell = NSStackView(views: [grip, cb])
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 8
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        return dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let str = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.rowType),
              let src = Int(str), items.indices.contains(src) else { return false }
        var dst = row
        let moved = items.remove(at: src)
        if src < dst { dst -= 1 }
        items.insert(moved, at: min(max(dst, 0), items.count))
        save()
        table.reloadData()
        return true
    }
}

/// Лёгкий схематичный мини-превью поповера: верхние плитки стопкой + полоска вкладок,
/// в порядке и видимости из текущей раскладки. Только для наглядности в настройках.
final class PopoverMiniPreview: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor(white: isDark ? 0.16 : 0.92, alpha: 1).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: isDark ? 0.10 : 0.0).cgColor
    }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func render(_ items: [PopoverItem]) {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.backgroundColor = NSColor(white: isDark ? 0.16 : 0.92, alpha: 1).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: isDark ? 0.10 : 0.0).cgColor

        let enabled = items.filter { $0.on }
        let tops = enabled.filter { !PopoverLayoutEditor.tabIDs.contains($0.id) }
        let tabs = enabled.filter { PopoverLayoutEditor.tabIDs.contains($0.id) }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        if enabled.isEmpty {
            stack.addArrangedSubview(label(L("ничего не выбрано")))
        } else {
            for t in tops { stack.addArrangedSubview(block(PopoverModules.title(t.id), h: heightFor(t.id), accent: t.id == "battery")) }
            if !tabs.isEmpty {
                stack.addArrangedSubview(tabStrip(tabs.map { $0.id }))
                stack.addArrangedSubview(block(PopoverModules.title(tabs.first!.id), h: 46, accent: false))
            }
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func heightFor(_ id: String) -> CGFloat {
        switch id { case "battery": return 34; case "toggles": return 30; default: return 22 }
    }
    /// SF-иконки вкладок — ЗЕРКАЛО реального таб-бара поповера (6 вкладок = иконки). Прежний shortName
    /// врал: «apps»→«Прогр.» и не переводил privacy/maintenance/history (показывал сырой id). Превью,
    /// которое врёт, учит не доверять настройкам — теперь 1:1 с живым баром (иконки + имя во всплывашке).
    static func tabIcon(_ id: String) -> String {
        switch id {
        case "flow":        return "bolt.fill"
        case "hardware":    return "cpu"
        case "apps":        return "square.grid.2x2.fill"
        case "privacy":     return "shield.lefthalf.filled"
        case "maintenance": return "wrench.and.screwdriver.fill"
        case "history":     return "chart.line.uptrend.xyaxis"
        default:            return "square"
        }
    }

    private func block(_ text: String, h: CGFloat, accent: Bool) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.cornerCurve = .continuous
        let base = accent ? NSColor.systemTeal : NSColor(white: isDark ? 1 : 0, alpha: 1)
        v.layer?.backgroundColor = base.withAlphaComponent(accent ? (isDark ? 0.22 : 0.18) : (isDark ? 0.12 : 0.07)).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        let l = label(text)
        v.addSubview(l)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 128),
            v.heightAnchor.constraint(equalToConstant: h),
            l.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            l.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 4),
        ])
        return v
    }

    private func tabStrip(_ ids: [String]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 3
        row.translatesAutoresizingMaskIntoConstraints = false
        for (i, id) in ids.enumerated() {
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 4
            let on = i == 0
            pill.layer?.backgroundColor = NSColor(white: isDark ? 1 : 0, alpha: on ? (isDark ? 0.20 : 0.12) : (isDark ? 0.08 : 0.05)).cgColor
            pill.translatesAutoresizingMaskIntoConstraints = false
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: Self.tabIcon(id), accessibilityDescription: PopoverModules.title(id))
            iv.contentTintColor = on ? .labelColor : .secondaryLabelColor
            iv.symbolConfiguration = .init(pointSize: 9, weight: .medium)
            iv.toolTip = PopoverModules.title(id)              // имя вкладки во всплывашке — как в живом баре
            iv.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(iv)
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 16),
                iv.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
                iv.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 11),
            ])
            row.addArrangedSubview(pill)
        }
        row.widthAnchor.constraint(equalToConstant: 128).isActive = true
        return row
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 8, weight: .medium)
        l.textColor = isDark ? .secondaryLabelColor : NSColor(white: 0.3, alpha: 1)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.lineBreakMode = .byTruncatingTail
        return l
    }
}
