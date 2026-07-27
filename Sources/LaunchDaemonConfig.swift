import Foundation

/// Конфигурация Launch Daemon для привилегированного сервиса.
/// Этот файл должен быть скомпилирован как часть ресурсом приложения или скопирован при сборке.
/// Для ServiceManagement (macOS 13+) основной механизм - SMAppService, но наличие plist может требоваться для отладки или legacy.
///
/// В современной архитектуре macOS 13+ мы используем `SMAppService.mainApp.service(forIdentifier:)`,
/// который автоматически находит соответствующий entry point в bundle, если правильно настроены entitlements.
///
/// Однако, для полноты картины и поддержки возможных fallback-механизмов, оставим структуру plist здесь.

let launchDaemonPlistContent: String = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Уникальный идентификатор демона -->
    <key>Label</key>
    <string>com.trykelvin.kelvin.privilegedHelper</string>

    <!-- Путь к исполняемому файлу внутри Bundle.app/Contents/Library/LaunchDaemons/ -->
    <!-- ServiceManagement сам укажет правильный путь, если используется стандартная структура -->
    <key>MachServices</key>
    <dict>
        <key>com.trykelvin.kelvin.privilegedHelper.xpc</key>
        <true/>
    </dict>

    <!-- Запуск от имени root -->
    <key>RunAtLoad</key>
    <true/>

    <!-- Ограничение прав доступа (опционально, но рекомендуется) -->
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.trykelvin.kelvin</string>
    </array>

    <!-- Логирование в систему -->
    <key>StandardOutPath</key>
    <string>/var/log/kelvin-privileged-helper.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/kelvin-privileged-helper-error.log</string>

    <!-- Аргументы командной строки (если нужны) -->
    <!-- <key>ProgramArguments</key>
    <array>
        <string>/path/to/helper</string>
        <string>--verbose</string>
    </array> -->
</dict>
</plist>
"""
