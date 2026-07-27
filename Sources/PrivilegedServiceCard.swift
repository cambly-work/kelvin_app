import SwiftUI
import AppKit

/// Карточка статуса привилегированного сервиса в настройках
struct PrivilegedServiceCard: View {
    @ObservedObject var manager: PrivilegedServiceManager
    @State private var isShowingInstallSheet = false
    @State private var isShowingUninstallConfirm = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundColor(statusColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Системные функции Kelvin")
                        .font(.headline)
                    
                    Text(statusDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }
            
            // Capabilities list
            if case .healthy(let info) = manager.state {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Доступные возможности:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    FlowLayout(spacing: 8) {
                        ForEach(info.supportedCapabilities.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { capability in
                            CapabilityBadge(capability: capability)
                        }
                    }
                }
            }
            
            // Actions
            HStack(spacing: 12) {
                switch manager.state {
                case .notInstalled, .incompatible:
                    Button(action: { isShowingInstallSheet = true }) {
                        Label("Установить", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    
                case .approvalRequired:
                    Button(action: openSystemSettings) {
                        Label("Открыть настройки системы", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button(action: { isShowingInstallSheet = true }) {
                        Label("Повторить", systemImage: "arrow.clockwise")
                    }
                    
                case .installing, .repairing, .uninstalling:
                    ProgressView()
                        .scaleEffect(0.8)
                    
                    Text(stateInProgressText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                case .healthy:
                    Button(action: { isShowingUninstallConfirm = true }) {
                        Label("Удалить", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: checkHealth) {
                        Label("Проверить", systemImage: "checkmark.circle")
                    }
                    
                case .updateRequired:
                    Button(action: { isShowingInstallSheet = true }) {
                        Label("Обновить", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    
                case .degraded(let reason):
                    Button(action: { isShowingInstallSheet = true }) {
                        Label("Исправить", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Text(reason.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // Help text
            if let helpText = explanatoryText {
                Text(helpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
        .sheet(isPresented: $isShowingInstallSheet) {
            InstallServiceSheet(manager: manager, isPresented: $isShowingInstallSheet)
        }
        .alert("Удалить системный компонент?", isPresented: $isShowingUninstallConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                Task { await manager.uninstall() }
            }
        } message: {
            Text("Это действие вернёт все настройки в безопасное состояние:\n• Вентиляторы → автоматический режим\n• Лимит заряда → снят\n• Правила фаервола → удалены только правила Kelvin\n• Блокировка доменов → отключена")
        }
    }
    
    // MARK: - Computed Properties
    
    private var statusIcon: String {
        switch manager.state {
        case .notInstalled: return "circle.dashed"
        case .approvalRequired: return "exclamationmark.triangle"
        case .installing, .repairing, .uninstalling: return "arrow.triangle.2.circlepath"
        case .healthy: return "checkmark.circle.fill"
        case .updateRequired: return "arrow.up.circle"
        case .incompatible: return "xmark.octagon"
        case .degraded: return "exclamationmark.bubble"
        }
    }
    
    private var statusColor: Color {
        switch manager.state {
        case .notInstalled: return .gray
        case .approvalRequired: return .orange
        case .installing, .repairing, .uninstalling: return .blue
        case .healthy: return .green
        case .updateRequired: return .orange
        case .incompatible: return .red
        case .degraded: return .yellow
        }
    }
    
    private var statusDescription: String {
        switch manager.state {
        case .notInstalled: return "Привилегированный сервис не установлен"
        case .approvalRequired: return "Требуется подтверждение в системных настройках"
        case .installing: return "Установка сервиса..."
        case .repairing: return "Восстановление сервиса..."
        case .uninstalling: return "Удаление сервиса..."
        case .healthy(let info): return "Сервис активен (v\(info.serviceVersion), протокол \(info.protocolVersion))"
        case .updateRequired: return "Доступно обновление сервиса"
        case .incompatible: return "Несовместимая версия сервиса"
        case .degraded(let reason): return "Сервис работает с ограничениями: \(reason.localizedDescription)"
        }
    }
    
    private var stateInProgressText: String {
        switch manager.state {
        case .installing: return "Установка компонента..."
        case .repairing: return "Восстановление после сбоя..."
        case .uninstalling: return "Удаление и очистка..."
        default: return ""
        }
    }
    
    private var explanatoryText: String? {
        switch manager.state {
        case .notInstalled:
            return "Для работы расширенных функций (управление вентиляторами, лимит заряда, фаервол) требуется однократная установка системного компонента. После установки операции выполняются без повторного ввода пароля."
        case .approvalRequired:
            return "macOS требует подтверждения установки системного расширения. Нажмите «Открыть настройки системы» и разрешите компонент Kelvin в разделе «Основные» → «Разрешения»."
        case .healthy:
            return nil
        case .degraded:
            return "Сервис обнаружил проблему. Рекомендуется нажать «Исправить» для восстановления полной функциональности."
        case .incompatible:
            return "Версия сервиса несовместима с текущим приложением. Требуется переустановка."
        default:
            return nil
        }
    }
    
    // MARK: - Actions
    
    private func openSystemSettings() {
        if #available(macOS 13, *) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.privacySecurity")!)
        } else if #available(macOS 11, *) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.security")!)
        }
    }
    
    private func checkHealth() {
        Task {
            await manager.performHealthCheck()
        }
    }
}

// MARK: - Supporting Views

struct CapabilityBadge: View {
    let capability: Capability
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconForCapability)
                .font(.caption)
            Text(capability.displayName)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .foregroundColor(.blue)
        .cornerRadius(6)
    }
    
    private var iconForCapability: String {
        switch capability {
        case .fanControl: return "fan.fill"
        case .chargeLimit: return "battery.75"
        case .powerMetrics: return "chart.bar.fill"
        case .firewall: return "shield.fill"
        case .hostBlock: return "network.slash"
        case .gpuMode: return "cpu.fill"
        }
    }
}

struct InstallServiceSheet: View {
    @ObservedObject var manager: PrivilegedServiceManager
    @Binding var isPresented: Bool
    @State private var installationStep: InstallationStep = .preflight
    @State private var errorMessage: String?
    
    enum InstallationStep {
        case preflight
        case installing
        case awaitingApproval
        case completing
        case success
        case failed
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: installationStep.icon)
                .font(.system(size: 48))
                .foregroundColor(installationStep.color)
            
            // Title
            Text(installationStep.title)
                .font(.headline)
            
            // Description
            Text(installationStep.description)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            // Progress
            if installationStep == .installing || installationStep == .awaitingApproval {
                ProgressView()
                    .scaleEffect(1.2)
            }
            
            // Error message
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 8)
            }
            
            Spacer()
            
            // Actions
            HStack(spacing: 12) {
                if installationStep == .failed {
                    Button("Закрыть") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)
                    
                    Button("Повторить") {
                        errorMessage = nil
                        startInstallation()
                    }
                    .buttonStyle(.borderedProminent)
                } else if installationStep == .success {
                    Button("Готово") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Отмена") {
                        isPresented = false
                    }
                    .keyboardShortcut(.escape)
                    
                    if installationStep == .preflight {
                        Button("Установить") {
                            startInstallation()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(32)
        .frame(width: 420, height: 380)
        .onAppear {
            if installationStep == .preflight {
                startInstallation()
            }
        }
    }
    
    private func startInstallation() {
        Task {
            installationStep = .installing
            
            do {
                try await manager.install()
                installationStep = .success
            } catch {
                installationStep = .failed
                errorMessage = error.localizedDescription
            }
        }
    }
}

extension PrivilegedServiceManager.InstallationStep {
    var icon: String {
        switch self {
        case .preflight: return "info.circle"
        case .installing: return "arrow.down.circle"
        case .awaitingApproval: return "exclamationmark.triangle"
        case .completing: return "checkmark.circle"
        case .success: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon"
        }
    }
    
    var color: Color {
        switch self {
        case .preflight: return .blue
        case .installing, .completing: return .blue
        case .awaitingApproval: return .orange
        case .success: return .green
        case .failed: return .red
        }
    }
    
    var title: String {
        switch self {
        case .preflight: return "Установка системного компонента"
        case .installing: return "Установка..."
        case .awaitingApproval: return "Требуется подтверждение"
        case .completing: return "Завершение установки..."
        case .success: return "Успешно установлено!"
        case .failed: return "Ошибка установки"
        }
    }
    
    var description: String {
        switch self {
        case .preflight:
            return "Сейчас будет запрошено разрешение на установку системного компонента Kelvin. Это потребуется сделать только один раз.\n\nСервис получит возможность:\n• Управлять вентиляторами\n• Контролировать лимит заряда\n• Настраивать фаервол\n• Блокировать домены"
        case .installing:
            return "Установка привилегированного компонента в систему..."
        case .awaitingApproval:
            return "Откройте Системные настройки и разрешите компонент Kelvin в разделе «Основные» → «Разрешения»."
        case .completing:
            return "Проверка работоспособности сервиса..."
        case .success:
            return "Привилегированный сервис успешно установлен и готов к работе. Теперь вы можете использовать все функции Kelvin без повторного ввода пароля."
        case .failed:
            return "Не удалось установить сервис. Проверьте логи консоли или повторите попытку."
        }
    }
}

// MARK: - Flow Layout for badges

struct FlowLayout<Item: View, ID: Hashable>: View {
    let items: [Item]
    let spacing: CGFloat
    let idKeyPath: KeyPath<Item, ID>
    
    init(spacing: CGFloat = 8, @ViewBuilder content: () -> TupleView<(any View)>) where Item == any View, ID == AnyHashable {
        self.spacing = spacing
        self.idKeyPath = \AnyHashable.self
        
        // Extract items from tuple - simplified for demo
        self.items = []
    }
    
    init(spacing: CGFloat = 8, @ViewBuilder content: () -> some View) where Item == some View, ID == Int {
        self.spacing = spacing
        self.idKeyPath = \Int.self
        self.items = []
    }
    
    // Simplified initializer for array
    init(items: [Item], spacing: CGFloat = 8, id: KeyPath<Item, ID>) {
        self.items = items
        self.spacing = spacing
        self.idKeyPath = id
    }
    
    var body: some View {
        // Simplified flow layout - in production use proper implementation
        ScrollView(.horizontal) {
            HStack(spacing: spacing) {
                ForEach(items, id: idKeyPath) { item in
                    item
                }
            }
        }
    }
}

// MARK: - Capability Extensions

extension Capability {
    var displayName: String {
        switch self {
        case .fanControl: return "Вентиляторы"
        case .chargeLimit: return "Лимит заряда"
        case .powerMetrics: return "Метрики питания"
        case .firewall: return "Фаервол"
        case .hostBlock: return "Блокировка доменов"
        case .gpuMode: return "Режим GPU"
        }
    }
}
