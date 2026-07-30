import Foundation

enum AppEnergySort: Equatable {
    case impact
    case cpu
    case net
}

/// Presentation-логика списка приложений без зависимостей от AppKit и контроллера.
///
/// Сетевую метрику поставляет вызывающая сторона: источник стран живёт в
/// `AppSession`, но алгоритм сортировки не должен знать о глобальном хранилище.
enum AppEnergyPresentation {
    typealias NetworkCount = (AppEnergy) -> Int

    static func networkCountText(
        for app: AppEnergy,
        count: NetworkCount
    ) -> String {
        let value = max(0, count(app))
        return value == 0 ? "—" : String(value)
    }

    static func valueText(
        for app: AppEnergy,
        sort: AppEnergySort,
        networkCount: NetworkCount
    ) -> String {
        switch sort {
        case .impact:
            return AppEnergyFormatting.impact(app.impact)
        case .cpu:
            return app.cpu.map(AppEnergyFormatting.cpu) ?? "—"
        case .net:
            return networkCountText(for: app, count: networkCount)
        }
    }

    static func metric(
        for app: AppEnergy,
        sort: AppEnergySort,
        networkCount: NetworkCount
    ) -> Double {
        switch sort {
        case .impact:
            return app.impact.isFinite ? max(0, app.impact) : 0
        case .cpu:
            guard let cpu = app.cpu, cpu.isFinite else { return 0 }
            return max(0, cpu)
        case .net:
            return Double(max(0, networkCount(app)))
        }
    }

    static func sorted(
        _ apps: [AppEnergy],
        by sort: AppEnergySort,
        networkCount: NetworkCount
    ) -> [AppEnergy] {
        apps.sorted { lhs, rhs in
            let left = metric(for: lhs, sort: sort, networkCount: networkCount)
            let right = metric(for: rhs, sort: sort, networkCount: networkCount)
            if left != right { return left > right }

            // Impact остаётся вторичным сигналом для CPU/сети.
            let leftImpact = lhs.impact.isFinite ? lhs.impact : 0
            let rightImpact = rhs.impact.isFinite ? rhs.impact : 0
            if leftImpact != rightImpact { return leftImpact > rightImpact }

            // Детерминированный последний tie-break предотвращает случайные FLIP-анимации.
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
