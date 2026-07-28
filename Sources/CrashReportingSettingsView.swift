//
//  CrashReportingSettingsView.swift
//  Kelvin
//
//  Settings view for crash reporting preferences.
//

import SwiftUI

struct CrashReportingSettingsView: View {
    @AppStorage("autoSendCrashReports") private var autoSendCrashReports = false
    @StateObject private var store = CrashReportStore.shared
    
    var body: some View {
        Form {
            Section {
                Toggle("Автоматически отправлять обезличенные отчёты о сбоях", isOn: $autoSendCrashReports)
                
                Text("При включении этой настройки Kelvin будет автоматически отправлять отчёты о сбоях после их обнаружения. Вы всегда можете отключить эту настройку.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("Статистика") {
                HStack {
                    Text("Найдено отчётов")
                    Spacer()
                    Text("\(store.allReports.count)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Отправлено")
                    Spacer()
                    Text("\(store.reports(state: .sent).count)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Ожидает отправки")
                    Spacer()
                    Text("\(store.reports(state: .queued).count)")
                        .foregroundColor(.secondary)
                }
            }
            
            Section("Приватность") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Отправляемые данные:")
                        .font(.subheadline)
                    
                    List(CrashReportSanitizer.allowedFields, id: \.self) { field in
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                            Text(field)
                                .font(.caption)
                        }
                    }
                    .frame(height: 200)
                    
                    Text("Никогда не отправляется:")
                        .font(.subheadline)
                        .padding(.top, 8)
                    
                    List([
                        "Полное имя пользователя и домашний путь",
                        "Серийный номер и hardware UUID",
                        "Лицензионный ключ и email",
                        "IP-адрес (на транспортном уровне)",
                        "Содержимое буфера обмена",
                        "Набранный текст и автозаполнение",
                        "Пути к пользовательским документам",
                        "Список открытых окон"
                    ], id: \.self) { item in
                        HStack {
                            Image(systemName: "xmark.shield.fill")
                                .foregroundColor(.red)
                            Text(item)
                                .font(.caption)
                        }
                    }
                    .frame(height: 200)
                }
            }
            
            Section {
                Link("Политика обработки отчётов о сбоях", destination: URL(string: "https://github.com/Kelvin-app/kelvin/blob/main/docs/crash-reporting-policy.md")!)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Отчёты о сбоях")
    }
}

#Preview {
    CrashReportingSettingsView()
}
