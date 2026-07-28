//
//  CrashNotificationView.swift
//  Kelvin
//
//  View for notifying the user about a detected crash and requesting consent.
//

import SwiftUI

struct CrashNotificationView: View {
    let report: CrashReport
    let onSend: () -> Void
    let onDecline: () -> Void
    let onPreview: () -> Void
    
    @State private var showingPreview = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.title2)
                
                Text("Kelvin неожиданно завершил работу")
                    .font(.headline)
            }
            
            Text("Мы нашли отчёт о сбое. Вы можете отправить обезличенный отчёт разработчику, чтобы помочь исправить эту ошибку.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button(action: onPreview) {
                    Text("Посмотреть")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                
                Button(action: onSend) {
                    Text("Отправить")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
                
                Button(action: onDecline) {
                    Text("Не отправлять")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .sheet(isPresented: $showingPreview) {
            CrashReportPreviewView(
                report: report,
                onSend: {
                    showingPreview = false
                    onSend()
                },
                onDecline: {
                    showingPreview = false
                    onDecline()
                }
            )
        }
    }
}

#Preview {
    CrashNotificationView(
        report: CrashReport(
            id: "test-id",
            fingerprint: "fp-123",
            state: .discovered,
            appVersion: "1.0.0",
            osVersion: "14.0",
            exceptionType: "EXC_BAD_ACCESS",
            timestamp: Date(),
            filePath: URL(fileURLWithPath: "/tmp/test.ips")
        ),
        onSend: {},
        onDecline: {},
        onPreview: {}
    )
    .padding()
}
