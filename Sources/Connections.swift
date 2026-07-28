import AppKit
import Darwin   // proc_pidpath

/// Одно активное соединение (исходящее/установленное).
struct NetConn {
    let proto: String        // TCP/UDP
    let remoteIP: String
    let remotePort: Int
    var label: String { "\(remoteIP):\(remotePort)" }
}

/// Один слушающий сокет (TCP LISTEN) — «открытый порт» = поверхность для входящих.
/// ЧЕСТНОСТЬ: `reachable` = привязка к НЕ-loopback адресу (виден в вашей сети). Это НЕ значит
/// «доступен из интернета» — NAT/фаервол могут не пускать. Мы только различаем loopback / не-loopback.
struct ListenSock {
    let proto: String        // TCP (UDP-байнды не считаем «слушающими» — иначе mDNS-шум и путаница)
    let addr: String         // "*", "0.0.0.0", "::", "127.0.0.1", "::1" или конкретный адрес интерфейса
    let port: Int
    /// только этот Mac: loopback IPv4 (127.0.0.0/8) или IPv6 ::1 (в т.ч. IPv4-mapped ::ffff:127.x).
    var loopback: Bool {
        let a = addr.hasPrefix("::ffff:") ? String(addr.dropFirst(7)) : addr   // IPv4-mapped-IPv6 → чистый IPv4
        return a == "127.0.0.1" || a.hasPrefix("127.") || a == "::1" || addr == "::1"
    }
    /// виден в вашей сети: привязка к не-loopback адресу (wildcard ИЛИ конкретный интерфейс)
    var reachable: Bool { !loopback }
    /// wildcard-формы (пусто/0.0.0.0/::) канонизируем в "*" — один логический «все интерфейсы»,
    /// чтобы IPv4+IPv6 привязки одного порта не двоились в счётчике и разборе.
    var label: String {
        let a = (addr.isEmpty || addr == "0.0.0.0" || addr == "::") ? "*" : addr
        return a + ":" + String(port)
    }
}

/// Приложение и его соединения (хелперы свёрнуты под родительское .app).
struct AppNet {
    let name: String
    let icon: NSImage?
    let appPath: String?     // путь к .app (для блока через фаервол); nil у демонов/бинарей
    let conns: [NetConn]
    let listens: [ListenSock]   // слушающие TCP-порты этого приложения (сегмент «Порты»)
}

/// Сырьё одного PID: только фон-безопасные данные (POSIX, никакого AppKit).
/// Резолв имени/иконки/.app откладывается на main (см. `resolveOnMain`).
struct RawProc {
    let pid: Int
    let exePath: String       // proc_pidpath — thread-safe POSIX
    let conns: [NetConn]
    let listens: [ListenSock]
}

/// Инспектор подключений: кто сейчас в сети и куда (через lsof, без перехвата).
/// Read-only — не фильтр; «закрыть доступ» делается существующим фаерволом/hosts.
///
/// ПОТОЧНАЯ МОДЕЛЬ (B1): AppKit-резолв (NSWorkspace/NSRunningApplication/FileManager.displayName/.icon)
/// — main-only. Поэтому снимок разбит на две фазы:
///   • `rawSnapshot()` — ТОЛЬКО фон-безопасное: lsof-shell, парс, proc_pidpath. Зовётся из фон-очереди.
///   • `resolveOnMain(_:)` — ТОЛЬКО main: имена/иконки/.app + свёртка+сортировка. Зовётся из main.
/// Дедлока нет: нигде нет `DispatchQueue.main.sync`; main-фаза доставляется обычным `async`.
enum Connections {
    /// ФОН-фаза: сырые PID→(соединения + слушающие порты). Никакого AppKit — можно с любой очереди.
    static func rawSnapshot() -> [RawProc] {
        let out = shell("/usr/sbin/lsof", ["-i", "-nP", "-w"])
        var connByPid: [Int: [NetConn]] = [:]
        var lsnByPid: [Int: [ListenSock]] = [:]
        for line in out.split(separator: "\n").dropFirst() {       // dropFirst — заголовок
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 9, let pid = Int(t[1]) else { continue }
            let proto = t[7]
            guard proto == "TCP" || proto == "UDP" else { continue }
            let name = t[8]
            let state = t.count >= 10 ? t[9] : ""
            if let arrow = name.range(of: "->") {                      // установленное/исходящее — с удалённым пиром
                guard let (ip, port) = parseEndpoint(String(name[arrow.upperBound...])) else { continue }
                if proto == "TCP" {                                    // только установленные TCP
                    guard state.contains("ESTABLISHED") else { continue }
                }
                connByPid[pid, default: []].append(NetConn(proto: proto, remoteIP: ip, remotePort: port))
            } else if proto == "TCP", state.contains("LISTEN") {       // слушающий TCP-сокет — открытый порт
                guard let (addr, port) = parseEndpoint(name) else { continue }
                lsnByPid[pid, default: []].append(ListenSock(proto: "TCP", addr: addr, port: port))
            }
        }
        let pids = Set(connByPid.keys).union(lsnByPid.keys)
        return pids.map { pid in
            RawProc(pid: pid, exePath: exePath(pid), conns: connByPid[pid] ?? [], listens: lsnByPid[pid] ?? [])
        }
    }

