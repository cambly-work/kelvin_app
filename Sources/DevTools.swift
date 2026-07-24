import Foundation
import AppKit

/// Каталог инструментов для разработчиков: установка через Homebrew одним кликом.
/// brew работает от пользователя (без root); длинные установки открываются в Терминале
/// с живым выводом. Авто-детект brew и уже установленных инструментов (галочки).
enum DevTools {
    struct Tool {
        let name: String        // отображаемое имя
        let pkg: String         // имя формулы/каска brew
        let cask: Bool          // true → brew install --cask
        let check: String?      // путь для отметки «установлено» (.app или бинарь в префиксе)
    }

    static let brewPrefixes = ["/opt/homebrew", "/usr/local"]   // Apple Silicon / Intel
    static var brewPath: String? {
        brewPrefixes.map { "\($0)/bin/brew" }.first { FileManager.default.fileExists(atPath: $0) }
    }
    static var brewInstalled: Bool { brewPath != nil }
    private static var prefix: String {
        brewPrefixes.first { FileManager.default.fileExists(atPath: "\($0)/bin/brew") } ?? "/usr/local"
    }

    /// bin-путь в текущем префиксе brew.
    private static func bin(_ name: String) -> String { "\(prefix)/bin/\(name)" }

    static let categories: [(title: String, tools: [Tool])] = [
        ("Редакторы и IDE", [
            Tool(name: "Visual Studio Code", pkg: "visual-studio-code", cask: true, check: "/Applications/Visual Studio Code.app"),
            Tool(name: "Cursor",             pkg: "cursor",             cask: true, check: "/Applications/Cursor.app"),
            Tool(name: "Sublime Text",       pkg: "sublime-text",       cask: true, check: "/Applications/Sublime Text.app"),
            Tool(name: "iTerm2",             pkg: "iterm2",             cask: true, check: "/Applications/iTerm.app"),
            Tool(name: "Warp",               pkg: "warp",               cask: true, check: "/Applications/Warp.app"),
        ]),
        ("Языки и среды", [
            Tool(name: "Node.js",  pkg: "node",   cask: false, check: nil),
            Tool(name: "Python 3", pkg: "python", cask: false, check: nil),
            Tool(name: "Go",       pkg: "go",     cask: false, check: nil),
            Tool(name: "Rust",     pkg: "rust",   cask: false, check: nil),
            Tool(name: "Deno",     pkg: "deno",   cask: false, check: nil),
            Tool(name: "pnpm",     pkg: "pnpm",   cask: false, check: nil),
        ]),
        ("Инструменты", [
            Tool(name: "Git",            pkg: "git",    cask: false, check: nil),
            Tool(name: "GitHub CLI",     pkg: "gh",     cask: false, check: nil),
            Tool(name: "Docker Desktop", pkg: "docker", cask: true,  check: "/Applications/Docker.app"),
            Tool(name: "wget",           pkg: "wget",   cask: false, check: nil),
            Tool(name: "jq",             pkg: "jq",     cask: false, check: nil),
            Tool(name: "htop",           pkg: "htop",   cask: false, check: nil),
        ]),
    ]

    /// Установлен ли инструмент: для каска — наличие .app, для формулы — бинарь в префиксе.
    static func isInstalled(_ t: Tool) -> Bool {
        let path = t.check ?? bin(t.pkg)
        return FileManager.default.fileExists(atPath: path)
    }

    /// Команда установки через brew.
    static func installCommand(_ t: Tool) -> String? {
        guard let brew = brewPath else { return nil }
        return "\(brew) install \(t.cask ? "--cask " : "")\(t.pkg)"
    }

    static let homebrewInstall = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""

    /// Запустить команду в новом окне Терминала (живой вывод). Требует разрешения «Автоматизация».
    static func runInTerminal(_ cmd: String) {
        let esc = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let src = "tell application \"Terminal\"\nactivate\ndo script \"\(esc)\"\nend tell"
        NSAppleScript(source: src)?.executeAndReturnError(nil)
    }
}
