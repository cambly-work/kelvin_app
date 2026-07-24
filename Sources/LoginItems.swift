import Foundation

/// Инвентарь автозапуска: агенты/демоны launchd, читаемые БЕЗ root и БЕЗ полного доступа к диску.
///
/// ЧЕСТНОСТЬ (закон продукта):
///  • Показываем ТОЛЬКО то, что реально прочли из ~/Library и /Library (мир-читаемые каталоги).
///    /System/Library НЕ трогаем — это Apple-системное, не действие пользователя.
///  • Факты берём из САМИХ plist: Label, Program/ProgramArguments, RunAtLoad. Ничего не выдумываем.
///  • `runAtLoad` — честный флаг «стартует при загрузке» из файла. Его ОТСУТСТВИЕ не значит «не запускается»:
///    агент может стартовать и по другим триггерам (StartInterval/WatchPaths/KeepAlive). Поэтому мы
///    помечаем ТОЛЬКО положительный случай и оговариваем это в UI.
///  • Состояние «включён/выключён» (Login Items macOS / база BTM) требует Full Disk Access — НЕ показываем.
enum LoginItems {
    enum Scope { case userAgent, globalAgent, systemDaemon }

    struct Item {
        let name: String        // Label из plist или имя файла
        let program: String     // Program или ProgramArguments[0] — путь бинаря ("" если нет)
        let scope: Scope
        let runAtLoad: Bool      // явный RunAtLoad из plist
        let disabled: Bool      // явный Disabled=true в самом файле (частичный сигнал — override-БД мы не читаем)
        let path: String        // путь к .plist (для «Показать в Finder»)
    }

    /// Результат скана: прочитанные элементы + сколько *.plist НЕ удалось прочесть/распарсить
    /// (напр. root-only права или битый файл) — чтобы счётчик не выдавал список за полный каталог.
    struct ScanResult { let items: [Item]; let skipped: Int }

    /// Синхронное сканирование (несколько небольших каталогов + мелкие plist). Для окна настроек — в фоне.
    static func scan() -> ScanResult {
        let home = NSHomeDirectory()
        let dirs: [(String, Scope)] = [
            (home + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .systemDaemon),
        ]
        let fm = FileManager.default
        var out: [Item] = []
        var skipped = 0
        for (dir, scope) in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }   // нет каталога/прав → пропускаем честно
            for f in files where f.hasSuffix(".plist") {
                let path = dir + "/" + f
                guard let data = fm.contents(atPath: path),
                      let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dict = obj as? [String: Any] else { skipped += 1; continue }   // не прочли (root-only/битый) — честно считаем
                let label = (dict["Label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(f.dropLast(6))
                var program = (dict["Program"] as? String) ?? ""
                if program.isEmpty, let args = dict["ProgramArguments"] as? [String], let first = args.first { program = first }
                let runAtLoad = (dict["RunAtLoad"] as? Bool) ?? false
                let disabled = (dict["Disabled"] as? Bool) ?? false
                out.append(Item(name: label, program: program, scope: scope, runAtLoad: runAtLoad, disabled: disabled, path: path))
            }
        }
        // стартующие при загрузке — вперёд; далее по имени (детерминированно)
        let items = out.sorted {
            if $0.runAtLoad != $1.runAtLoad { return $0.runAtLoad }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        return ScanResult(items: items, skipped: skipped)
    }

    /// Асинхронно: скан в фоне, результат — на main (окно настроек не подвисает на I/O).
    static func scan(completion: @escaping (ScanResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = scan()
            DispatchQueue.main.async { completion(r) }
        }
    }
}