    /// MAIN-фаза: сырьё → приложения. AppKit-резолв (имена/иконки/.app) — только здесь.
    /// Свёртка под .app и сортировка идентичны прежней `snapshot()`.
    static func resolveOnMain(_ raw: [RawProc]) -> [AppNet] {
        assert(Thread.isMainThread, "resolveOnMain должен исполняться на main (AppKit-резолв)")
        struct Acc { var name: String; var icon: NSImage?; var appPath: String?; var conns: [NetConn]; var listens: [ListenSock] }
        var byApp: [String: Acc] = [:]
        for rp in raw {
            let id = resolveApp(rp.pid, exe: rp.exePath)
            let key = id.appPath ?? id.name
            byApp[key, default: Acc(name: id.name, icon: id.icon, appPath: id.appPath, conns: [], listens: [])].conns += rp.conns
            byApp[key]!.listens += rp.listens
        }
        return byApp.values.map { a in
            var seen = Set<String>()
            let uniq = a.conns.filter { seen.insert($0.label).inserted }
            var lseen = Set<String>()
            let luniq = a.listens.filter { lseen.insert($0.proto + $0.label).inserted }   // IPv4/IPv6 одного *:порт — раз
            return AppNet(name: a.name, icon: a.icon, appPath: a.appPath, conns: uniq, listens: luniq)
        }.sorted { $0.conns.count > $1.conns.count }
    }

    /// Полный снимок = фон-фаза + main-резолв. Оставлен как удобный фасад ТОЛЬКО для main-контекста.
    /// Фон-вызовы обязаны использовать `rawSnapshot()`+`resolveOnMain()` раздельно (см. B1).
    static func snapshot() -> [AppNet] {
        assert(Thread.isMainThread, "Connections.snapshot() — main-only фасад; в фоне используйте rawSnapshot()+resolveOnMain()")
        return resolveOnMain(rawSnapshot())
    }

    /// Путь исполняемого файла PID — thread-safe POSIX, безопасно в фоне.
    private static func exePath(_ pid: Int) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(Int32(pid), &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    /// Имя процесса (как его печатает `top`/`ps`) → иконка + чистое имя приложения.
    /// Сопоставляем со списком запущенных приложений (по localizedName и по имени бинаря),
    /// чтобы поднять .icon и аккуратное отображаемое имя. Нет совпадения → (nil, исходное имя).
    static func resolveByName(_ proc: String) -> (icon: NSImage?, name: String) {
        assert(Thread.isMainThread, "resolveByName трогает NSWorkspace.runningApplications — main-only")
        let needle = proc.lowercased()
        for ra in NSWorkspace.shared.runningApplications {
            if let ln = ra.localizedName, ln.lowercased() == needle {
                return (ra.icon, ln)
            }
        }
        // запасной проход: имя процесса = имя исполняемого файла внутри .app
        for ra in NSWorkspace.shared.runningApplications {
            guard let exe = ra.executableURL?.lastPathComponent else { continue }
            if exe.lowercased() == needle {
                return (ra.icon, ra.localizedName ?? proc)
            }
        }
        // Helper/WebContent-процессы и сгруппированные названия должны сохранять настоящую иконку
        // родительского .app. Сначала мягко сопоставляем с уже запущенным приложением.
        let family = needle
            .replacingOccurrences(of: " helper", with: "")
            .replacingOccurrences(of: " web content", with: "")
        for ra in NSWorkspace.shared.runningApplications {
            guard let ln = ra.localizedName?.lowercased() else { continue }
            if ln.hasPrefix(family) || family.hasPrefix(ln) {
                return (ra.icon, ra.localizedName ?? proc)
            }
        }
        // Известные Electron/browser family могут иметь бинарь, не совпадающий с display name.
        let knownBundles: [(prefixes: [String], id: String)] = [
            (["visual studio code", "code"], "com.microsoft.VSCode"),
            (["firefox"], "org.mozilla.firefox"),
            (["google chrome", "chrome"], "com.google.Chrome"),
            (["chatgpt"], "com.openai.chat"),
            (["safari"], "com.apple.Safari"),
        ]
        if let hit = knownBundles.first(where: { entry in entry.prefixes.contains { needle.hasPrefix($0) } }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: hit.id) {
            return (NSWorkspace.shared.icon(forFile: url.path),
                    FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        return (nil, proc)
    }

    /// PID → приложение: по реальному пути исполняемого файла находим внешний .app
    /// (так хелперы браузера сворачиваются под родителя и получают имя+иконку).
    /// MAIN-only: трогает FileManager.displayName/NSWorkspace.icon/NSRunningApplication.
    /// `exe` передаётся заранее (получен в фоне через proc_pidpath) — сам путь тут не читаем.
    private static func resolveApp(_ pid: Int, exe: String) -> (name: String, icon: NSImage?, appPath: String?) {
        if let r = exe.range(of: ".app/") {
            let appPath = String(exe[exe.startIndex..<r.lowerBound]) + ".app"
            let dn = FileManager.default.displayName(atPath: appPath)
            let name = dn.hasSuffix(".app") ? String(dn.dropLast(4)) : dn
            return (name, NSWorkspace.shared.icon(forFile: appPath), appPath)
        }
        if !exe.isEmpty { return ((exe as NSString).lastPathComponent, nil, nil) }   // демон/бинарь
        if let ra = NSRunningApplication(processIdentifier: pid_t(pid)) {
            return (ra.localizedName ?? "PID \(pid)", ra.icon, ra.bundleURL?.path)
        }
        return ("PID \(pid)", nil, nil)
    }

    /// Разбор удалённого адреса: IPv4 `1.2.3.4:443` или IPv6 `[2607::1]:443`.
    private static func parseEndpoint(_ s: String) -> (String, Int)? {
        if s.hasPrefix("[") {
            guard let close = s.range(of: "]:") else { return nil }
            return (String(s[s.index(after: s.startIndex)..<close.lowerBound]), Int(s[close.upperBound...]) ?? 0)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        return (String(s[..<colon]), Int(s[s.index(after: colon)...]) ?? 0)
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        ProcessRunner.output(path, args, timeout: 8)
    }
}
