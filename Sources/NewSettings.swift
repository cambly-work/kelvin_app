import AppKit
import SwiftUI

enum MacSystemSettings {
    static func open(_ candidates: [String]) {
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    static func openGraphics() {
        open([
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.energysaver",
        ])
    }

    static func openFirewall() {
        open([
            "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall",
            "x-apple.systempreferences:com.apple.preference.security?Firewall",
        ])
    }

    static func openInputMonitoring() {
        open([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        ])
    }
}

/// Полностью новый интерфейс настроек. Он намеренно не использует SettingsKit,
/// NSStackView-страницы и async-подмену documentView старого окна.
final class KelvinSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = KelvinSettingsWindowController()

    let model = KelvinSettingsModel()

    private init() {
        let root = KelvinSettingsRoot(model: model)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.contentMaxSize = NSSize(width: 1240, height: 1000)
        window.title = L("Настройки Kelvin")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .windowBackgroundColor
        window.isOpaque = true
        if #available(macOS 11, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameAutosaveName("KelvinSettingsV2")
        super.init(window: window)
        window.delegate = self
        if UserDefaults.standard.object(forKey: "NSWindow Frame KelvinSettingsV2") == nil {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(section: String? = nil) {
        if let section { select(section) }
        model.reload()
        WindowChrome.becomeRegular()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func select(_ name: String) {
        model.selected = KelvinSettingsSection.resolve(name)
    }

    func refresh() { model.reload() }

    /// Офскрин-снимки нового окна: каждая страница проходит через один и тот же
    /// реальный viewport. Это регрессионная проверка ширины и положения контента.
    func renderSectionsSnapshot(to directory: String, light: Bool, prefix: String) -> Int {
        guard let window, let root = window.contentView else { return 0 }
        if light { window.appearance = NSAppearance(named: .aqua) }
        window.setContentSize(NSSize(width: 960, height: 680))
        var count = 0
        for (index, section) in KelvinSettingsSection.allCases.enumerated() {
            model.selected = section
            model.reload()
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            root.layoutSubtreeIfNeeded()
            let rect = root.bounds
            guard rect.width > 1,
                  rect.height > 1,
                  let rep = root.bitmapImageRepForCachingDisplay(in: rect)
            else { continue }
            root.cacheDisplay(in: rect, to: rep)
            let slug = section.title.replacingOccurrences(of: " ", with: "_")
            let url = URL(fileURLWithPath: String(format: "%@/%@%02d_%@.png",
                                                   directory, prefix, index, slug))
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                count += 1
            }
        }
        return count
    }

    func windowWillClose(_ notification: Notification) {
        WindowChrome.restoreAccessoryIfNoWindows(closing: window)
    }
}

enum KelvinSettingsSection: String, CaseIterable, Identifiable {
    case general
    case power
    case cooling
    case input
    case popover
    case notifications
    case security
    case maintenance
    case about
    case pro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:       return L("Основные")
        case .power:         return L("Питание")
        case .cooling:       return L("Охлаждение")
        case .input:         return L("Ввод и исправления")
        case .popover:       return L("Поповер")
        case .notifications: return L("Уведомления")
        case .security:      return L("Сеть и защита")
        case .maintenance:   return L("Обслуживание")
        case .about:         return L("О Kelvin")
        case .pro:           return "Kelvin Pro"
        }
    }

    var symbol: String {
        switch self {
        case .general:       return "gearshape"
        case .power:         return "bolt.fill"
        case .cooling:       return "fanblades"
        case .input:         return "keyboard"
        case .popover:       return "rectangle.topthird.inset.filled"
        case .notifications: return "bell.badge"
        case .security:      return "lock.shield"
        case .maintenance:   return "wrench.and.screwdriver"
        case .about:         return "info.circle"
        case .pro:           return "sparkles"
        }
    }

    static func resolve(_ name: String) -> KelvinSettingsSection {
        switch name.lowercased() {
        case "power", "питание и охлаждение": return .power
        case "cooling": return .cooling
        case "input", "ввод и текст": return .input
        case "popover", "hub", "поповер и уведомления": return .popover
        case "notifications": return .notifications
        case "netsec", "сеть и защита": return .security
        case "maintenance": return .maintenance
        case "about", "о программе": return .about
        case "license", "pro", "kelvin pro": return .pro
        default: return .general
        }
    }
}

final class KelvinSettingsModel: ObservableObject {
    @Published var selected: KelvinSettingsSection = .general
    @Published private(set) var revision = 0
    @Published var firewallEnabled = false
    @Published var firewallAvailable = false
    @Published var firewallStealth = false
    @Published var firewallBlockAll = false
    @Published var vpnSummary = L("Проверка…")
    @Published var vpnProfiles: [VPN.Profile] = []
    @Published var loginEnabled = false
    @Published var thermalLive: [AlertKind: Double] = [:]
    private var thermalTimer: Timer?

    func startThermalPolling() {
        stopThermalPolling()
        pollThermalOnce()
        thermalTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.pollThermalOnce()
        }
    }

    func stopThermalPolling() {
        thermalTimer?.invalidate()
        thermalTimer = nil
    }

    private func pollThermalOnce() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var values: [AlertKind: Double] = [:]
            
            // Использовать SensorResolver для получения подтверждённых CPU/GPU датчиков.
            let model = FanController.sysctlStr("hw.model")
            let arch = FanController.architecture()
            let catalog = SensorCatalog.build()
            let smc = EnergyModel.smc
            
            if smc.available {
                let resolved = SensorResolver.resolve(
                    model: model,
                    architecture: arch,
                    catalog: catalog,
                    readValue: { smc.read($0) }
                )
                
                // Функция для получения max температуры из набора ключей.
                func maxOf(_ ks: [String]) -> Double? {
                    ks.compactMap { smc.read($0) }.filter { $0 > -40 && $0 < 130 }.max()
                }
                
                // Приоритет: confirmed keys из resolver, иначе fallback на legacy.
                if let cpuSensor = resolved.cpuTemperature {
                    values[.cpuTemp] = maxOf(cpuSensor.keys)
                } else {
                    values[.cpuTemp] = maxOf(["TCXC","TC0E","TC1C","TC2C","TC3C","TC4C"])
                }
                
                if let gpuSensor = resolved.gpuTemperature {
                    values[.gpuTemp] = maxOf(gpuSensor.keys)
                } else {
                    values[.gpuTemp] = maxOf(["TG0D","TG0P"])
                }
            }
            
            values[.cpuLoad] = SystemUsage.shared.cpu() * 100
            if let batt = BatteryReader.read() {
                values[.batteryLow]  = Double(batt.charge)
                values[.batteryFull] = Double(batt.charge)
            }
            DispatchQueue.main.async { self?.thermalLive = values }
        }
    }

    func reload() {
        revision &+= 1
        loginEnabled = LoginItem.enabled
        refreshSecurity()
    }

    func changed(popover: Bool = false, menuBar: Bool = false) {
        revision &+= 1
        if popover {
            NotificationCenter.default.post(name: Notification.Name("BMPopoverChanged"), object: nil)
        }
        if menuBar {
            NotificationCenter.default.post(name: Notification.Name("BMMenuBarChanged"), object: nil)
        }
    }

    func refreshSecurity() {
        DispatchQueue.global(qos: .utility).async {
            let available = Firewall.available
            let enabled = available && Firewall.enabled
            let stealth = available && Firewall.stealth
            let blockAll = available && Firewall.blockAll
            let vpn = VPN.status()
            let summary = vpn.active.map { String(format: L("Подключено: %@"), $0.name) } ?? L("Не подключено")
            DispatchQueue.main.async {
                self.firewallAvailable = available
                self.firewallEnabled = enabled
                self.firewallStealth = stealth
                self.firewallBlockAll = blockAll
                self.vpnSummary = summary
                self.vpnProfiles = vpn.profiles
            }
        }
    }
}

private struct KelvinSettingsRoot: View {
    @ObservedObject var model: KelvinSettingsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            KelvinSettingsSidebar(model: model)
                .frame(width: 224)
            Divider()
            KelvinSettingsPage(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .accentColor(KelvinSwiftUITheme.accent(colorScheme))
        .frame(minWidth: 860, minHeight: 560)
    }
}

private struct KelvinSettingsSidebar: View {
    @ObservedObject var model: KelvinSettingsModel
    @Environment(\.colorScheme) private var colorScheme

    private let primary: [KelvinSettingsSection] = [.general, .power, .cooling, .input, .popover, .notifications]
    private let system: [KelvinSettingsSection] = [.security, .maintenance]

