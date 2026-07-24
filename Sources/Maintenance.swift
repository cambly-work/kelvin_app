import Foundation
import Darwin

/// Read-only диагностика раздела «Обслуживание».
///
/// Принципы:
/// - никаких root-операций и сетевых запросов;
/// - системные команды выполняются параллельно и с жёстким timeout;
/// - «пусто» не смешивается с «проверка недоступна» — см. `Posture.availability`;
/// - старые поля `Posture` сохранены, поэтому существующий UI продолжит собираться;
/// - стабильные проверки (SIP/FileVault/XProtect/boot-args) кратковременно кэшируются.
enum Maintenance {

    // MARK: - Public models

    enum SIP: Equatable {
        case enabled
        case disabled
        case custom
        case unknown

        var label: String {
            switch self {
            case .enabled:
                return L("включена")
            case .disabled:
                return L("отключена")
            case .custom:
                return L("ослаблена (Custom Configuration)")
            case .unknown:
                return L("неизвестно")
            }
        }

        /// Акцент только для реально ослабленной защиты.
        var level: Design.Level? {
            switch self {
            case .disabled:
                return .crit
            case .custom:
                return .warn
            case .enabled, .unknown:
                return nil
            }
        }
    }

    enum Thermal: Equatable {
        case nominal
        case fair
        case serious
        case critical
        case unknown

        var label: String {
            switch self {
            case .nominal:
                return L("в норме")
            case .fair:
                return L("умеренная")
            case .serious:
                return L("высокая")
            case .critical:
                return L("критическая")
            case .unknown:
                return L("неизвестно")
            }
        }

        var level: Design.Level? {
            switch self {
            case .serious:
                return .warn
            case .critical:
                return .crit
            case .nominal, .fair, .unknown:
                return nil
            }
        }
    }

    /// Одно ожидающее обновление из локального кэша macOS.
    /// `major == true` означает апгрейд ОС, а не тревогу безопасности.
    struct PendingUpdate: Equatable {
        let name: String
        let major: Bool
    }

    /// Структурированная системная assertion сна.
    struct SleepAssertion: Equatable, Hashable {
        enum Kind: Equatable, Hashable {
            /// Явный запрет сна всей системы.
            case systemSleep

            /// Запрет автоматического сна системы при бездействии.
            case idleSystemSleep

            /// Запрет только отключения дисплея.
            case displaySleep
        }

        let processName: String
        let pid: Int?
        let kind: Kind
        let reason: String?

        /// Только первые два вида действительно мешают сну Mac.
        var blocksSystemSleep: Bool {
            switch kind {
            case .systemSleep, .idleSystemSleep:
                return true
            case .displaySleep:
                return false
            }
        }
    }

    struct CrashRecord: Equatable {
        let processName: String
        let date: Date
    }

    struct CrashSummary: Equatable {
        let count: Int
        let latest: CrashRecord?
    }

    /// Какие проверки реально удалось выполнить.
    ///
    /// Старые поля `sleepBlockers == []`, `crashes7d == 0` и
    /// `pendingUpdates == []` сами по себе не позволяют отличить честный ноль
    /// от ошибки чтения. Для этого UI может использовать эту структуру.
    struct Availability: Equatable {
        let xprotect: Bool
        let sip: Bool
        let fileVault: Bool
        let thermal: Bool
        let sleepAssertions: Bool
        let crashes: Bool
        let bootArgs: Bool
        let updates: Bool
        let memory: Bool

        var isComplete: Bool {
            xprotect
                && sip
                && fileVault
                && thermal
                && sleepAssertions
                && crashes
                && bootArgs
                && updates
                && memory
        }

        static let allAvailable = Availability(
            xprotect: true,
            sip: true,
            fileVault: true,
            thermal: true,
            sleepAssertions: true,
            crashes: true,
            bootArgs: true,
            updates: true,
            memory: true
        )
    }

