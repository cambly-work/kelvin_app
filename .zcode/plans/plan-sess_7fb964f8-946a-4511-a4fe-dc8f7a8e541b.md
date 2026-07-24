# План исправления: датчики не работают на Big Sur+ и M1+

## Диагностированные корневые причины

1. **Нет Universal Binary** — `build.sh` билдит только под хост-архитектуру (arm64 или x86_64, но не оба)
2. **`kIOMainPortDefault` не существует на Big Sur (11.x)** — символ появился в macOS 12, все IOKit вызовы молча возвращают 0
3. **`AppleSMC` на Apple Silicon (M1+)** — может не открываться или иметь другие ключи датчиков
4. **Нет fallback** — при ошибке SMC-коннекта приложение молча показывает пустые данные

## План реализации

### Шаг 1: Universal Binary в `build.sh`
- Добавить `-arch x86_64 -arch arm64` к команде `xcrun swiftc` (и к fand-билду)
- Swiftc с двумя `-arch` автоматически создаёт fat binary через `lipo`
- Проверить что `swiftc` поддерживает multi-arch (на Xcode 12+, Big Sur+ поддерживает)

### Шаг 2: IOKit port compatibility в новом файле `Sources/IOKitCompat.swift`
- Создать helper-функцию:
  ```swift
  #if canImport(Darwin)
  import IOKit
  @available(macOS 12, *)
  func ioMainPort() -> mach_port_t { kIOMainPortDefault }
  @available(macOS, introduced: 10.12, deprecated: 12.0, renamed: "ioMainPort()")
  func ioMasterPort() -> mach_port_t { kIOMasterPortDefault }
  /// Unified port that works on both Big Sur and Monterey+
  func ioPort() -> mach_port_t {
      if #available(macOS 12, *) { return kIOMainPortDefault }
      else { return kIOMasterPortDefault }
  }
  #endif
  ```
- Заменить **все 6 вызовов** `kIOMainPortDefault` в SMCReader.swift, BatteryReader.swift, USBWatch.swift, MachineID.swift, DiskInfo.swift, fand.swift на `ioPort()`

### Шаг 3: Apple Silicon SMC support в `SMCReader.swift`
- После открытия `AppleSMC` проверить: коннект успешен? Если `IOServiceGetMatchingService` вернул 0:
  - Залогировать предупреждение (OSLog) с информацией о машине (arch, macOS version)
  - На Apple Silicon попробовать альтернативные подходы:
    - `IOServiceMatching("AppleARMIODevice")` — ARM device tree
    - Чтение из `/sys/class/thermal/` (если доступно)
    - `sysctl` ключи (например `kern.hw.optional.arm64`)
    - Парсинг `powermetrics` вывода (уже частично используется через LaunchDaemon)
- Для существующих SMC ключей (TC0D, TC0P, TB0T и т.д.): обернуть чтение в try/catch, при ошибке — пометить датчик как unavailable

### Шаг 4: Graceful fallback и диагностика
- Если SMC недоступен: показать в UI "Сенсоры недоступны на этой машине" вместо пустоты
- Добавить OSLog-диагностику: логировать при старте архитектуру CPU, версию macOS, результат коннекта к SMC
- Это поможет в будущем быстро понять что происходит на конкретной машине

### Шаг 5: Обновить `release.sh`
- Добавить те же `-arch` флаги для release-билда
- Убедиться что `codesign` и notarization работают с Universal Binary

## Файлы для изменения
| Файл | Изменение |
|------|-----------|
| `Sources/IOKitCompat.swift` | **Новый** — helper для порта |
| `Sources/SMCReader.swift` | `kIOMainPortDefault` → `ioPort()`, Apple Silicon fallback |
| `Sources/BatteryReader.swift` | `kIOMainPortDefault` → `ioPort()` |
| `Sources/USBWatch.swift` | `kIOMainPortDefault` → `ioPort()` |
| `Sources/MachineID.swift` | `kIOMainPortDefault` → `ioPort()` |
| `Sources/DiskInfo.swift` | `kIOMainPortDefault` → `ioPort()` |
| `helper/fand.swift` | `kIOMainPortDefault` → `ioPort()` |
| `build.sh` | Добавить `-arch x86_64 -arch arm64` |
| `release.sh` | Добавить `-arch` флаги, проверить notarization |

## Порядок работы
1. Сначала Шаг 2 (IOKitCompat) + замены во всех файлах — это самая быстрая победа
2. Потом Шаг 1 (Universal Binary) — чтобы можно было тестировать на обеих архитектурах
3. Потом Шаг 3 (Apple Silicon SMC) — требует тестирования на реальном M1/M2/M3
4. Шаг 4 (diagnostics) — параллельно с остальным
5. Шаг 5 (release.sh) — последний