    var body: some View {
        ZStack {
            VisualEffect(material: .sidebar, blendingMode: .behindWindow)
            ScrollView {
                VStack(alignment: .leading, spacing: KelvinSwiftUITheme.Spacing.compact) {
                    HStack(spacing: KelvinSwiftUITheme.Spacing.control) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(KelvinSwiftUITheme.accent(colorScheme))
                        Text("Kelvin")
                            .font(KelvinSwiftUITheme.Typography.brand)
                    }
                    .padding(.bottom, KelvinSwiftUITheme.Spacing.cardInset)

                    sidebarGroup(nil, primary)
                    sidebarGroup(L("Система"), system)
                    sidebarGroup(nil, [.about, .pro])
                }
                .padding(.top, 44)
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private func sidebarGroup(_ label: String?, _ sections: [KelvinSettingsSection]) -> some View {
        if let label {
            Text(label.uppercased())
                .font(KelvinSwiftUITheme.Typography.eyebrow)
                .foregroundColor(.secondary)
                .padding(.leading, 10)
                .padding(.top, 15)
                .padding(.bottom, 3)
        }
        ForEach(sections) { section in
            Button {
                model.selected = section
            } label: {
                HStack(spacing: KelvinSwiftUITheme.Spacing.control) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 21)
                        .foregroundColor(KelvinSwiftUITheme.accent(colorScheme))
                    Text(section.title)
                        .font(KelvinSwiftUITheme.Typography.navigation)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .foregroundColor(.primary)
                .background(
                    RoundedRectangle(cornerRadius: KelvinSwiftUITheme.Radius.chip, style: .continuous)
                        .fill(model.selected == section
                              ? KelvinSwiftUITheme.accentMuted(colorScheme)
                              : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: KelvinSwiftUITheme.Radius.chip, style: .continuous)
                        .stroke(model.selected == section
                                ? KelvinSwiftUITheme.accentRim(colorScheme)
                                : Color.clear,
                                lineWidth: 0.5)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}

private struct KelvinSettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KelvinSwiftUITheme.Spacing.section) {
                Text(model.selected.title)
                    .font(KelvinSwiftUITheme.Typography.pageTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, KelvinSwiftUITheme.Spacing.compact)
                page
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, KelvinSwiftUITheme.Spacing.page)
            .padding(.top, 44)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .id(model.selected)
    }

    @ViewBuilder private var page: some View {
        switch model.selected {
        case .general:       GeneralSettingsPage(model: model)
        case .power:         PowerSettingsPage(model: model)
        case .cooling:       CoolingSettingsPage(model: model)
        case .input:         InputSettingsPage(model: model)
        case .popover:       PopoverSettingsPage(model: model)
        case .notifications: NotificationSettingsPage(model: model)
        case .security:      SecuritySettingsPage(model: model)
        case .maintenance:   MaintenanceSettingsPage()
        case .about:         AboutSettingsPage()
        case .pro:           ProSettingsPage()
        }
    }
}

// MARK: - GPU Mode Card (in-app picker + setup)

/// Карточка переключения GPU: показывает активную GPU, текущую политику,
/// Picker Авто/Встроенная/Дискретная и статус привилегированного сервиса.
private struct GPUModeCard: View {
    @ObservedObject private var gpu = GPUController.shared
    @State private var showSetupSheet = false

    var body: some View {
        KelvinCard(L("Графика")) {
            // Активная GPU (живой индикатор)
            if let active = GPUInfo.active() {
                SettingsRow(active.integrated ? "checkmark.circle.fill" : "circle.fill",
                            active.name,
                            detail: active.kind + " · " + active.vramText) {
                    EmptyView()
                }
                CardDivider()
            }

            // Текущая политика + Picker
            SettingsRow("cpu", L("Режим графики")) {
                if gpu.canSwitch {
                    gpuPicker
                } else {
                    // Сервис не установлен — показываем setup CTA
                    gpuSetupCTA
                }
            }

            // Inline состояние применения
            if gpu.isApplying {
                CardDivider()
                SettingsRow("arrow.triangle.2.circlepath", L("Применяется…")) {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            // Inline ошибка
            if let err = gpu.lastError {
                CardDivider()
                SettingsRow("exclamationmark.triangle", L("Ошибка"),
                            detail: err) {
                    Button(L("Повторить")) {
                        gpu.clearError()
                    }
                }
            }
        }
        .onAppear {
            gpu.refreshSupportState()
            gpu.refreshServiceState()
            gpu.refreshModeFromSystem()
        }
    }

    /// Picker для выбора режима. Disabled во время применения.
    private var gpuPicker: some View {
        Picker(L("Режим графики"), selection: Binding(
            get: { gpu.selectedMode ?? .automatic },
            set: { gpu.setMode($0) }
        )) {
            ForEach(GPUMode.allCases, id: \.self) { mode in
                Text(mode.shortTitle).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(gpu.isApplying)
        .frame(width: 200)
    }

    /// CTA для установки привилегированного сервиса.
    private var gpuSetupCTA: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if case .notInstalled = gpu.serviceState {
                Text(L("Не подключён"))
                    .font(KelvinSwiftUITheme.Typography.detail)
                    .foregroundColor(.secondary)
                Button(L("Подключить")) {
                    showSetupSheet = true
                }
            } else if case .approvalRequired = gpu.serviceState {
                Text(L("Требует одобрения"))
                    .font(KelvinSwiftUITheme.Typography.detail)
                    .foregroundColor(.orange)
                Button(L("Открыть настройки")) {
                    MacSystemSettings.openGraphics()
                }
            } else if case .repairNeeded = gpu.serviceState {
                Text(L("Требует восстановления"))
                    .font(KelvinSwiftUITheme.Typography.detail)
                    .foregroundColor(.orange)
                Button(L("Восстановить")) {
                    showSetupSheet = true
                }
            } else {
                Text(L("Подключение…"))
                    .font(KelvinSwiftUITheme.Typography.detail)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showSetupSheet) {
            GPUSetupSheet(isPresented: $showSetupSheet)
        }
    }
}

/// Sheet установки/восстановления привилегированного сервиса GPU.
private struct GPUSetupSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var gpu = GPUController.shared
    @State private var installing = false
    @State private var result: PrivilegedServiceManager.InstallResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Переключение графики"))
                .font(.system(size: 16, weight: .semibold))

            Text(L("Kelvin установит один системный компонент для переключения видеокарты. Пароль администратора понадобится только один раз — после этого переключение работает без пароля."))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L("Компонент умеет только переключать разрешённые режимы GPU (Авто, Встроенная, Дискретная) и не может выполнять другие команды."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result {
                switch result {
                case .success:
                    Label(L("Компонент подключён"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                case .approvalRequired:
                    Label(L("Откройте Системные настройки → Общие → Объекты входа и разрешите компонент Kelvin"), systemImage: "info.circle")
                        .foregroundColor(.orange)
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                case .cancelled:
                    Label(L("Установка отменена"), systemImage: "xmark.circle")
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Spacer()
                if installing {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                Button(L("Готово")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                if result == nil || (result != nil && result != .success) {
                    Button(L("Подключить")) {
                        installing = true
                        Task {
                            let r = await gpu.installService()
                            await MainActor.run {
                                self.result = r
                                self.installing = false
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installing)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private struct KelvinCard<Content: View>: View {
    let title: String?
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(KelvinSwiftUITheme.Typography.section)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, KelvinSwiftUITheme.Spacing.cardInset)
                    .padding(.top, 13)
                    .padding(.bottom, 6)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: KelvinSwiftUITheme.Radius.card, style: .continuous)
                .fill(KelvinSwiftUITheme.surface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: KelvinSwiftUITheme.Radius.card, style: .continuous)
                .stroke(KelvinSwiftUITheme.surfaceRim(colorScheme), lineWidth: 0.5)
        )
    }
}

/// Честное состояние системного компонента. Настройки можно подготовить заранее,
/// но пароль появляется только после явного нажатия этой CTA.
private struct SystemControlCard: View {
    @ObservedObject var model: KelvinSettingsModel
    let required: Bool

    private var state: HelperInstall.InstallState {
        HelperInstall.installState(.control)
    }

    private var title: String {
        switch state {
        case .starting: return L("Системное управление запускается")
        case .installed: return L("Системное управление подключено")
        case .updateAvailable: return L("Доступно обновление системного управления")
        case .repairNeeded: return L("Системное управление требует восстановления")
        case .notInstalled: return required ? L("Настройки подготовлены") : L("Системное управление не подключено")
        }
    }

    private var detail: String {
        switch state {
        case .starting:
            return L("Kelvin проверяет системный компонент. Настройки применятся после запуска.")
        case .installed:
            return L("Лимит заряда и профили вентиляторов применяются без повторного пароля.")
        case .updateAvailable:
            return L("Текущая версия продолжает работать. Обновление запускается только по вашему выбору.")
        case .repairNeeded:
            return L("Установка неполная; обычные переключатели не будут запрашивать пароль.")
        case .notInstalled:
            return required
                ? L("Подключите компонент один раз, чтобы применить выбранные параметры.")
                : L("Понадобится только для управления зарядом и вентиляторами.")
        }
    }

    private var actionTitle: String {
        switch state {
        case .notInstalled: return L("Подключить…")
        case .updateAvailable: return L("Обновить…")
        case .repairNeeded: return L("Восстановить…")
        case .starting, .installed: return ""
        }
    }

    var body: some View {
        KelvinCard(L("Системные функции")) {
            SettingsRow(state == .installed ? "checkmark.shield.fill" : "lock.shield",
                        title,
                        detail: detail) {
                if state == .starting {
                    ProgressView()
                        .controlSize(.small)
                } else if state == .installed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Button(actionTitle) {
                        _ = SettingsCoordinator.installSystemControlHelper()
                        model.reload()
                    }
                }
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    let control: Control

    init(_ symbol: String, _ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: KelvinSwiftUITheme.Spacing.row) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(KelvinSwiftUITheme.Typography.body)
                if let detail {
                    Text(detail)
                        .font(KelvinSwiftUITheme.Typography.detail)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 18)
            control
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, KelvinSwiftUITheme.Spacing.cardInset)
        .padding(.vertical, detail == nil ? 11 : 9)
        .frame(maxWidth: .infinity)
    }
}

private struct CardDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(KelvinSwiftUITheme.hairline(colorScheme))
            .frame(height: 0.5)
            .padding(.leading, 48)
    }
}

private func settingBinding<T>(
    get: @escaping () -> T,
    set: @escaping (T) -> Void
) -> Binding<T> {
    Binding(get: get, set: set)
}

// MARK: - Thermal Rules helpers

private func alertRules() -> [AlertRule] { SettingsStore.alertRules }

private func updateAlertRule(_ kind: AlertKind, _ transform: (inout AlertRule) -> Void) {
    var rules = SettingsStore.alertRules
    if let idx = rules.firstIndex(where: { $0.kind == kind }) {
        transform(&rules[idx])
        SettingsStore.alertRules = rules
    }
}

private func alertSymbol(_ kind: AlertKind) -> String {
    switch kind {
    case .cpuTemp: return "thermometer.medium"
    case .gpuTemp: return "thermometer.medium"
    case .batteryLow: return "battery.25percent"
    case .batteryFull: return "battery.100percent"
    case .cpuLoad: return "cpu"
    }
}

// MARK: - Custom Toggle helpers (for new settings UI)

extension SettingsStore {
    static func deleteCustomToggle(_ id: String) {
        guard id.hasPrefix("custom:") else { return }
        let cid = String(id.dropFirst("custom:".count))
        var customs = customToggles; customs.removeAll { $0.id == cid }; customToggles = customs
        var lay = toggleLayout; lay.removeAll { $0.id == id }; toggleLayout = lay
    }

    static func addCustomToggle(label: String, icon: String, command: String) {
        let c = CustomToggle(id: UUID().uuidString, label: label, icon: icon, command: command, color: "blue")
        var customs = customToggles; customs.append(c); customToggles = customs
    }
}

private struct GeneralSettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel

    /// Extra indicator definitions (id → label).
    private static let menuExtraDefs: [(id: String, label: String, symbol: String)] = [
        ("watts",   L("Потребление (Вт)"), "bolt.fill"),
        ("cputemp", L("Температура CPU"), "thermometer.medium"),
        ("gputemp", L("Температура GPU"), "thermometer.high"),
        ("fan",     L("Обороты вентилятора"), "fanblades.fill"),
        ("cpu",     L("Загрузка CPU"), "cpu"),
        ("ram",     L("Оперативная память"), "memorychip"),
        ("net",     L("Сетевая скорость"), "arrow.up.arrow.down"),
        ("clock",   L("Часы"), "clock"),
        ("date",    L("Дата"), "calendar"),
        ("diskio",  L("Диск (R/W)"), "internaldrive"),
        ("diskfree",L("Диск (свободно)"), "externaldrive.badge.checkmark"),
        ("btbatt",  L("Bluetooth-аккумулятор"), "wave.3.right"),
    ]

    var body: some View {
        VStack(spacing: 18) {
            KelvinCard(L("Запуск")) {
                SettingsRow("power", L("Запускать Kelvin при входе"), detail: L("Приложение откроется автоматически после входа в macOS.")) {
                    Toggle("", isOn: Binding(
                        get: { model.loginEnabled },
                        set: { value in
                            _ = LoginItem.set(value)
                            model.loginEnabled = LoginItem.enabled
                        }
                    )).labelsHidden()
                }
            }
            KelvinCard(L("Строка меню")) {
                SettingsRow("menubar.rectangle", L("Основной показатель")) {
                    Picker("", selection: settingBinding(
                        get: { SettingsStore.menuBarMode },
                        set: { SettingsStore.menuBarMode = $0; model.changed(menuBar: true) }
                    )) {
                        Text(L("Батарея")).tag("battery")
                        Text("CPU").tag("cpu")
                        Text("RAM").tag("ram")
                        Text(L("Температура CPU")).tag("cputemp")
                        Text(L("Вентилятор")).tag("fan")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                if SettingsStore.menuBarMode == "battery" {
                    CardDivider()
                    SettingsRow("thermometer.medium", L("Иконка")) {
                        Picker("", selection: settingBinding(
                            get: { SettingsStore.mainIconStyle },
                            set: { SettingsStore.mainIconStyle = $0; model.changed(menuBar: true) }
                        )) {
                            Text("Kelvin Live").tag("kelvin")
                            Text(L("Термометр")).tag("thermometer")
                            Text(L("Батарея")).tag("battery")
                            Text(L("Кольцо заряда")).tag("ring")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                CardDivider()
                SettingsRow("paintpalette", L("Стиль иконок"),
                            detail: L("Системные используют оригинальные SF Symbols macOS; Kelvin — фирменные векторные глифы.")) {
                    Picker("", selection: settingBinding(
                        get: { SettingsStore.menuBarIconStyle },
                        set: { SettingsStore.menuBarIconStyle = $0; model.changed(menuBar: true) }
                    )) {
                        Text(L("Системные macOS")).tag("system")
                        Text("Kelvin").tag("kelvin")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                CardDivider()
                if SettingsStore.menuBarMode == "battery" {
                    SettingsRow("bolt", L("Показывать потребление")) {
                        Toggle("", isOn: settingBinding(
                            get: { SettingsStore.menuBarShowWatts },
                            set: { SettingsStore.menuBarShowWatts = $0; model.changed(menuBar: true) }
                        )).labelsHidden()
                    }
                    CardDivider()
                }
                SettingsRow("waveform.path", L("Живые анимации"),
                            detail: L("Движение показывает зарядку и смену состояния; системное «Уменьшение движения» имеет приоритет.")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.menuBarMotion },
                        set: { SettingsStore.menuBarMotion = $0; model.changed(menuBar: true) }
                    )).labelsHidden()
                }
                CardDivider()
                SettingsRow("rectangle.3.group", L("Объединённый вид")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.menuBarCombined },
                        set: { SettingsStore.menuBarCombined = $0; model.changed(menuBar: true) }
                    )).labelsHidden()
                }
                if SettingsStore.menuBarCombined {
                    CardDivider()
                    SettingsRow("app.badge", L("Иконки показателей")) {
                        Toggle("", isOn: settingBinding(
                            get: { SettingsStore.menuBarExtraIcons },
                            set: { SettingsStore.menuBarExtraIcons = $0; model.changed(menuBar: true) }
                        )).labelsHidden()
                    }
                }
                ForEach(Array(Self.menuExtraDefs.enumerated()), id: \.element.id) { index, def in
                    CardDivider()
                    SettingsRow(def.symbol, def.label) {
                        Toggle("", isOn: settingBinding(
                            get: { SettingsStore.menuBarExtras.contains(def.id) },
                            set: { isOn in
                                var extras = SettingsStore.menuBarExtras
                                if isOn && extras.count < 3 { extras.append(def.id) }
                                else if !isOn { extras.removeAll { $0 == def.id } }
                                SettingsStore.menuBarExtras = extras
                                model.changed(menuBar: true)
                            }
                        )).labelsHidden()
                        .disabled(!SettingsStore.menuBarExtras.contains(def.id) && SettingsStore.menuBarExtras.count >= 3)
                    }
                }
            }
            // MARK: - Interface Language
            KelvinCard(L("Язык интерфейса")) {
                SettingsRow("globe", L("Язык"), detail: L("Меню и панель обновляются мгновенно.")) {
                    Picker("", selection: settingBinding(
                        get: { I18n.override?.rawValue ?? "system" },
                        set: { v in
                            I18n.override = v == "system" ? nil : Lang(rawValue: v)
                        }
                    )) {
                        Text(L("Системный")).tag("system")
                        ForEach(Lang.allCases, id: \.rawValue) { lang in
                            Text(lang.title).tag(lang.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            // MARK: - Global Hotkey
            KelvinCard(L("Горячая клавиша поповера")) {
                SettingsRow("command", L("Открывать поповер по хоткею")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.popoverHotkeyEnabled },
                        set: { v in
                            SettingsStore.popoverHotkeyEnabled = v
                            reapplyPopoverHotkey()
                        }
                    )).labelsHidden()
                }
                if SettingsStore.popoverHotkeyEnabled {
                    CardDivider()
                    SettingsRow("keyboard", L("Комбинация"), detail: hotkeyDisplayText) {
                        Button(L("Сбросить")) {
                            SettingsStore.popoverHotkeyKeyCode = 11
                            SettingsStore.popoverHotkeyMods = Int(NSEvent.ModifierFlags([.command, .option]).rawValue)
                            reapplyPopoverHotkey()
                        }
                    }
                }
            }
        }
    }
}

/// Re-registers the global hotkey with current settings.
private func reapplyPopoverHotkey() {
    GlobalHotkey.shared.apply(
        enabled: SettingsStore.popoverHotkeyEnabled,
        keyCode: SettingsStore.popoverHotkeyKeyCode,
        modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(SettingsStore.popoverHotkeyMods))
    )
}

/// Human-readable display for the current hotkey combination.
private var hotkeyDisplayText: String {
    let mods = NSEvent.ModifierFlags(rawValue: UInt(SettingsStore.popoverHotkeyMods))
    var parts: [String] = []
    if mods.contains(.control)  { parts.append("⌃") }
    if mods.contains(.option)   { parts.append("⌥") }
    if mods.contains(.command)  { parts.append("⌘") }
    if mods.contains(.shift)    { parts.append("⇧") }
    parts.append(HotkeyFormat.keyName(SettingsStore.popoverHotkeyKeyCode) ?? "B")
    return parts.joined()
}

private struct PowerSettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel

    var body: some View {
        VStack(spacing: 18) {
            KelvinCard(L("Заряд аккумулятора")) {
                SettingsRow("battery.100", L("Режим")) {
                    Picker("", selection: settingBinding(
                        get: {
                            SettingsStore.chargeMode == "sail" ? "sail"
                                : (SettingsStore.chargeLimit < 100 ? "limit" : "off")
                        },
                        set: { value in
                            guard ChargeControl.setMode(value) else { model.reload(); return }
                            model.changed(popover: true)
                        }
                    )) {
                        Text(L("Без ограничений")).tag("off")
                        Text(L("Лимит")).tag("limit")
                        Text(L("Парус")).tag("sail")
                    }
                    .labelsHidden()
                    .frame(width: 175)
                }
                if SettingsStore.chargeMode != "sail" && SettingsStore.chargeLimit < 100 {
                    CardDivider()
                    SettingsRow("gauge.with.dots.needle.67percent", L("Лимит заряда"), detail: "\(SettingsStore.chargeLimit)%") {
                        Slider(value: settingBinding(
                            get: { Double(SettingsStore.chargeLimit) },
                            set: {
                                let value = Int($0.rounded())
                                SettingsStore.chargeLimit = value
                                _ = ChargeControl.setLimit(value)
                                model.changed(popover: true)
                            }
                        ), in: 50...100, step: 5)
                        .frame(width: 220)
                    }
                }
                if SettingsStore.chargeMode == "sail" {
                    CardDivider()
                    SettingsRow("arrow.up.circle", L("Заряжать до"), detail: "\(SettingsStore.sailUpper)%") {
                        Slider(value: settingBinding(
                            get: { Double(SettingsStore.sailUpper) },
                            set: {
                                _ = ChargeControl.setSail(upper: Int($0), lower: SettingsStore.sailLower)
                                model.changed(popover: true)
                            }
                        ), in: 60...90, step: 5).frame(width: 220)
                    }
                    CardDivider()
                    SettingsRow("arrow.down.circle", L("Держать не ниже"), detail: "\(SettingsStore.sailLower)%") {
                        Slider(value: settingBinding(
                            get: { Double(SettingsStore.sailLower) },
                            set: {
                                _ = ChargeControl.setSail(upper: SettingsStore.sailUpper, lower: Int($0))
                                model.changed(popover: true)
                            }
                        ), in: 50...85, step: 5).frame(width: 220)
                    }
                }
            }
            KelvinCard(L("Защита")) {
                SettingsRow("thermometer.high", L("Защита от перегрева"), detail: L("Приостанавливать заряд при высокой температуре аккумулятора.")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.heatProtect },
                        set: {
                            guard ChargeControl.setHeatProtection($0) else { model.reload(); return }
                            model.changed(popover: true)
                        }
                    )).labelsHidden()
                }
            }
            SystemControlCard(model: model, required: ChargeControl.isActive)
            // MARK: - Top-up & Scheduled Charge
            if SettingsStore.chargeMode != "off" {
                KelvinCard(L("Дозарядка")) {
                    if SettingsStore.chargeMode == "sail" || SettingsStore.chargeLimit < 100 {
                        SettingsRow("bolt.badge.clock", L("Зарядить до 100% сейчас")) {
                            Button(L("Зарядить")) { _ = ChargeControl.topUp() }
                        }
                        CardDivider()
                    }
                    SettingsRow("alarm", L("Запланированная дозарядка"), detail: L("Полная зарядка к указанному времени.")) {
                        Toggle("", isOn: settingBinding(
                            get: { SettingsStore.chargeAlarmOn },
                            set: { v in
                                guard ChargeControl.setAlarm(on: v,
                                                             targetMin: SettingsStore.chargeAlarmTargetMin,
                                                             leadMin: SettingsStore.chargeAlarmLeadMin)
                                else { model.reload(); return }
                                model.changed(popover: true)
                            }
                        )).labelsHidden()
                    }
                    if SettingsStore.chargeAlarmOn {
                        CardDivider()
                        SettingsRow("clock", L("Время полной зарядки")) {
                            Picker("", selection: settingBinding(
                                get: { SettingsStore.chargeAlarmTargetMin },
                                set: { v in
                                    SettingsStore.chargeAlarmTargetMin = v
                                    _ = ChargeControl.setAlarm(on: true, targetMin: v, leadMin: SettingsStore.chargeAlarmLeadMin)
                                    model.changed(popover: true)
                                }
                            )) {
                                ForEach(Array(stride(from: 0, to: 1440, by: 30)), id: \.self) { m in
                                    Text(String(format: "%02d:%02d", m / 60, m % 60)).tag(m)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                        CardDivider()
                        SettingsRow("timer", L("Начать зарядку за")) {
                            Picker("", selection: settingBinding(
                                get: { SettingsStore.chargeAlarmLeadMin },
                                set: { v in
                                    SettingsStore.chargeAlarmLeadMin = v
                                    _ = ChargeControl.setAlarm(on: true, targetMin: SettingsStore.chargeAlarmTargetMin, leadMin: v)
                                    model.changed(popover: true)
                                }
                            )) {
                                Text("30 " + L("мин")).tag(30)
                                Text("45 " + L("мин")).tag(45)
                                Text("1 " + L("ч")).tag(60)
                                Text("1 ч 30 " + L("мин")).tag(90)
                                Text("2 " + L("ч")).tag(120)
                            }
                            .labelsHidden()
                            .frame(width: 120)
                        }
                    }
                }
            }
        }
    }
}

private struct CoolingSettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel
    @State private var advancedProfile = SettingsStore.customFanProfile
    
    private var rules: [AlertRule] { alertRules() }
    
    // Определить cooling topology для текущего Mac.
    private let coolingTopology = FanController.coolingTopology()
    private let isPassive = FanController.isPassiveCooling
    private let hasFans = FanController.hasActiveCooling
    private var fans: [FanInfo] { FanController.fans() }
    
    var body: some View {
        VStack(spacing: 18) {
            // MARK: - Cooling Topology Info
            if isPassive {
                KelvinCard(L("Охлаждение")) {
                    SettingsRow("fanblades.fill", L("Пассивное охлаждение"), detail: L("Ваш Mac не имеет вентиляторов и полагается на естественное рассеивание тепла.")) {
                        EmptyView()
                    }
                }
            } else if !hasFans {
                KelvinCard(L("Охлаждение")) {
                    SettingsRow("questionmark.circle", L("Данные недоступны"), detail: L("Не удалось определить наличие вентиляторов. Управление может быть недоступно.")) {
                        EmptyView()
                    }
                }
            }
            
            // MARK: - Fan Profile (только если есть активное охлаждение)
            if hasFans && !isPassive {
            SystemControlCard(
                model: model,
                required: SettingsStore.activeFanProfileName != "auto" || SettingsStore.fanAutoBySource
            )
            KelvinCard(L("Профиль вентиляторов")) {
                SettingsRow("fanblades", L("Активный профиль"), detail: L("Системный режим безопаснее всего для повседневной работы.")) {
                    Picker("", selection: settingBinding(
                        get: { SettingsStore.activeFanProfileName },
                        set: { value in
                            guard SettingsCoordinator.requirePro(.fans) else { model.reload(); return }
                            SettingsStore.activeFanProfileName = value
                            FanController.applyProfileHeadless(named: value)
                            model.changed(popover: true)
                        }
                    )) {
                        ForEach(SettingsStore.builtinFanIDs, id: \.self) {
                            Text(SettingsStore.builtinFanDisplay($0)).tag($0)
                        }
                        ForEach(SettingsStore.userFanPresets, id: \.name) {
                            Text($0.name).tag($0.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 155)
                }
                CardDivider()
                SettingsRow("arrow.triangle.2.circlepath", L("Автоматически по источнику питания")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.fanAutoBySource },
                        set: { on in
                            if on, !SettingsCoordinator.requirePro(.fans) { model.reload(); return }
                            SettingsStore.fanAutoBySource = on
                            if on { ChargeControl.ensureHelper() }
                            model.changed(popover: true)
                        }
                    )).labelsHidden()
                }
                CardDivider()
                SettingsRow("slider.horizontal.3", L("Профессиональный редактор"),
                            detail: L("Свой профиль: датчики, кривая, разгон и отдельная настройка вентиляторов.")) {
                    EmptyView()
                }
                CardDivider()
                AdvancedCoolingEditor(profile: $advancedProfile, fans: fans) {
                    guard SettingsCoordinator.requirePro(.fans) else { return }
                    SettingsStore.customFanProfile = advancedProfile
                    SettingsStore.activeFanProfileName = advancedProfile.name
                    FanController.writeProfileFile(advancedProfile)
                    model.changed(popover: true)
                }
            }

            KelvinCard(L("Текущее охлаждение")) {
                ForEach(Array(fans.enumerated()), id: \.offset) { index, fan in
                    SettingsRow("fanblades",
                                fans.count > 1 ? String(format: L("Вентилятор %d"), index + 1) : L("Вентилятор"),
                                detail: String(format: L("Сейчас %.0f об/мин · диапазон %.0f–%.0f об/мин%@"),
                                               fan.rpm, fan.min, fan.max,
                                               fan.forced ? " · " + L("принудительный режим") : "")) {
                        EmptyView()
                    }
                    if index < fans.count - 1 { CardDivider() }
                }
            }
            }

            // MARK: - GPU
            if GPUInfo.switchable {
                GPUModeCard()
            }

            // MARK: - Thermal Rules
            KelvinCard(L("Тепловые правила")) {
                ForEach(Array(rules.enumerated()), id: \.element.kind) { index, rule in
                    thermalRuleRows(rule: rule, index: index)
                    if index < rules.count - 1 { CardDivider() }
                }
                if !SettingsStore.alertsEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(.secondary)
                        Text(L("Включите уведомления, чтобы тепловые правила работали."))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
            .onAppear { model.startThermalPolling() }
            .onDisappear { model.stopThermalPolling() }
        }
    }

    private func thermalRuleRows(rule: AlertRule, index: Int) -> some View {
        VStack(spacing: 0) {
            // Header: icon + label + live value
            SettingsRow(alertSymbol(rule.kind), rule.kind.label) {
                if let v = model.thermalLive[rule.kind] {
                    Text(String(format: L("сейчас %.0f%@"),
                                v,
                                rule.kind.unit))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // Toggle: enable / disable rule
            SettingsRow("bell", L("Уведомить при срабатывании")) {
                Toggle("", isOn: settingBinding(
                    get: { rule.on },
                    set: { on in
                        if on {
                            AlertsEngine.shared.requestOrOpenSettings { granted in
                                guard granted else { model.changed(); return }
                                updateAlertRule(rule.kind) { $0.on = true }
                                AlertsEngine.shared.onRulesChanged()
                                model.changed()
                            }
                        } else {
                            updateAlertRule(rule.kind) { r in
                                r.on = false
                                r.action = nil
                            }
                            AlertsEngine.shared.onRulesChanged()
                            model.changed()
                        }
                    }
                )).labelsHidden()
                .disabled(!SettingsStore.alertsEnabled)
            }

            // Threshold slider (only when rule is on + master on)
            if rule.on && SettingsStore.alertsEnabled {
                SettingsRow("slider.horizontal.3", L("Порог")) {
                    HStack(spacing: 8) {
                        Slider(value: settingBinding(
                            get: { rule.threshold },
                            set: { v in
                                updateAlertRule(rule.kind) { $0.threshold = v }
                                AlertsEngine.shared.onRulesChanged()
                                model.changed()
                            }
                        ), in: rule.kind.range.lo...rule.kind.range.hi,
                           step: rule.kind.range.step)
                            .frame(width: 160)
                        Text(String(format: "%.0f%@", rule.threshold, rule.kind.unit))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            // Fan boost toggle (cpuTemp, gpuTemp, cpuLoad only, Pro-gated)
            if rule.on && SettingsStore.alertsEnabled && rule.kind.canBoostFans {
                SettingsRow("fanblades", L("Турбо-кулеры при срабатывании"),
                           detail: L("Вентиляторы переключатся на максимум до恢复正常.")) {
                    Toggle("", isOn: settingBinding(
                        get: { rule.action == .fansMax },
                        set: { on in
                            guard SettingsCoordinator.requirePro(.fans) else {
                                model.reload(); return
                            }
                            updateAlertRule(rule.kind) { r in
                                r.action = on ? .fansMax : nil
                            }
                            AlertsEngine.shared.onRulesChanged()
                            model.changed()
                        }
                    )).labelsHidden()
                }
            }
        }
    }
}

/// Встроенный профессиональный редактор. Остаётся частью текущей SwiftUI-страницы:
/// никаких вторых окон и визуального скачка в legacy AppKit.
private struct AdvancedCoolingEditor: View {
    @Binding var profile: FanProfile
    let fans: [FanInfo]
    let apply: () -> Void
    @State private var profileName = ""
    @Environment(\.colorScheme) private var colorScheme

    private var availableSensors: [TempSensor] { FanController.sensors() }

    private var idleEnabled: Binding<Bool> {
        Binding(
            get: { (profile.idleHandoffTemp ?? 0) > 0 },
            set: { profile.idleHandoffTemp = $0 ? max(35, profile.idleHandoffTemp ?? 45) : nil }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow("person.crop.square", L("Название профиля"),
                        detail: L("Сохраните несколько профилей для разных задач.")) {
                TextField(L("Например, Монтаж"), text: $profileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            CardDivider()
            SettingsRow("dial.medium", L("Режим")) {
                Picker("", selection: Binding(
                    get: { profile.mode },
                    set: { mode in
                        profile.mode = mode
                        if mode == .curve, (profile.curvePoints?.count ?? 0) < 2 {
                            let lo = Int(fans.map(\.min).filter { $0 > 0 }.min() ?? 1800)
                            let hi = Int(fans.map(\.max).max() ?? 6000)
                            profile.curvePoints = [
                                CurvePoint(temp: 35, rpm: lo),
                                CurvePoint(temp: 55, rpm: max(lo, (lo + hi) / 2)),
                                CurvePoint(temp: 75, rpm: hi)
                            ]
                        }
                    }
                )) {
                    Text(L("По датчикам")).tag(FanMode.curve)
                    Text(L("Постоянные обороты")).tag(FanMode.constant)
                }
                .labelsHidden()
                .frame(width: 210)
            }
            if profile.mode == .constant {
                SettingsRow("fanblades", L("Целевые обороты")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(profile.rpm) },
                            set: { profile.rpm = Int($0.rounded()) }
                        ), in: rpmBounds, step: 50)
                        .frame(width: 190)
                        Text("\(profile.rpm)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            } else {
                CardDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Датчики кривой"))
                        .font(.system(size: 12, weight: .semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 7)], alignment: .leading, spacing: 7) {
                        ForEach(availableSensors, id: \.key) { sensor in
                            SensorChip(
                                title: sensor.name,
                                selected: selectedSensorKeys.contains(sensor.key)
                            ) { toggleSensor(sensor.key) }
                        }
                    }
                    FanCurveRepresentable(
                        points: Binding(
                            get: { profile.curvePoints ?? [] },
                            set: { profile.curvePoints = $0 }
                        ),
                        rpmRange: rpmBounds,
                        currentTemp: selectedSensorKeys.compactMap { FanController.temp($0) }.max()
                    )
                    .frame(height: 178)
                    Text(L("Перетаскивайте точки: температура слева направо, обороты снизу вверх. Самый горячий выбранный датчик управляет кривой."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            SettingsRow("timer", L("Время разгона"),
                        detail: L("Плавное изменение оборотов снижает резкие скачки шума.")) {
                HStack(spacing: 10) {
                    Slider(value: Binding(
                        get: { Double(profile.rampTime) },
                        set: { profile.rampTime = Int($0.rounded()) }
                    ), in: 0...120, step: 5)
                    .frame(width: 170)
                    Text(profile.rampTime == 0 ? L("мгновенно") : "\(profile.rampTime) " + L("с"))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .frame(width: 78, alignment: .trailing)
                }
            }
            CardDivider()
            SettingsRow("moon.zzz", L("Передавать управление macOS в простое"),
                        detail: L("Ниже выбранной температуры система снова управляет вентиляторами.")) {
                Toggle("", isOn: idleEnabled).labelsHidden()
            }
            if idleEnabled.wrappedValue {
                SettingsRow("thermometer.low", L("Температура возврата")) {
                    HStack(spacing: 10) {
                        Slider(value: Binding(
                            get: { Double(profile.idleHandoffTemp ?? 45) },
                            set: { profile.idleHandoffTemp = Int($0.rounded()) }
                        ), in: 30...60, step: 1)
                        .frame(width: 170)
                        Text("\(profile.idleHandoffTemp ?? 45)°")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            }
            if fans.count > 1 {
                CardDivider()
                SettingsRow("fanblades", L("Настроить вентиляторы отдельно"),
                            detail: L("Используйте только при раздельных зонах охлаждения.")) {
                    Toggle("", isOn: Binding(
                        get: { profile.perFan?.count == fans.count },
                        set: { enabled in
                            if enabled {
                                let base = profile.setting(forFan: 0)
                                profile.perFan = fans.map { _ in base }
                            } else {
                                profile.perFan = nil
                            }
                        }
                    )).labelsHidden()
                }
            }
            CardDivider()
            HStack {
                Label(L("Защита от перегрева остаётся активной при любом профиле."),
                      systemImage: "checkmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if !profileName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button(L("Сохранить профиль")) { saveProfile() }
                }
                Button(L("Применить")) {
                    if !profileName.trimmingCharacters(in: .whitespaces).isEmpty { saveProfile() }
                    apply()
                }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(KelvinSwiftUITheme.accentMuted(colorScheme).opacity(0.28))
        .onAppear {
            ensureCurve()
            if profileName.isEmpty, !SettingsStore.isBuiltinFanID(profile.name) {
                profileName = profile.name == "Свой" ? "" : profile.name
            }
        }
    }

    private var rpmBounds: ClosedRange<Double> {
        let lo = fans.map(\.min).filter { $0 > 0 }.min() ?? 1200
        let hi = max(fans.map(\.max).max() ?? 6000, lo + 500)
        return lo...hi
    }

    private var selectedSensorKeys: [String] {
        let keys = profile.curveSensorKeys ?? [profile.sensorKey]
        return keys.filter { !$0.isEmpty }
    }

    private func toggleSensor(_ key: String) {
        var keys = selectedSensorKeys
        if let index = keys.firstIndex(of: key) {
            if keys.count > 1 { keys.remove(at: index) }
        } else {
            keys.append(key)
        }
        profile.curveSensorKeys = keys
        profile.sensorKey = keys.first ?? profile.sensorKey
    }

    private func saveProfile() {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !SettingsStore.builtinFanNames.contains(name) else { return }
        profile.name = name
        var presets = SettingsStore.userFanPresets
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            presets[index] = profile
        } else {
            presets.append(profile)
        }
        SettingsStore.userFanPresets = presets
        SettingsStore.customFanProfile = profile
        SettingsStore.activeFanProfileName = name
    }

    private func ensureCurve() {
        guard profile.mode == .curve, (profile.curvePoints?.count ?? 0) < 2 else { return }
        let lo = Int(rpmBounds.lowerBound)
        let hi = Int(rpmBounds.upperBound)
        profile.curvePoints = [
            CurvePoint(temp: 35, rpm: lo),
            CurvePoint(temp: 55, rpm: max(lo, (lo + hi) / 2)),
            CurvePoint(temp: 75, rpm: hi)
        ]
    }
}

private struct SensorChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(selected
                        ? KelvinSwiftUITheme.accentMuted(colorScheme)
                        : KelvinSwiftUITheme.control(colorScheme))
            .cornerRadius(KelvinSwiftUITheme.Radius.chip)
        }
        .buttonStyle(.plain)
    }
}

private struct FanCurveRepresentable: NSViewRepresentable {
    @Binding var points: [CurvePoint]
    let rpmRange: ClosedRange<Double>
    let currentTemp: Double?

    func makeNSView(context: Context) -> FanCurveView {
        let view = FanCurveView()
        view.onChange = { context.coordinator.points.wrappedValue = $0 }
        return view
    }

    func updateNSView(_ view: FanCurveView, context: Context) {
        context.coordinator.points = $points
        if view.points != points { view.points = points }
        view.rpmRange = rpmRange
        view.currentTemp = currentTemp
    }

    func makeCoordinator() -> Coordinator { Coordinator(points: $points) }
    final class Coordinator {
        var points: Binding<[CurvePoint]>
        init(points: Binding<[CurvePoint]>) { self.points = points }
    }
}


private struct InputSettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel
    @State private var snippets = SettingsStore.snippetsRaw
    @State private var inputStatus = LangSwitcherStatus.current()

    private var needsInputAccess: Bool {
        SettingsStore.langMode != "off"
            || SettingsStore.spellFixEnabled
            || SettingsStore.snippetsEnabled
    }

    var body: some View {
        VStack(spacing: 18) {
            KelvinCard(L("Переключение языка")) {
                SettingsRow("globe", L("Режим")) {
                    Picker("", selection: settingBinding(
                        get: { SettingsStore.langMode },
                        set: {
                            SettingsStore.langMode = $0
                            switch $0 {
                            case "hotkey": LangSwitcher.shared.mode = .hotkey
                            case "auto":   LangSwitcher.shared.mode = .auto
                            default:       LangSwitcher.shared.mode = .off
                            }
                            model.changed()
                        }
                    )) {
                        Text(L("Выключено")).tag("off")
                        Text(L("Горячая клавиша")).tag("hotkey")
                        Text(L("Автоматически")).tag("auto")
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                if SettingsStore.langMode == "hotkey" {
                    CardDivider()
                    SettingsRow("keyboard", L("Клавиша-триггер")) {
                        Picker("", selection: settingBinding(
                            get: { SettingsStore.langHotkey },
                            set: { SettingsStore.langHotkey = $0; LangSwitcher.shared.hotkeyKeycode = CGKeyCode($0) }
                        )) {
                            Text(L("Правый Option")).tag(61)
                            Text(L("Правый Command")).tag(54)
                            Text(L("Правый Control")).tag(62)
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
                if SettingsStore.langMode == "auto" {
                    CardDivider()
                    SettingsRow("textformat.size", L("Мин. длина слова")) {
                        Picker("", selection: settingBinding(
                            get: { SettingsStore.langAutoMinLength },
                            set: { SettingsStore.langAutoMinLength = $0 }
                        )) {
                            Text("3").tag(3)
                            Text("4").tag(4)
                            Text("5").tag(5)
                        }
                        .labelsHidden()
                        .frame(width: 60)
                    }
                }
            }
            if needsInputAccess {
                KelvinCard(L("Разрешение системы")) {
                    SettingsRow(inputStatus.runtimeStatus.isWorking ? "checkmark.circle.fill" : "accessibility",
                                inputStatus.runtimeStatus.localizedDescription,
                                detail: inputPermissionDetail) {
                        switch inputStatus.runtimeStatus {
                        case .active:
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        case .accessibilityDenied:
                            Button(L("Разрешить…")) {
                                _ = LangSwitcher.shared.requestAccessibility()
                            }
                        case .inputMonitoringUnavailable, .tapFailed:
                            Button(L("Открыть настройки")) {
                                MacSystemSettings.openInputMonitoring()
                            }
                        case .missingLayouts:
                            Button(L("Открыть настройки")) {
                                InputSources.openSystemKeyboardSettings()
                            }
                        case .tapStarting:
                            ProgressView().controlSize(.small)
                        case .off, .unavailableByLicense:
                            EmptyView()
                        }
                    }
                }
            }
            KelvinCard(L("Исправления")) {
                SettingsRow("checkmark.circle", L("Исправлять явные опечатки"), detail: L("После замены можно оставить исправление или вернуть исходное слово.")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.spellFixEnabled },
                        set: { SettingsStore.spellFixEnabled = $0; LangSwitcher.shared.spellFixEnabled = $0; model.changed() }
                    )).labelsHidden()
                }
                if SettingsStore.spellFixEnabled {
                    CardDivider()
                    SettingsRow("slider.horizontal.3", L("Строгость")) {
                        Picker("", selection: settingBinding(
                            get: { SettingsStore.spellFixMode },
                            set: { SettingsStore.spellFixMode = $0 }
                        )) {
                            Text(L("Строгая")).tag("strict")
                            Text(L("Сбалансированная")).tag("balanced")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
                CardDivider()
                SettingsRow("sparkles", L("Интерактивное предложение")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.langFeedbackHUD },
                        set: { SettingsStore.langFeedbackHUD = $0; model.changed() }
                    )).labelsHidden()
                }
                if SettingsStore.langFeedbackHUD {
                    CardDivider()
                    SettingsRow("paintpalette", L("Стиль индикатора")) {
                        Picker("", selection: settingBinding(
                            get: { SettingsStore.langFeedbackStyle },
                            set: { SettingsStore.langFeedbackStyle = $0 }
                        )) {
                            Text(L("Анимированный")).tag("animated")
                            Text(L("Компактный")).tag("compact")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
                CardDivider()
                SettingsRow("speaker.wave.2", L("Звук обратной связи")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.langFeedbackSound },
                        set: { SettingsStore.langFeedbackSound = $0; model.changed() }
                    )).labelsHidden()
                }
            }
            KelvinCard(L("Дисплей")) {
                SettingsRow("sun.max", L("Яркость экрана")) {
                    Slider(value: settingBinding(
                        get: { Double(ScreenBrightness.get()) },
                        set: { ScreenBrightness.set(Float($0)) }
                    ), in: 0...1)
                    .frame(width: 200)
                }
                CardDivider()
                SettingsRow("lightbulb.min", L("Подсветка клавиатуры")) {
                    Slider(value: settingBinding(
                        get: { Double(KeyboardBacklight.get()) },
                        set: { KeyboardBacklight.set(Float($0)) }
                    ), in: 0...1)
                    .frame(width: 200)
                }
                CardDivider()
                SettingsRow("moon", L("Гасить подсветку при бездействии")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.idleBacklight },
                        set: { SettingsStore.idleBacklight = $0 }
                    )).labelsHidden()
                }
                if SettingsStore.idleBacklight {
                    CardDivider()
                    SettingsRow("timer", L("Задержка")) {
                        Picker("", selection: settingBinding(
                            get: { SettingsStore.idleSeconds },
                            set: { SettingsStore.idleSeconds = $0 }
                        )) {
                            Text("15 " + L("с")).tag(15)
                            Text("30 " + L("с")).tag(30)
                            Text("1 " + L("мин")).tag(60)
                            Text("2 " + L("мин")).tag(120)
                        }
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }
            }
            KelvinCard(L("Ночной режим")) {
                SettingsRow("thermometer.sun", L("Теплота экрана")) {
                    Slider(value: settingBinding(
                        get: { Double(SettingsStore.nightStrength) },
                        set: { v in
                            SettingsStore.nightStrength = Float(v)
                            NightShift.enableNow(strength: Float(v))
                        }
                    ), in: 0...1)
                    .frame(width: 200)
                }
                CardDivider()
                SettingsRow("lightbulb.2", L("Всегда включён")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.nightKeepOn },
                        set: { v in
                            SettingsStore.nightKeepOn = v
                            if v { NightShift.enableNow(strength: SettingsStore.nightStrength) }
                        }
                    )).labelsHidden()
                }
            }
            KelvinCard(L("Сниппеты")) {
                SettingsRow("text.badge.plus", L("Включить сниппеты")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.snippetsEnabled },
                        set: { SettingsStore.snippetsEnabled = $0; LangSwitcher.shared.snippetsEnabled = $0; model.changed() }
                    )).labelsHidden()
                }
                Divider()
                TextEditor(text: $snippets)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(10)
                    .onChange(of: snippets) { value in
                        SettingsStore.snippetsRaw = value
                        LangSwitcher.shared.snippets = SettingsStore.parseSnippets(value)
                    }
            }
        }
        .onAppear { inputStatus = LangSwitcherStatus.current() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputStatus = LangSwitcherStatus.current()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("BMLangRuntimeChanged"))) { _ in
            inputStatus = LangSwitcherStatus.current()
        }
    }

    private var inputPermissionDetail: String {
        switch inputStatus.runtimeStatus {
        case .active:
            return L("Обработка клавиш работает локально на вашем Mac.")
        case .accessibilityDenied:
            return L("Kelvin не запрашивает доступ при запуске. Разрешите его только если хотите использовать автозамену.")
        case .inputMonitoringUnavailable, .tapFailed:
            return L("Универсальный доступ разрешён, но обработчик ввода не запустился. Проверьте «Мониторинг ввода» в настройках macOS.")
        case .missingLayouts:
            return L("Добавьте вторую поддерживаемую раскладку в настройках клавиатуры macOS.")
        case .tapStarting:
            return L("Kelvin запускает локальный обработчик ввода.")
        case .off:
            return L("Обработка ввода выключена.")
        case .unavailableByLicense:
            return L("Функция недоступна без активной лицензии Kelvin Pro.")
        }
    }
}

private struct PopoverSettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel
    @State private var newToggleLabel = ""
    @State private var newToggleIcon = "command"
    @State private var newToggleCmd = ""

    var body: some View {
        VStack(spacing: 18) {
            KelvinCard(L("Внешний вид")) {
                SettingsRow("rectangle.3.group", L("Набор модулей")) {
                    Picker("", selection: settingBinding(
                        get: { currentPopoverPreset() },
                        set: { idx in applyPopoverPreset(idx); model.changed(popover: true) }
                    )) {
                        Text(L("Минимум")).tag(0)
                        Text(L("Сбалансированный")).tag(1)
                        Text(L("Все модули")).tag(2)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                CardDivider()
                SettingsRow("circle.lefthalf.filled", L("Прозрачность"), detail: "\(Int((1 - SettingsStore.popoverOpacity) * 100))%") {
                    Slider(value: settingBinding(
                        get: { SettingsStore.popoverOpacity },
                        set: { SettingsStore.popoverOpacity = $0; model.changed(popover: true) }
                    ), in: 0.18...1.0)
                    .frame(width: 230)
                }
            }
            KelvinCard(L("Модули")) {
                ForEach(Array(SettingsStore.popoverLayout.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { CardDivider() }
                    SettingsRow(moduleSymbol(item.id), PopoverModules.title(item.id)) {
                        Toggle("", isOn: Binding(
                            get: { SettingsStore.popoverLayout.first(where: { $0.id == item.id })?.on ?? false },
                            set: { value in
                                var layout = SettingsStore.popoverLayout
                                if let i = layout.firstIndex(where: { $0.id == item.id }) { layout[i].on = value }
                                SettingsStore.popoverLayout = layout
                                model.changed(popover: true)
                            }
                        )).labelsHidden()
                    }
                }
            }
            // MARK: - Quick Toggles
            KelvinCard(L("Быстрые действия")) {
                ForEach(Array(SettingsStore.toggleLayout.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { CardDivider() }
                    SettingsRow(toggleIcon(item.id), toggleLabel(item.id)) {
                        Toggle("", isOn: Binding(
                            get: { item.on },
                            set: { value in
                                var layout = SettingsStore.toggleLayout
                                if let i = layout.firstIndex(where: { $0.id == item.id }) { layout[i].on = value }
                                SettingsStore.toggleLayout = layout
                                model.changed(popover: true)
                            }
                        )).labelsHidden()
                    }
                    if item.id.hasPrefix("custom:") {
                        HStack(spacing: 6) {
                            Spacer()
                            Button {
                                SettingsStore.deleteCustomToggle(item.id)
                                model.changed(popover: true)
                            } label: {
                                Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                    }
                }
                if Licensing.shared.isPro {
                    CardDivider()
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            TextField(L("Название"), text: $newToggleLabel)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            TextField(L("Команда"), text: $newToggleCmd)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                        }
                        Button(L("Добавить")) {
                            SettingsStore.addCustomToggle(label: newToggleLabel, icon: newToggleIcon, command: newToggleCmd)
                            newToggleLabel = ""
                            newToggleCmd = ""
                            model.changed(popover: true)
                        }
                        .disabled(newToggleLabel.isEmpty || newToggleCmd.isEmpty)
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Popover preset helpers

    private static let presetSets: [[String]] = [
        ["battery", "toggles"],  // Minimum
        Array(PopoverModules.defaultOn), // Balance
        PopoverModules.all.map { $0.id } // Everything
    ]

    private func currentPopoverPreset() -> Int {
        let on = Set(SettingsStore.popoverLayout.filter { $0.on }.map { $0.id })
        for (idx, preset) in Self.presetSets.enumerated() {
            if on == Set(preset) { return idx }
        }
        return -1
    }

    private func applyPopoverPreset(_ idx: Int) {
        guard idx >= 0, idx < Self.presetSets.count else { return }
        let on = Set(Self.presetSets[idx])
        var layout = SettingsStore.popoverLayout
        for i in layout.indices { layout[i].on = on.contains(layout[i].id) }
        SettingsStore.popoverLayout = layout
    }
}

// MARK: - Quick Toggle helpers

private func toggleIcon(_ id: String) -> String {
    if id.hasPrefix("custom:") {
        if let ct = SettingsStore.customToggles.first(where: { $0.id == id }) { return ct.icon }
        return "square"
    }
    switch id {
    case "limit80":  return "battery.75"
    case "topup":    return "bolt.fill"
    case "turbofan": return "fanblades"
    case "panic":    return "exclamationmark.triangle"
    case "caffeine": return "cup.and.saucer"
    default:         return "toggleswitch"
    }
}

private func toggleLabel(_ id: String) -> String {
    if id.hasPrefix("custom:") {
        if let ct = SettingsStore.customToggles.first(where: { $0.id == id }) { return ct.label }
        return L("Пользовательский")
    }
    switch id {
    case "limit80":  return L("Лимит 80%")
    case "topup":    return L("Дозарядка")
    case "turbofan": return L("Турбо-кулеры")
    case "panic":    return L("Аварийный режим")
    case "caffeine": return L("Не засыпать")
    default:         return id
    }
}

private func moduleSymbol(_ id: String) -> String {
    switch id {
    case "battery": return "battery.75"
    case "toggles": return "switch.2"
    case "flow": return "bolt"
    case "hardware": return "cpu"
    case "apps": return "square.grid.2x2"
    case "privacy": return "hand.raised"
    case "maintenance": return "wrench.and.screwdriver"
    case "history": return "chart.xyaxis.line"
    case "disk": return "internaldrive"
    case "btbattery": return "bolt.horizontal.circle"
    case "audio": return "speaker.wave.2"
    case "batteryStats": return "chart.bar"
    default: return "square"
    }
}

private struct NotificationSettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel
    @State private var permission = AlertsEngine.shared.authorizationState

    private var permissionTitle: String {
        switch permission {
        case .authorized: return L("Разрешены при последней проверке")
        case .notDetermined: return L("Разрешение ещё не запрошено")
        case .denied: return L("Отключены в настройках macOS")
        case .unavailable: return L("Состояние разрешения недоступно")
        }
    }

    private var permissionDetail: String {
        switch permission {
        case .authorized: return L("Нажмите «Проверить», чтобы подтвердить доступ и отправить тестовое уведомление.")
        case .notDetermined: return L("Системный запрос появится только после вашего нажатия.")
        case .denied: return L("Откройте настройки macOS, чтобы снова разрешить уведомления.")
        case .unavailable: return L("Kelvin не будет показывать неожиданный системный запрос.")
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            KelvinCard {
                SettingsRow("bell", L("Уведомления Kelvin"), detail: L("Температура, заряд и другие важные состояния.")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.alertsEnabled },
                        set: { on in
                            if on {
                                AlertsEngine.shared.requestOrOpenSettings { granted in
                                    SettingsStore.alertsEnabled = granted
                                    permission = AlertsEngine.shared.authorizationState
                                    model.changed()
                                }
                            } else {
                                SettingsStore.alertsEnabled = false
                                AlertsEngine.shared.onRulesChanged()
                                model.changed()
                            }
                        }
                    )).labelsHidden()
                }
                CardDivider()
                SettingsRow("network.badge.shield.half.filled", L("Новое приложение в сети")) {
                    Toggle("", isOn: settingBinding(
                        get: { SettingsStore.firstConnAlerts },
                        set: { on in
                            if on {
                                AlertsEngine.shared.requestOrOpenSettings { granted in
                                    SettingsStore.firstConnAlerts = granted
                                    permission = AlertsEngine.shared.authorizationState
                                    model.changed()
                                }
                            } else {
                                SettingsStore.firstConnAlerts = false
                                model.changed()
                            }
                        }
                    )).labelsHidden()
                }
            }
            KelvinCard(L("Разрешение системы")) {
                SettingsRow(permission == .authorized ? "checkmark.circle.fill" : "bell.slash",
                            permissionTitle,
                            detail: permissionDetail) {
                    if permission == .authorized {
                        Button(L("Проверить")) {
                            AlertsEngine.shared.sendTest { _ in
                                permission = AlertsEngine.shared.authorizationState
                            }
                        }
                    } else {
                        Button(permission == .denied ? L("Открыть настройки") : L("Разрешить…")) {
                            AlertsEngine.shared.requestOrOpenSettings { _ in
                                permission = AlertsEngine.shared.authorizationState
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            permission = AlertsEngine.shared.authorizationState
        }
    }
}

private struct SecuritySettingsPage: View {
    @ObservedObject var model: KelvinSettingsModel

    var body: some View {
        VStack(spacing: 18) {
            KelvinCard(L("Сетевой экран")) {
                SettingsRow(model.firewallEnabled ? "checkmark.shield.fill" : "exclamationmark.shield",
                            model.firewallAvailable ? L("Встроенный сетевой экран macOS") : L("Сетевой экран недоступен"),
                            detail: model.firewallEnabled ? L("Входящие подключения контролируются.") : L("Входящие подключения не контролируются.")) {
                    Button(L("Открыть настройки")) {
                        MacSystemSettings.openFirewall()
                    }
                    .disabled(!model.firewallAvailable)
                }
                if model.firewallEnabled && model.firewallAvailable {
                    CardDivider()
                    SettingsRow("eye.slash", L("Невидимый режим (Stealth)")) {
                        Image(systemName: model.firewallStealth ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(model.firewallStealth ? .green : .secondary)
                    }
                    CardDivider()
                    SettingsRow("shield.lefthalf.filled", L("Блокировать всё, кроме подписанного")) {
                        Image(systemName: model.firewallBlockAll ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(model.firewallBlockAll ? .green : .secondary)
                    }
                }
            }
            KelvinCard("VPN") {
                SettingsRow("lock.shield", L("Системный профиль"), detail: model.vpnSummary) {
                    Button(L("Обновить")) { model.refreshSecurity() }
                }
                ForEach(Array(model.vpnProfiles.enumerated()), id: \.element.name) { _, profile in
                    CardDivider()
                    SettingsRow("network.badge.shield.half.filled", profile.name,
                                detail: profile.connected ? L("Подключено") : (profile.enabled ? L("Готов к подключению") : L("Отключён в системе"))) {
                        Button(profile.connected ? L("Отключить") : L("Подключить")) {
                            guard SettingsCoordinator.requirePro(.vpn) else { model.refreshSecurity(); return }
                            DispatchQueue.global(qos: .userInitiated).async {
                                if profile.connected { VPN.disconnect(profile.name) }
                                else { VPN.connect(profile.name) }
                                Thread.sleep(forTimeInterval: 0.6)
                                DispatchQueue.main.async { model.refreshSecurity() }
                            }
                        }
                    }
                }
            }
            KelvinCard(L("Активные подключения")) {
                SettingsRow("network", L("Открыть сетевой радар"), detail: L("Подробные подключения доступны в поповере Kelvin.")) {
                    Button(L("Открыть")) {
                        KelvinSettingsWindowController.shared.window?.orderOut(nil)
                        (NSApp.delegate as? AppDelegate)?.openRadarFromAlert()
                    }
                }
            }
        }
    }
}

private struct MaintenanceSettingsPage: View {
    var body: some View {
        VStack(spacing: 18) {
            KelvinCard(L("Системные инструменты")) {
                SettingsRow("trash", L("Очистка временных файлов"), detail: L("Расширенные действия обслуживания доступны из поповера.")) {
                    Text(L("Поповер")).foregroundColor(.secondary)
                }
                CardDivider()
                SettingsRow("stethoscope", L("Диагностика"), detail: L("Соберите отчёт из раздела «О Kelvin».")) {
                    EmptyView()
                }
            }
        }
    }
}

private struct AboutSettingsPage: View {
    var body: some View {
        VStack(spacing: 18) {
            KelvinCard {
                HStack(spacing: 18) {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kelvin").font(.system(size: 21, weight: .bold))
                        Text("Версия " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                            .foregroundColor(.secondary)
                        Text(L("Мониторинг и управление вашим Mac"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
            }
            // MARK: - Updates
            KelvinCard(L("Обновления")) {
                SettingsRow("arrow.triangle.2.circlepath", L("Проверять автоматически")) {
                    Toggle("", isOn: settingBinding(
                        get: { Updater.autoCheck },
                        set: { Updater.autoCheck = $0 }
                    )).labelsHidden()
                }
                CardDivider()
                SettingsRow("arrow.down.circle", L("Проверить сейчас")) {
                    Button(L("Проверить")) { Updater.checkManually() }
                }
            }
            // MARK: - Tools
            KelvinCard(L("Инструменты")) {
                SettingsRow("sparkles", L("Первый запуск")) {
                    Button(L("Показать")) { OnboardingWindowController.shared.present() }
                }
                CardDivider()
                SettingsRow("doc.text.magnifyingglass", L("Диагностический отчёт"), detail: L("Снимок состояния системы для поддержки.")) {
                    Button(L("Создать")) {
                        let log = AppSession.connectionLog()
                        DiagnosticReport.generate(log: log) { md in
                            DispatchQueue.main.async {
                                let panel = NSSavePanel()
                                panel.nameFieldStringValue = "Kelvin-diagnostics.md"
                                panel.allowedContentTypes = [.plainText]
                                panel.begin { resp in
                                    if resp == .OK, let url = panel.url {
                                        try? md.write(to: url, atomically: true, encoding: .utf8)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            // MARK: - Support & Links
            KelvinCard(L("Поддержка")) {
                SettingsRow("heart.fill", L("Поддержать Kelvin"), detail: L("Kelvin бесплатен — и останется таким. Поддержка помогает развитию.")) {
                    Button(L("Поддержать")) { AppConfig.openDonate() }
                }
            }
            KelvinCard {
                SettingsRow("envelope", L("Обратная связь")) {
                    Button(L("Написать")) {
                        if let url = AppConfig.mailto(subject: "Kelvin feedback") { NSWorkspace.shared.open(url) }
                    }
                }
                CardDivider()
                SettingsRow("globe", L("Сайт Kelvin")) {
                    Button(L("Открыть")) { AppConfig.openWebsite() }
                }
                CardDivider()
                SettingsRow("copyright", L("© Tim Blau / Kelvin")) {
                    EmptyView()
                }
            }
        }
    }
}

private struct ProSettingsPage: View {
    @State private var key = ""
    @State private var status = ""
    @State private var activating = false
    @State private var showDeactivateConfirm = false
    @State private var lastCheckDate: Date? = nil
    
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            // MARK: Status Card
            KelvinCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: Licensing.shared.isPro ? "checkmark.seal.fill" : "sparkles")
                            .font(.system(size: 28))
                            .foregroundColor(Licensing.shared.isPro ? .green : .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kelvin Pro")
                                .font(.system(size: 22, weight: .bold))
                            Text(Licensing.shared.statusText)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Divider()
                    
                    // MARK: Status Details
                    VStack(alignment: .leading, spacing: 8) {
                        if !AppConfig.isCommerceEnabled {
                            StatusRow(icon: "checkmark.circle.fill", text: L("Все Pro-функции доступны"), color: .green)
                            StatusRow(icon: "wrench.and.screwdriver", text: L("Покупки включатся после настройки магазина"), color: .secondary)
                        } else if Licensing.shared.activated {
                            StatusRow(icon: "checkmark.circle.fill", text: L("Лицензия активирована"), color: .green)
                            if let instance = Licensing.shared.instanceID {
                                StatusRow(icon: "macbook", text: String(format: L("Mac ID: %@"), String(instance.prefix(8))), color: .secondary)
                            }
                            if let lastCheck = lastCheckDate ?? loadLastCheckDate() {
                                StatusRow(icon: "clock", text: String(format: L("Последняя проверка: %@"), formatter.string(from: lastCheck)), color: .secondary)
                            }
                        } else if Licensing.shared.inTrial {
                            StatusRow(icon: "hourglass", text: String(format: L("Осталось дней триала: %@"), "\(Licensing.shared.trialDaysLeft)"), color: .orange)
                            StatusRow(icon: "calendar", text: String(format: L("До конца: %@"), "\(Licensing.shared.trialDays) \(Licensing.shared.plural(Licensing.shared.trialDays, L("день"), L("дня"), L("дней")))"), color: .secondary)
                        } else {
                            StatusRow(icon: "info.circle.fill", text: L("Мониторинг бесплатен навсегда"), color: .blue)
                            StatusRow(icon: "lock.fill", text: L("Управление требует Pro"), color: .secondary)
                        }
                    }
                    .font(.system(size: 13))
                    
                    // MARK: Purchase Button (only for non-Pro)
                    if !Licensing.shared.isPro && !Licensing.shared.inTrial {
                        Divider()
                        Button(action: openCheckout) {
                            HStack {
                                Image(systemName: "bag.fill")
                                Text(String(format: L("Купить за %@ — навсегда"), AppConfig.proPriceDisplay))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .disabled(!AppConfig.isCheckoutURLValid)
                        
                        if !AppConfig.isCheckoutURLValid {
                            Text(L("Покупка временно недоступна"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        
                        // Trial info
                        VStack(spacing: 6) {
                            Text(String(format: L("%@ на %@"), AppConfig.proPriceDisplay, L("2 Mac")))
                                .font(.system(size: 12, weight: .medium))
                            Text(L("Без подписки • Один платёж"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(
                                String(
                                    format: L("%@ %@"),
                                    L("Включает"),
                                    String(
                                        format: L("триал %d дн."),
                                        Licensing.shared.trialDays
                                    )
                                )
                            )
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(20)
            }
            
            // MARK: Activation Section (only for non-activated)
            if !Licensing.shared.activated {
                // MARK: Activate with Key
                KelvinCard(L("Активация ключом")) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            SecureField(L("Лицензионный ключ"), text: $key)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(size: 13, design: .monospaced))
                            
                            Button(action: pasteFromClipboard) {
                                Image(systemName: "doc.on.doc")
                                    .frame(width: 32, height: 32)
                            }
                            .help(L("Вставить из буфера"))
                            .disabled(key.isEmpty == false)
                        }
                        
                        HStack {
                            Button(action: activateLicense) {
                                HStack {
                                    if activating {
                                        ProgressView()
                                            .controlSize(.small)
                                            .progressViewStyle(.circular)
                                    }
                                    Text(activating ? L("Активация...") : L("Активировать"))
                                }
                                .frame(minWidth: 100)
                            }
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || activating || !Licensing.isStoreConfigured)
                            
                            Spacer()
                            
                            if !status.isEmpty {
                                Text(status)
                                    .font(.system(size: 11))
                                    .foregroundColor(status.hasPrefix("✓") ? .green : .red)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        
                        // Helper text
                        Text(L("Ключ приходит на email после покупки в Lemon Squeezy"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(16)
                }
                
                // MARK: Restore / Links
                KelvinCard {
                    VStack(spacing: 10) {
                        Button(L("Восстановить покупку / Активировать существующую лицензию")) {
                            // Same as activate - user enters key
                            NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                        }
                        .buttonStyle(.borderless)
                        
                        Divider()
                        
                        HStack(spacing: 16) {
                            LinkButton(title: L("Privacy"), url: "https://trykelvin.com/privacy.html")
                            LinkButton(title: L("EULA"), url: "https://trykelvin.com/eula.html")
                            LinkButton(title: L("Support"), url: "mailto:support@trykelvin.com")
                        }
                    }
                    .padding(16)
                }
            }
            
            // MARK: Deactivation (only for activated)
            if Licensing.shared.activated {
                KelvinCard {
                    VStack(spacing: 12) {
                        Text(L("Управление лицензией"))
                            .font(.system(size: 14, weight: .semibold))
                        
                        HStack {
                            Button(action: { showDeactivateConfirm = true }) {
                                Text(L("Деактивировать этот Mac"))
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            
                            Spacer()
                            
                            Button(action: manualRevalidate) {
                                Text(L("Проверить сейчас"))
                            }
                            .buttonStyle(.borderless)
                        }
                        
                        Text(L("Деактивация освободит слот для активации на другом компьютере"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(16)
                }
            }
        }
        .sheet(isPresented: $showDeactivateConfirm) {
            DeactivationConfirmationSheet(
                onConfirm: {
                    showDeactivateConfirm = false
                    performDeactivation()
                },
                onCancel: {
                    showDeactivateConfirm = false
                }
            )
        }
        .onAppear {
            lastCheckDate = loadLastCheckDate()
        }
    }
    
    // MARK: Actions
    
    private func openCheckout() {
        if let url = Licensing.checkoutURL, let realURL = URL(string: url) {
            NSWorkspace.shared.open(realURL)
        }
    }
    
    private func pasteFromClipboard() {
        if let clipboard = NSPasteboard.general.string(forType: .string) {
            key = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    private func activateLicense() {
        activating = true
        status = ""
        Licensing.shared.activate(key) { ok, message in
            DispatchQueue.main.async {
                activating = false
                status = ok ? "✓ " + message : message
                if ok {
                    key = ""  // Clear sensitive data
                    lastCheckDate = Licensing.shared.lastValidatedAt
                    KelvinSettingsWindowController.shared.refresh()
                }
            }
        }
    }
    
    private func performDeactivation() {
        Licensing.shared.deactivate()
        status = L("Деактивировано")
        lastCheckDate = nil
        KelvinSettingsWindowController.shared.refresh()
    }
    
    private func manualRevalidate() {
        status = L("Проверка...")
        Licensing.shared.revalidate { ok in
            lastCheckDate = Licensing.shared.lastValidatedAt
            status = ok ? L("Проверено") : L("Не удалось проверить лицензию")
            KelvinSettingsWindowController.shared.refresh()
        }
    }
    
    private func loadLastCheckDate() -> Date? {
        Licensing.shared.lastValidatedAt
    }
}

// MARK: Helper Views

private struct StatusRow: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color == .secondary ? .gray : color)
                .frame(width: 18)
            Text(text)
                .foregroundColor(color == .secondary ? .secondary : color)
        }
    }
}

private struct LinkButton: View {
    let title: String
    let url: String
    
    var body: some View {
        Button(action: {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        }) {
            Text(title)
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.borderless)
    }
}

private struct DeactivationConfirmationSheet: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void
    
    @State private var confirmText = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text(L("Деактивировать лицензию?"))
                .font(.system(size: 16, weight: .semibold))
            
            Text(L("Это освободит слот активации на этом Mac. Вы сможете активировать снова этим же ключом."))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            HStack {
                Text(L("Введите «деактивировать» для подтверждения:"))
                    .font(.system(size: 11))
                SecureField("", text: $confirmText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(width: 150)
            }
            
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(L("Отмена"))
                        .frame(minWidth: 80)
                }
                .keyboardShortcut(.cancelAction)
                
                Button(action: onConfirm) {
                    Text(L("Деактивировать"))
                        .foregroundColor(.red)
                        .frame(minWidth: 80)
                }
                .disabled(confirmText.lowercased() != L("деактивировать"))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

/// NSVisualEffectView для стабильного нативного sidebar-материала на Big Sur.
private struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