    struct Posture {
        // Старый публичный контракт — сохранён.
        let xprotect: String?
        let sip: SIP
        let fileVault: Bool?
        let thermal: Thermal
        let sleepBlockers: [String]
        let crashes7d: Int
        let latestCrash: String?
        let bootArgs: String?
        let pendingUpdates: [PendingUpdate]
        let updateChecked: Date?
        let memory: MemoryInfo.State

        // Расширенный контракт для нового UI.
        let sleepAssertions: [SleepAssertion]
        let crashSummary: CrashSummary?
        let availability: Availability

        /// Явный initializer сохраняет совместимость со старым memberwise-вызовом:
        /// новые параметры имеют значения по умолчанию.
        init(
            xprotect: String?,
            sip: SIP,
            fileVault: Bool?,
            thermal: Thermal,
            sleepBlockers: [String],
            crashes7d: Int,
            latestCrash: String?,
            bootArgs: String?,
            pendingUpdates: [PendingUpdate],
            updateChecked: Date?,
            memory: MemoryInfo.State,
            sleepAssertions: [SleepAssertion] = [],
            crashSummary: CrashSummary? = nil,
            availability: Availability = .allAvailable
        ) {
            self.xprotect = xprotect
            self.sip = sip
            self.fileVault = fileVault
            self.thermal = thermal
            self.sleepBlockers = sleepBlockers
            self.crashes7d = crashes7d
            self.latestCrash = latestCrash
            self.bootArgs = bootArgs
            self.pendingUpdates = pendingUpdates
            self.updateChecked = updateChecked
            self.memory = memory
            self.sleepAssertions = sleepAssertions
            self.crashSummary = crashSummary
            self.availability = availability
        }
    }

    // MARK: - Public collection API

    /// Синхронный снимок. Не вызывай на main thread при построении интерфейса.
    static func posture() -> Posture {
        collectPosture(forceStableRefresh: false)
    }

    /// Синхронный снимок с возможностью принудительно обновить стабильные проверки.
    static func posture(forceRefresh: Bool) -> Posture {
        collectPosture(forceStableRefresh: forceRefresh)
    }

    /// Асинхронный снимок: сбор в фоне, completion всегда на main.
    static func posture(completion: @escaping (Posture) -> Void) {
        posture(forceRefresh: false, completion: completion)
    }

