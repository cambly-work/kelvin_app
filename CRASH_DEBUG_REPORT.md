# Отчёт по диагностике: Kelvin — краш при запуске после интеграции Sparkle 2.x

## Контекст

В коммите `272e234` (merge `безопасные-обновления-kelvin-db911`) был интегрирован Sparkle 2.9.4 для автообновлений.
После этого приложение перестало собираться и запускаться.

---

## Проблема 1: Ошибка компиляции — `no such module 'Sparkle'`

### Что произошло
`Sources/Updater.swift` содержит `import Sparkle`, но `build.sh` не передаёт флаги поиска фреймворка
компилятору `swiftc`. Фреймворк `Sparkle.framework` копировался в бандл **после** компиляции (строки 27-32),
но на этапе компиляции `swiftc` не мог найти модуль.

### Фикс (`build.sh:19`)
```diff
- xcrun swiftc -O -target "$arch-apple-macos11" $SRCS Sources/main.swift -o "..."
+ xcrun swiftc -O -target "$arch-apple-macos11" -F "$PWD" -framework Sparkle $SRCS Sources/main.swift -o "..."
```

---

## Проблема 2: Ошибки API Sparkle в Updater.swift

При попытке собрать после фикса №1 появились ещё 2 ошибки:

**2a.** `Updater.swift:41` — `controller.canCheckForUpdates`
В Sparkle 2.x свойство `canCheckForUpdates` принадлежит `SPUUpdater`, а не `SPUStandardUpdaterController`.
```diff
- return controller.canCheckForUpdates
+ return controller.updater.canCheckForUpdates
```

**2b.** `Updater.swift:96` — `getSparkle().automaticallyChecksForUpdates = newValue`
`getSparkle()` возвращает тип протокола `UpdateProviding`, и присваивание свойства через результат
функции не компилируется (immutable return value).
```diff
- getSparkle().automaticallyChecksForUpdates = newValue
+ if sparkle == nil { sparkle = SparkleUpdater() }
+ sparkle!.automaticallyChecksForUpdates = newValue
```

---

## Проблема 3: Краш при запуске — `Library not loaded: @rpath/Sparkle.framework`

После успешной компиляции приложение крашилось с `dyld` ошибкой при запуске.

### Почему
`build.sh` копирует `Sparkle.framework` в `Kelvin.app/Contents/Frameworks/` после компиляции, но не добавлял
`@rpath` в бинарник. При запуске `dyld` искал Sparkle только в системных путях (`/usr/lib/swift/`),
а не в `Contents/Frameworks/` бандла.

### Фикс (`build.sh:19`)
```diff
- xcrun swiftc ... -F "$PWD" -framework Sparkle ...
+ xcrun swiftc ... -F "$PWD" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks ...
```

После этого `otool -l` показывает `LC_RPATH: @executable_path/../Frameworks` — `dyld` теперь находит фреймворк.

---

## Проблема 4 (НЕ РЕШЕНА): SIGSEGV при запуске — UserNotifications callback

После исправления проблем 1-3 приложение собирается и Sparkle загружается корректно, но происходит
краш `EXC_BAD_ACCESS (SIGSEGV)` at address `0x0` (nil pointer dereference).

### Симптомы
- **Exit code 139** (SIGSEGV)
- **NSZombieEnabled=YES** предотвращает краш → типичный use-after-free
- Краш через `UserNotifications` → `libdispatch` → main queue callback

### Backtrace (символизированный, debug binary без `-O`):

**Два разных crash site-а:**

1. **`OnboardingWindowController.refreshPermissionStatus()`** — вызывается через
   `UNUserNotificationCenter.current().getNotificationSettings { callback }`.
   Асинхронный callback обращается к UI-элементам Onboarding-окна (`notifButton`, `notifStatus`),
   которые могут быть уже освобождены.

2. **`AlertsEngine.start()`** — вызов `UNUserNotificationCenter.current().delegate = self`
   или `setNotificationCategories()`.

### Оптимизатор запутал диагностику

Сборка с `-O` (оптимизация, используется в `build.sh`) показывает **неверный backtrace** —
краш из Onboarding атрибутируется к `AlertsEngine.start()` из-за inlining.
Только сборка с `-g` (debug, без `-O`) показала настоящий источник: **OnboardingWindowController**.

### Почему краш начался именно после интеграции Sparkle

На данный момент **причина не установлена до конца**. Текущие гипотезы:

1. **Конфликт delegate-ов UNUserNotificationCenter.** Sparkle 2.x с `SUEnableAutomaticChecks=true`
   в Info.plist автоматически инициализирует `SPUUpdater` при загрузке приложения. Sparkle может
   устанавливать свой `UNUserNotificationCenterDelegate`, а затем `AlertsEngine.start()` и
   `OnboardingWindowController.startPermissionPolling()` тоже работают с тем же `UNUserNotificationCenter`.
   Pending callbacks могут вызываться на неверном объекте.

2. **Вероятнее всего:** краш existed и раньше в `OnboardingWindowController`, но раньше не воспроизводился
   потому что `applicationDidFinishLaunching` → Onboarding callback вызывался в другом порядке.
   Добавление Sparkle изменило время загрузки framework-ов и timing `UNUserNotificationCenter` callbacks,
   что вывело latent bug наружу.

### Почему `[weak self] + guard` не помог

Исправление `{ [weak self] s in ... guard let self, self.window?.isVisible == true else { return } }`
в `OnboardingWindowController.refreshPermissionStatus()` не остановило краш, потому что:
- краш происходит **не** после закрытия окна
- краш происходит **при первом вызове** `getNotificationSettings` сразу после `present()`
- проблема может быть в самом ObjC bridge UserNotifications framework или в nil-дереференсе
  внутри `UNUserNotificationCenter.current()` на данной версии macOS

### Текущий статус — приложение работает если:
- `Onboarding` отключён (`if false { ... present() }`)
- `AlertsEngine.start()` вызывается (delegate + categories работают без краша)

---

## Что сделано и откатано

### Фиксы, которые остаются (в `build.sh` и `Updater.swift`):
1. ✅ `build.sh:19` — добавлены `-F "$PWD" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks`
2. ✅ `Updater.swift:41` — `controller.updater.canCheckForUpdates`
3. ✅ `Updater.swift:96` — прямой доступ к `sparkle!` вместо `getSparkle()`

### Временные отладочные изменения (нужно откатить перед коммитом):
- `main.swift` — Onboarding отключён через `if false { ... }`
- `Onboarding.swift:232-236` — добавлен `[weak self] + guard` в callback
- `Onboarding.swift:34-38` — nil-out `notifButton/notifStatus/axButton/axStatus` при закрытии

### Удалённые файлы:
- `Sources/SparkleStub.swift` — временная заглушка, удалена

---

## Рекомендации

1. **Краш Onboarding** — investigate глубже с `lldb` или Instruments (Zombie tracking).
   Либо воспроизвести на версии до Sparkle-интеграции, чтобы понять, это old bug или новый.

2. **SUPublicEDKey** — в `Info.plist` стоит placeholder `<!-- INSERT_PUBLIC_ED_KEY_HERE -->`.
   Sparkle будет отвергать все обновления без валидного EdDSA публичного ключа.

3. **build.sh** — стоит добавить `-g` (debug info без -O) хотя бы для debug-варианта,
   потому что сейчас `strip -x` убирает все символы, и краш-репорты невозможно символизировать.
   Вместо `swiftc -O` для debug можно использовать `swiftc -O -g` или отдельный target.
