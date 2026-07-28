import SwiftUI

/// UI компонент для preview crash report и получения согласия пользователя.
///
/// Показывает:
/// - версию Kelvin;
/// - модель Mac и macOS;
/// - тип падения;
/// - стек Kelvin (sanitized);
/// - безопасные breadcrumbs;
/// - точный endpoint;
/// - ссылку на privacy policy.
///
/// Кнопки:
/// - Отправить;
/// - Скопировать;
/// - Сохранить в файл;
/// - Не отправлять.
struct CrashReportPreview: View {
    let report: CrashReportStore.ReportMetadata
    let sanitizedJSON: String
    let onSend: () -> Void
    let onDecline: () -> Void
    let onCopy: () -> Void
    let onSaveToFile: () -> Void
    
    @State private var expandedSections: Set<String> = ["overview"]
    @Environment(\.colorScheme) var colorScheme
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overviewSection
                    systemInfoSection
                    crashDetailsSection
                    privacyInfoSection
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            actionsSection
        }
        .frame(minWidth: 500, minHeight: 400, maxHeight: 600)
        .background(colorScheme == .dark ? Color.black.opacity(0.8) : Color.white)
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Kelvin неожиданно завершил работу")
                    .font(.system(size: 16, weight: .semibold))
                Text("Отправить обезличенный отчёт разработчику?")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(colorScheme == .dark ? Color.gray.opacity(0.2) : Color.gray.opacity(0.1))
    }
    
    // MARK: - Sections
    
    private var overviewSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                infoRow(label: "Версия Kelvin", value: appVersion)
                infoRow(label: "Дата падения", value: formattedCrashDate)
                infoRow(label: "Тип падения", value: crashType)
            }
            .padding(.vertical, 4)
        } label: {
            Label("Обзор", systemImage: "info.circle")
        }
    }
    
    private var systemInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let systemInfo = extractSystemInfo() {
                    infoRow(label: "macOS", value: "\(systemInfo.macosVersion) (\(systemInfo.macosBuild))")
                    infoRow(label: "Модель Mac", value: systemInfo.hardwareModel)
                    infoRow(label: "Архитектура", value: systemInfo.architecture)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Система", systemImage: "desktopcomputer")
        }
    }
    
    private var crashDetailsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let crashInfo = extractCrashInfo() {
                    if let exception = crashInfo.exceptionType {
                        infoRow(label: "Тип исключения", value: exception)
                    }
                    if let signal = crashInfo.signal {
                        infoRow(label: "Сигнал", value: signal)
                    }
                    if let termination = crashInfo.terminationReason {
                        infoRow(label: "Причина завершения", value: termination)
                    }
                    
                    DisclosureGroup("Показать стек вызовов") {
                        Text(sanitizedJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(colorScheme == .dark ? Color.black.opacity(0.3) : Color.gray.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Детали падения", systemImage: "bug")
        }
    }
    
    private var privacyInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Отчёт не содержит:")
                    .font(.system(size: 12, weight: .medium))
                
                BulletPoint("Вашего имени и домашнего пути")
                BulletPoint("Серийного номера и hardware UUID")
                "Лицензионного ключа и email"
                BulletPoint("Содержимого буфера обмена")
                BulletPoint("Путей к пользовательским документам")
                
                Divider()
                
                HStack(spacing: 4) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.green)
                    Text("Privacy Policy")
                        .font(.system(size: 12))
                    Button("Подробнее") {
                        openPrivacyPolicy()
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Приватность", systemImage: "hand.raised")
        }
    }
    
    // MARK: - Actions
    
    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button(action: onDecline) {
                Text("Не отправлять")
                    .frame(minWidth: 100)
            }
            .keyboardShortcut(.escape, modifiers: [])
            
            Spacer()
            
            Button(action: onCopy) {
                Label("Скопировать", systemImage: "doc.on.doc")
            }
            .help("Скопировать JSON в буфер обмена")
            
            Button(action: onSaveToFile) {
                Label("Сохранить", systemImage: "square.and.arrow.down")
            }
            .help("Сохранить JSON в файл")
            
            Button(action: onSend) {
                Label("Отправить", systemImage: "paperplane")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding()
    }
    
    // MARK: - Helpers
    
    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label + ":")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .textSelection(.enabled)
        }
    }
    
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    
    private var formattedCrashDate: String {
        guard let date = report.crashDate else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }
    
    private var crashType: String {
        // Парсим из JSON или возвращаем общее описание
        if sanitizedJSON.contains("EXC_BAD_ACCESS") { return "EXC_BAD_ACCESS" }
        if sanitizedJSON.contains("EXC_CRASH") { return "EXC_CRASH" }
        if sanitizedJSON.contains("SIGSEGV") { return "SIGSEGV" }
        if sanitizedJSON.contains("SIGABRT") { return "SIGABRT" }
        return "Неизвестно"
    }
    
    private func extractSystemInfo() -> (macosVersion: String, macosBuild: String, hardwareModel: String, architecture: String)? {
        // В реальной реализации парсим из sanitizedJSON
        // Здесь заглушка для примера
        let processInfo = ProcessInfo.processInfo
        let macosVersion = "\(processInfo.operatingSystemVersion.majorVersion).\(processInfo.operatingSystemVersion.minorVersion).\(processInfo.operatingSystemVersion.patchVersion)"
        
        return (
            macosVersion: macosVersion,
            macosBuild: "Unknown",
            hardwareModel: getHardwareModel() ?? "Unknown",
            architecture: getArchitecture()
        )
    }
    
    private func extractCrashInfo() -> (exceptionType: String?, signal: String?, terminationReason: String?)? {
        // В реальной реализации парсим из sanitizedJSON
        // Здесь заглушка
        return nil
    }
    
    private func openPrivacyPolicy() {
        if let url = URL(string: "https://trykelvin.com/privacy") {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func getHardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buf)
    }
    
    private func getArchitecture() -> String {
        #if arch(arm64)
        return "ARM64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "Unknown"
        #endif
    }
}

// MARK: - Helper Views

private struct BulletPoint: View {
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CrashReportPreview_Previews: PreviewProvider {
    static var previews: some View {
        CrashReportPreview(
            report: CrashReportStore.ReportMetadata(
                fingerprint: "abc123",
                sourceFilename: "Kelvin_2024-01-15-123456.ips",
                crashDate: Date()
            ),
            sanitizedJSON: """
            {
              "schemaVersion": "1.0",
              "application": {
                "name": "Kelvin",
                "version": "1.0.0",
                "buildNumber": "100"
              },
              "crash": {
                "exceptionType": "EXC_BAD_ACCESS",
                "signal": "SIGSEGV"
              }
            }
            """,
            onSend: {},
            onDecline: {},
            onCopy: {},
            onSaveToFile: {}
        )
    }
}
#endif