    /// Асинхронный снимок с принудительным обновлением стабильных проверок.
    static func posture(
        forceRefresh: Bool,
        completion: @escaping (Posture) -> Void
    ) {
        // Оборачиваем callback в @unchecked Sendable-контейнер: это сохраняет
        // обычную сигнатуру API и одновременно не ломает Swift 6 strict concurrency.
        let callback = CompletionBox(completion)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = collectPosture(forceStableRefresh: forceRefresh)
            let delivery = MainDelivery(
                result: result,
                callback: callback
            )

            DispatchQueue.main.async {
                delivery.perform()
            }
        }
    }

    /// Сброс кэша SIP/FileVault/XProtect/boot-args.
    /// Полезно вызвать после системного действия, которое могло изменить эти параметры.
    static func invalidateCache() {
        stableCache.clear()
    }

    // MARK: - Collection orchestration

    private struct Probe<Value> {
        let value: Value
        let available: Bool
    }

    private struct StableSnapshot {
        let xprotect: Probe<String?>
        let sip: Probe<SIP>
        let fileVault: Probe<Bool?>
        let bootArgs: Probe<String?>
    }

    private struct UpdateSnapshot {
        let updates: [PendingUpdate]
        let checked: Date?
    }

    private static let stableCacheLifetime: TimeInterval = 90

    private static let workerQueue = DispatchQueue(
        label: "com.trykelvin.maintenance.collector",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private static let stableCache = StableCache()

    private static func collectPosture(forceStableRefresh: Bool) -> Posture {
        let stableBox = LockedBox<StableSnapshot?>(nil)
        let sleepBox = LockedBox<Probe<[SleepAssertion]>?>(nil)
        let crashBox = LockedBox<Probe<CrashSummary>?>(nil)
        let updateBox = LockedBox<Probe<UpdateSnapshot>?>(nil)
        let memoryBox = LockedBox<MemoryInfo.State?>(nil)

        let group = DispatchGroup()

        group.enter()
        workerQueue.async {
            stableBox.set(stableSnapshot(forceRefresh: forceStableRefresh))
            group.leave()
        }

        group.enter()
        workerQueue.async {
            sleepBox.set(sleepAssertionsProbe())
            group.leave()
        }

        group.enter()
        workerQueue.async {
            crashBox.set(recentCrashesProbe())
            group.leave()
        }

        group.enter()
        workerQueue.async {
            updateBox.set(macUpdatesProbe())
            group.leave()
        }

        group.enter()
        workerQueue.async {
            memoryBox.set(MemoryInfo.read())
            group.leave()
        }

        let thermal = thermalState()
        group.wait()

        // Все boxes обязаны быть заполнены после group.wait(); fallback оставлен
        // только как защита от будущей ошибки при изменении orchestration.
        let stable = stableBox.get() ?? StableSnapshot(
            xprotect: Probe(value: nil, available: false),
            sip: Probe(value: .unknown, available: false),
            fileVault: Probe(value: nil, available: false),
            bootArgs: Probe(value: nil, available: false)
        )

        let sleep = sleepBox.get()
            ?? Probe(value: [], available: false)

        let crashes = crashBox.get()
            ?? Probe(
                value: CrashSummary(count: 0, latest: nil),
                available: false
            )

        let updates = updateBox.get()
            ?? Probe(
                value: UpdateSnapshot(updates: [], checked: nil),
                available: false
            )

        // `MemoryInfo.read()` исторически возвращает не optional. Если box по
        // какой-либо причине пуст, выполняем один синхронный fallback вместо
        // выдуманного состояния памяти.
        let memory = memoryBox.get() ?? MemoryInfo.read()

        let blockers = uniqueProcessNames(
            sleep.value.filter(\.blocksSystemSleep)
        )

        let latestCrashText = crashes.value.latest.map(formatCrashRecord)

        let availability = Availability(
            xprotect: stable.xprotect.available,
            sip: stable.sip.available,
            fileVault: stable.fileVault.available,
            thermal: thermal != .unknown,
            sleepAssertions: sleep.available,
            crashes: crashes.available,
            bootArgs: stable.bootArgs.available,
            updates: updates.available,
            memory: true
        )

        return Posture(
            xprotect: stable.xprotect.value,
            sip: stable.sip.value,
            fileVault: stable.fileVault.value,
            thermal: thermal,
            sleepBlockers: blockers,
            crashes7d: crashes.value.count,
            latestCrash: latestCrashText,
            bootArgs: stable.bootArgs.value,
            pendingUpdates: updates.value.updates,
            updateChecked: updates.value.checked,
            memory: memory,
            sleepAssertions: sleep.value,
            crashSummary: crashes.value,
            availability: availability
        )
    }

    // MARK: - Stable probes and cache

    private static func stableSnapshot(forceRefresh: Bool) -> StableSnapshot {
        if !forceRefresh,
           let cached = stableCache.value(maxAge: stableCacheLifetime) {
            return cached
        }

        let xprotectBox = LockedBox<Probe<String?>?>(nil)
        let sipBox = LockedBox<Probe<SIP>?>(nil)
        let fileVaultBox = LockedBox<Probe<Bool?>?>(nil)
        let bootArgsBox = LockedBox<Probe<String?>?>(nil)

        let group = DispatchGroup()

        group.enter()
        workerQueue.async {
            xprotectBox.set(xprotectVersionProbe())
            group.leave()
        }

        group.enter()
        workerQueue.async {
            sipBox.set(sipStatusProbe())
            group.leave()
        }

        group.enter()
        workerQueue.async {
            fileVaultBox.set(fileVaultProbe())
            group.leave()
        }

        group.enter()
        workerQueue.async {
            bootArgsBox.set(bootArgsProbe())
            group.leave()
        }

        group.wait()

        let snapshot = StableSnapshot(
            xprotect: xprotectBox.get()
                ?? Probe(value: nil, available: false),
            sip: sipBox.get()
                ?? Probe(value: .unknown, available: false),
            fileVault: fileVaultBox.get()
                ?? Probe(value: nil, available: false),
            bootArgs: bootArgsBox.get()
                ?? Probe(value: nil, available: false)
        )

        stableCache.store(snapshot)
        return snapshot
    }

    // MARK: - XProtect

    private static func xprotectVersionProbe() -> Probe<String?> {
        let candidates = [
            "/private/var/protected/xprotect/XProtect.bundle/Contents/Info.plist",
            "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist",
            "/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        ]

        for path in candidates {
            guard FileManager.default.fileExists(atPath: path),
                  let data = FileManager.default.contents(atPath: path)
            else {
                continue
            }

            guard let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = object as? [String: Any]
            else {
                continue
            }

            if let version = stringValue(
                dictionary["CFBundleShortVersionString"]
                    ?? dictionary["CFBundleVersion"]
            )?.trimmedNonEmpty {
                return Probe(value: version, available: true)
            }
        }

        // Ни один известный plist не дал подтверждённую версию.
        return Probe(value: nil, available: false)
    }

    // MARK: - SIP

    private static func sipStatusProbe() -> Probe<SIP> {
        let result = runCommand(
            "/usr/bin/csrutil",
            ["status"],
            timeout: 4
        )

        guard result.succeeded else {
            return Probe(value: .unknown, available: false)
        }

        let output = result.stdout.lowercased()

        // Проверяем custom раньше enabled/disabled: строка custom-конфигурации
        // может содержать описания отдельных включённых флагов.
        if output.contains("custom") {
            return Probe(value: .custom, available: true)
        }
        if output.contains("disabled") {
            return Probe(value: .disabled, available: true)
        }
        if output.contains("enabled") {
            return Probe(value: .enabled, available: true)
        }

        return Probe(value: .unknown, available: false)
    }

    // MARK: - FileVault

    private static func fileVaultProbe() -> Probe<Bool?> {
        let result = runCommand(
            "/usr/bin/fdesetup",
            ["status"],
            timeout: 5
        )

        guard result.succeeded else {
            return Probe(value: nil, available: false)
        }

        let output = result.stdout.lowercased()

        if output.contains("filevault is on") {
            return Probe(value: true, available: true)
        }
        if output.contains("filevault is off") {
            return Probe(value: false, available: true)
        }

        // Команда ответила, но состояние не укладывается в Bool
        // (например, deferred enablement). Данные доступны, значение неизвестно.
        return Probe(value: nil, available: true)
    }

    // MARK: - boot-args

    private static func bootArgsProbe() -> Probe<String?> {
        let result = runCommand(
            "/usr/sbin/nvram",
            ["boot-args"],
            timeout: 4
        )

        let stdout = result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if result.succeeded {
            guard !stdout.isEmpty else {
                return Probe(value: nil, available: true)
            }

            if let tab = stdout.firstIndex(of: "\t") {
                let value = String(stdout[stdout.index(after: tab)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Probe(
                    value: value.isEmpty ? nil : value,
                    available: true
                )
            }

            // Защита от изменения разделителя: отделяем имя переменной
            // от значения первым блоком whitespace.
            let components = stdout.split(
                maxSplits: 1,
                whereSeparator: { $0.isWhitespace }
            )

            if components.count == 2 {
                let value = String(components[1])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Probe(
                    value: value.isEmpty ? nil : value,
                    available: true
                )
            }

            return Probe(value: nil, available: false)
        }

        // `nvram boot-args` штатно возвращает exit 1, когда переменная не задана.
        // Отличаем это от timeout/launch failure по структурированному результату.
        let stderr = result.stderr.lowercased()
        let variableAbsent = result.exitCode == 1
            && stdout.isEmpty
            && (
                stderr.contains("error getting variable")
                    || stderr.contains("data was not found")
                    || stderr.contains("not found")
            )

        if variableAbsent {
            return Probe(value: nil, available: true)
        }

        return Probe(value: nil, available: false)
    }

    // MARK: - Thermal

    private static func thermalState() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .unknown
        }
    }

    // MARK: - Sleep assertions

    private static func sleepAssertionsProbe() -> Probe<[SleepAssertion]> {
        let result = runCommand(
            "/usr/bin/pmset",
            ["-g", "assertions"],
            timeout: 5
        )

        guard result.succeeded else {
            return Probe(value: [], available: false)
        }

        let output = result.stdout

        guard let marker = output.range(of: "Listed by owning process:") else {
            // Команда выполнена успешно. Отсутствие секции трактуем как
            // отсутствие перечисленных process assertions, а не как ошибку.
            return Probe(value: [], available: true)
        }

        var assertions: [SleepAssertion] = []
        var seen = Set<SleepAssertion>()

        for rawLine in output[marker.upperBound...].split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            guard let assertion = parseSleepAssertion(String(rawLine)) else {
                continue
            }

            if seen.insert(assertion).inserted {
                assertions.append(assertion)
            }
        }

        return Probe(value: assertions, available: true)
    }

    private static func parseSleepAssertion(_ line: String) -> SleepAssertion? {
        guard let namedRange = line.range(of: " named:") else {
            return nil
        }

        let prefix = line[..<namedRange.lowerBound]
        let typeToken = prefix.split(separator: " ").last.map(String.init) ?? ""

        let kind: SleepAssertion.Kind
        switch typeToken {
        case "PreventSystemSleep":
            kind = .systemSleep
        case "PreventUserIdleSystemSleep":
            kind = .idleSystemSleep
        case "PreventUserIdleDisplaySleep":
            kind = .displaySleep
        default:
            return nil
        }

        // Ищем последнее `): `, потому что имя процесса само может содержать `)`.
        guard let pidMarker = line.range(of: "pid "),
              let openParen = line[pidMarker.upperBound...].firstIndex(of: "("),
              let processEnd = line.range(of: "): ", options: .backwards),
              openParen < processEnd.lowerBound
        else {
            return nil
        }

        let pidText = line[pidMarker.upperBound..<openParen]
            .trimmingCharacters(in: .whitespaces)
        let pid = Int(pidText)

        let processName = String(
            line[line.index(after: openParen)..<processEnd.lowerBound]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !processName.isEmpty else {
            return nil
        }

        var reason = String(line[namedRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if reason.hasPrefix("\"") && reason.hasSuffix("\"") && reason.count >= 2 {
            reason.removeFirst()
            reason.removeLast()
        }

        return SleepAssertion(
            processName: processName,
            pid: pid,
            kind: kind,
            reason: reason.isEmpty ? nil : reason
        )
    }

    private static func uniqueProcessNames(
        _ assertions: [SleepAssertion]
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for assertion in assertions {
            let key = assertion.processName.lowercased()
            if seen.insert(key).inserted {
                result.append(assertion.processName)
            }
        }

        return result
    }

    // MARK: - Crash reports

    private static func recentCrashesProbe() -> Probe<CrashSummary> {
        let directory = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

        let files: [String]
        do {
            files = try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )
        } catch {
            return Probe(
                value: CrashSummary(count: 0, latest: nil),
                available: false
            )
        }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let selfNames = ownProcessNames()
        let filenameFormatter = DateFormatter()
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.calendar = Calendar(identifier: .gregorian)
        filenameFormatter.dateFormat = "yyyy-MM-dd-HHmmss"

        var records: [CrashRecord] = []

        for filename in files where filename.hasSuffix(".ips") {
            let fileInfo = crashFilenameInfo(
                filename,
                formatter: filenameFormatter
            )

            // Если дата уверенно извлечена из имени и отчёт старше cutoff,
            // не открываем файл вообще.
            if let date = fileInfo.date, date < cutoff {
                continue
            }

            let url = directory.appendingPathComponent(filename)
            guard let header = readCrashHeader(at: url) else {
                continue
            }

            guard crashBugType(header["bug_type"]) == 309 else {
                continue
            }

            let date = fileInfo.date
                ?? crashTimestamp(header["timestamp"])

            guard let date, date >= cutoff else {
                continue
            }

            let processName = stringValue(
                header["app_name"]
                    ?? header["procName"]
                    ?? header["process"]
            )?.trimmedNonEmpty
                ?? fileInfo.fallbackProcessName

            guard let processName = processName?.trimmedNonEmpty else {
                continue
            }

            if selfNames.contains(processName.lowercased()) {
                continue
            }

            records.append(
                CrashRecord(
                    processName: processName,
                    date: date
                )
            )
        }

        let latest = records.max { lhs, rhs in
            lhs.date < rhs.date
        }

        return Probe(
            value: CrashSummary(
                count: records.count,
                latest: latest
            ),
            available: true
        )
    }

    private static func readCrashHeader(
        at url: URL
    ) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return nil
        }

        let data = handle.readData(ofLength: 16 * 1024)
        try? handle.close()

        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(
                with: Data(firstLine.utf8),
                options: []
              ),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }

        return dictionary
    }

    private static func crashBugType(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    private static func crashFilenameInfo(
        _ filename: String,
        formatter: DateFormatter
    ) -> (date: Date?, fallbackProcessName: String?) {
        let stem = String(filename.dropLast(4))
        let pattern = #"-(\d{4}-\d{2}-\d{2}-\d{6})(?:_|$)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: stem,
                range: NSRange(stem.startIndex..., in: stem)
              ),
              let dateRange = Range(match.range(at: 1), in: stem),
              let fullMatchRange = Range(match.range(at: 0), in: stem)
        else {
            return (
                date: nil,
                fallbackProcessName: stem.trimmedNonEmpty
            )
        }

        let date = formatter.date(from: String(stem[dateRange]))
        let processEnd = fullMatchRange.lowerBound
        let processName = String(stem[..<processEnd]).trimmedNonEmpty

        return (date: date, fallbackProcessName: processName)
    }

    private static func crashTimestamp(_ value: Any?) -> Date? {
        guard let text = stringValue(value)?.trimmedNonEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]

        if let date = iso.date(from: text) {
            return date
        }

        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)

        for format in [
            "yyyy-MM-dd HH:mm:ss.SS Z",
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss.SSSSSS Z"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }

        return nil
    }

    private static func ownProcessNames() -> Set<String> {
        var names = Set<String>()

        names.insert("kelvin")
        names.insert("batterymeter")
        names.insert(ProcessInfo.processInfo.processName.lowercased())

        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            if let name = Bundle.main.object(
                forInfoDictionaryKey: key
            ) as? String,
            let normalized = name.trimmedNonEmpty?.lowercased() {
                names.insert(normalized)
            }
        }

        return names
    }

    private static func formatCrashRecord(_ record: CrashRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.current.rawValue)
        formatter.setLocalizedDateFormatFromTemplate("d MMM")

        let processName: String
        if record.processName.count > 15 {
            processName = String(record.processName.prefix(14)) + "…"
        } else {
            processName = record.processName
        }

        return processName + " · " + formatter.string(from: record.date)
    }

    // MARK: - Software updates

    private static func macUpdatesProbe() -> Probe<UpdateSnapshot> {
        let path = "/Library/Preferences/com.apple.SoftwareUpdate.plist"

        guard let data = FileManager.default.contents(atPath: path),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let dictionary = object as? [String: Any]
        else {
            return Probe(
                value: UpdateSnapshot(updates: [], checked: nil),
                available: false
            )
        }

        let rawUpdates = dictionary["RecommendedUpdates"] as? [[String: Any]]
            ?? []

        var seen = Set<String>()
        var updates: [PendingUpdate] = []

        for record in rawUpdates {
            let identifier = stringValue(record["Identifier"])?.trimmingCharacters(in: .whitespacesAndNewlines)

            let displayName = stringValue(
                record["Display Name"]
                    ?? record["DisplayName"]
                    ?? record["Title"]
            )?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let name = (displayName?.isEmpty == false ? displayName : identifier),
                  !name.isEmpty
            else {
                continue
            }

            let major = boolValue(record["MobileSoftwareUpdate"])
                || boolValue(record["IsMajorOSUpdate"])
                || identifier?.hasSuffix("_major") == true

            let deduplicationKey = name.lowercased()
            guard seen.insert(deduplicationKey).inserted else {
                continue
            }

            updates.append(
                PendingUpdate(name: name, major: major)
            )
        }

        let checked = dateValue(
            dictionary["LastFullSuccessfulDate"]
                ?? dictionary["LastSuccessfulDate"]
        )

        return Probe(
            value: UpdateSnapshot(
                updates: updates,
                checked: checked
            ),
            available: true
        )
    }

    // MARK: - Command runner

    private struct CommandResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32?
        let timedOut: Bool
        let launchError: String?

        var succeeded: Bool {
            !timedOut
                && launchError == nil
                && exitCode == 0
        }
    }

    /// Локальный runner нужен именно здесь, потому что модулю важно различать:
    /// пустой stdout, ненулевой exit code, timeout и launch error.
    private static func runCommand(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval
    ) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(
                stdout: "",
                stderr: "",
                exitCode: nil,
                timedOut: false,
                launchError: String(describing: error)
            )
        }

        let waitResult = finished.wait(
            timeout: .now() + max(0.2, timeout)
        )
        let timedOut = waitResult == .timedOut

        if timedOut, process.isRunning {
            process.terminate()

            if finished.wait(timeout: .now() + 0.35) == .timedOut,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.35)
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let exitCode: Int32?
        if process.isRunning {
            exitCode = nil
        } else {
            exitCode = process.terminationStatus
        }

        return CommandResult(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: exitCode,
            timedOut: timedOut,
            launchError: nil
        )
    }

    // MARK: - Value conversion

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["1", "true", "yes"].contains(string.lowercased())
        default:
            return false
        }
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }

        guard let text = value as? String else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        return iso.date(from: text)
    }

    // MARK: - Thread-safe storage

    private final class CompletionBox: @unchecked Sendable {
        let callback: (Posture) -> Void

        init(_ callback: @escaping (Posture) -> Void) {
            self.callback = callback
        }
    }

    private final class MainDelivery: @unchecked Sendable {
        let result: Posture
        let callback: CompletionBox

        init(result: Posture, callback: CompletionBox) {
            self.result = result
            self.callback = callback
        }

        func perform() {
            callback.callback(result)
        }
    }

    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) {
            storage = value
        }

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        func get() -> Value {
            lock.lock()
            let value = storage
            lock.unlock()
            return value
        }
    }

    private final class StableCache: @unchecked Sendable {
        private struct Entry {
            let createdAt: Date
            let snapshot: StableSnapshot
        }

        private let lock = NSLock()
        private var entry: Entry?

        func value(maxAge: TimeInterval) -> StableSnapshot? {
            lock.lock()
            defer { lock.unlock() }

            guard let entry,
                  Date().timeIntervalSince(entry.createdAt) <= maxAge
            else {
                return nil
            }

            return entry.snapshot
        }

        func store(_ snapshot: StableSnapshot) {
            lock.lock()
            entry = Entry(
                createdAt: Date(),
                snapshot: snapshot
            )
            lock.unlock()
        }

        func clear() {
            lock.lock()
            entry = nil
            lock.unlock()
        }
    }
}

// MARK: - Local helpers

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
