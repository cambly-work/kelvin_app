import Foundation

/// Чистое форматирование метрик вкладки «Приложения».
///
/// Форматы единиц передаются снаружи, чтобы модуль не зависел от глобального
/// словаря локализации и оставался пригодным для изолированных unit-тестов.
enum AppEnergyFormatting {
    static func memory(
        megabytes: Double,
        megabytesFormat: String,
        gigabytesFormat: String
    ) -> String {
        guard megabytes.isFinite, megabytes >= 0 else { return "—" }
        if megabytes < 1024 {
            return String(format: megabytesFormat, megabytes)
        }
        return String(format: gigabytesFormat, megabytes / 1024)
    }

    static func impact(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    static func cpu(_ percent: Double) -> String {
        guard percent.isFinite else { return "—" }
        return String(format: "%.0f%%", percent)
    }
}
