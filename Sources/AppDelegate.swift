//
//  AppDelegate.swift
//  Kelvin
//
//  Делегат приложения: status item, menu-bar, tick-оркестратор. Извлечён из main.swift.
//

import AppKit
import CoreAudio
import ServiceManagement


// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    private var popoverAnchor: NSWindow?     // неподвижный якорь поповера (фикс «съезда» в полноэкранном)
    private var postedMenuTracking = false   // послан ли begin-меню-трекинг (fullscreen-путь) — снять на закрытии
    let controller = PopoverController()
    var history: [Double] = []
    var tickTimer: Timer?
    var appsTimer: Timer?
    var idleTimer: Timer?
    private var statusAnimationTimer: Timer?
    private var statusAnimationPhase = 0
    private var lastStatusBattery = BatteryInfo.absent
    private var lastStatusEnergy = EnergySnapshot()
    private var hasStatusSnapshot = false
    private var menuBarCPULoad: Double = 0
    private var menuBarRAMLoad: Double = 0
    let usbWatch = USBWatch()             // живой USB-ридер (lifetime-инстанс, рег. при старте)
    var idleDimmed = false
    var savedBacklight: Float = -1
    var nightTick = 0
    private let hardwareQueue = DispatchQueue(label: "com.trykelvin.kelvin.hardware",
                                              qos: .userInitiated)
    private var hardwareTickInFlight = false
    private var lastMenuTitle = ""        // чтобы не переустанавливать заголовок строки без изменений
    private var lastMenuImgKey = ""
    private var pendingCrashReports: [CrashReportStore.ReportMetadata] = []
    private var presentingCrashReport = false

    /// Мгновенно применить настройки строки меню: сброс кэша рендера → безусловная перерисовка
    /// СЕЙЧАС, не дожидаясь тика/смены сигнатуры. Раньше часть настроек «Общих» (стиль иконок
    /// Kelvin↔Системные в необъединённом виде и др.) не входила в триггер перерисовки и применялась
    /// только после перезапуска приложения. Зовётся наблюдателем BMMenuBarChanged.
    func refreshMenuBarNow() {
        lastMenuTitle = ""; lastMenuImgKey = ""
        let b = BatteryReader.read() ?? .absent
        let energy = menuBarNeedsEnergy ? EnergyModel.snapshot() : EnergySnapshot()
        updateMenuBar(b, energy)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Hardening.denyDebugger()              // релиз-only: затруднить lldb-attach к гейту лицензии
        SettingsStore.migrateMenuBarIdentityIfNeeded()
        SettingsStore.migrateNativeMenuBarIfNeeded()
        SettingsStore.migrateOriginalMenuBarIconIfNeeded()
        SettingsStore.repairOriginalMenuBarIconIfNeeded()
        SettingsStore.migratePopoverProductLayoutIfNeeded()
        if let btn = statusItem.button {
            // Бренд виден с первого кадра; асинхронный hardware tick затем добавит
            // реальное значение. Больше нет безликого временного «…».
            btn.image = KelvinGlyph.image("kelvin", size: 14)
            btn.imagePosition = .imageOnly
            btn.title = ""
            btn.setAccessibilityTitle("Kelvin")
            btn.action = #selector(statusClick)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.wantsLayer = true                 // для лёгкой вспышки при автозамене
        }
        popover.behavior = .transient
        popover.contentViewController = controller
        buildMainMenu()                       // горячие клавиши ⌘C/⌘V/⌘Z в полях + ⌘,/⌘W/⌘Q в окнах
        AlertsEngine.shared.start()           // делегат Центра уведомлений (баннеры показываются и поверх активного приложения)
        // Радар 2.0: хук открытия радара из баннера «новое приложение в сети».
        FirstConnAlert.shared.showRadar = { [weak self] in self?.openRadarFromAlert() }

        tick()
        controller.updateApps([])
        refreshApps()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        appsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.refreshApps() }
        RunLoop.main.add(tickTimer!, forMode: .common)
        RunLoop.main.add(appsTimer!, forMode: .common)   // иначе рефреш приложений вставал во время трекинга меню/скролла

        // пересборка поповера при изменении его настроек (секция «Поповер»)
        NotificationCenter.default.addObserver(forName: AppNotifications.popoverChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.controller.isViewLoaded else { return }
            self.controller.buildModules()
        }

        // мгновенное применение настроек строки меню из секции «Общие» (без перезапуска)
        NotificationCenter.default.addObserver(forName: AppNotifications.menuBarChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshMenuBarNow()
        }

        // Из popover обычный toggle только подготавливает конфигурацию и приводит
        // пользователя к единственной осознанной CTA. Password dialog отсюда не вызывается.
        NotificationCenter.default.addObserver(forName: ChargeControl.helperSetupNeeded, object: nil, queue: .main) { _ in
            SettingsCoordinator.open(section: "power")
        }

        // авто-гашение подсветки клавы при простое
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.checkIdleBacklight() }

        // E1 — живой USB: регистрируем при СТАРТЕ (не при открытии поповера), чтобы счётчик был
        // верен в момент открытия. Колбэк на main: connect/disconnect → тик-пульс обода + сурфейс.
        usbWatch.onChange = { [weak self] ev in
            guard let self else { return }
            switch ev {
            case .connected:    self.controller.pulseUSB(connect: true)
            case .disconnected: self.controller.pulseUSB(connect: false)
            case .initialSync:  break   // стартовый засев — без пульса, только сурфейс
            }
            let name = self.usbWatch.devices.first?.name
            self.controller.setUSBCount(self.usbWatch.count, name: name)
        }
        usbWatch.start()

        // Локальные автоматизации ввода.
        LangSwitcher.shared.hotkeyKeycode = CGKeyCode(SettingsStore.langHotkey)
        LangSwitcher.shared.snippets = SettingsStore.parseSnippets(SettingsStore.snippetsRaw)
        LangSwitcher.shared.onFeedback = { [weak self] fb in self?.handleLangFeedback(fb) }
        applyFeatureEntitlements()

        // Глобальный хоткей вызова поповера (Carbon, без Универсального доступа). Дефолт ⌥⌘B вкл.
        // Даёт вход в поповер поверх fullscreen, где иконка строки меню недостижима.
        GlobalHotkey.shared.onPressed = { [weak self] in
            self?.togglePopover(fromHotkey: true)        // колбэк уже на main (DispatchQueue.main.async внутри GlobalHotkey)
        }
        GlobalHotkey.shared.apply(
            enabled: SettingsStore.popoverHotkeyEnabled,
            keyCode: SettingsStore.popoverHotkeyKeyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(SettingsStore.popoverHotkeyMods)))

        // Переносим только доказанно существовавший старый LaunchAgent. Новый
        // пользователь сам решает, запускать ли Kelvin при входе.
        if Bundle.main.bundlePath.hasPrefix("/Applications/") {
            LoginItem.migrateLegacyIfNeeded()
        }
        // Инициализация системы отчётов о сбоях: отмечаем запуск в breadcrumbs
        CrashBreadcrumbStore.shared.appStarted()
        
        // Проверка наличия crash reports после предыдущего запуска
        checkForCrashReports()

        // welcome при первом запуске (но не во время скриншот-режимов)
        let env = ProcessInfo.processInfo.environment
        let screenshotMode = env["BM_SETTINGS"] != nil || env["BM_SHOWCASE"] != nil || env["BM_AUTOSHOW"] != nil
        if env["BM_ONBOARD"] != nil || (OnboardingWindowController.shouldShow && !screenshotMode) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                OnboardingWindowController.shared.present()
                if let w = OnboardingWindowController.shared.window { print("ONBOARD_WIN \(w.windowNumber)"); fflush(stdout) }
            }
        }
        if !screenshotMode { Updater.checkOnLaunch() }   // тихая проверка обновлений (не чаще раза в сутки)

        // прямое открытие настроек (для скриншот-проверки)
        if ProcessInfo.processInfo.environment["BM_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsCoordinator.open()
                if let sec = ProcessInfo.processInfo.environment["BM_SETTINGS"], sec != "1" {
                    SettingsCoordinator.select(sec)
                }
                if let w = SettingsCoordinator.window {
                    if ProcessInfo.processInfo.environment["BM_LIGHT"] != nil {
                        w.appearance = NSAppearance(named: .aqua)
                    }
                    print("SETTINGS_WIN \(w.windowNumber)")
                    fflush(stdout)
                }
            }
        }

        // витрина: весь UI в обычном окне (для экранного скриншота, т.к. слои/анимация
        // не видны в офскрин-рендере поповера).
        if ProcessInfo.processInfo.environment["BM_SHOWCASE"] != nil {
            let v = controller.view
            if ProcessInfo.processInfo.environment["BM_LIGHT"] != nil {
                v.appearance = NSAppearance(named: .aqua)
            }
            v.layoutSubtreeIfNeeded()
            let sz = v.fittingSize
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(sz.width, 300), height: max(sz.height, 500)),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Kelvin"
            win.contentView = v
            win.center()
            win.level = .floating
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            // печатаем номер окна для screencapture -l (надёжно даже при перекрытии)
            print("SHOWCASE_WIN \(win.windowNumber)")
            fflush(stdout)
        }

        // отладочный автопоказ поповера для скриншот-проверки
        if ProcessInfo.processInfo.environment["BM_AUTOSHOW"] != nil {
            popover.behavior = .applicationDefined   // не закрывать при потере фокуса (для скриншота)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.togglePopover()
                if let w = self?.popover.contentViewController?.view.window { print("POPOVER_WIN \(w.windowNumber)"); fflush(stdout) }
                guard let path = ProcessInfo.processInfo.environment["BM_RENDER"] else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let v = self?.controller.view else { return }
                    v.layoutSubtreeIfNeeded()
                    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Рисованная батарея-template для строки меню (адаптируется к свету/тьме).
    /// Фирменный глиф меню-бара — вертикальный термо-столбик (а не клон Apple-батарейки):
    /// стеклянная капсула + колба, «ртуть» = уровень заряда, шкала-риски справа, при зарядке — молния-вырез.
    /// Template (монохром): узнаётся формой, система тинтует под свет/тьму/подсветку.
    /// Главная иконка строки меню по выбранному стилю (термометр / батарея) — обе charge-aware.
    func menuBarIcon(charge: Int, charging: Bool) -> NSImage {
        switch SettingsStore.mainIconStyle {
        case "kelvin":
            return menuBarKelvinIcon(charge: charge, charging: charging, phase: statusAnimationPhase)
        case "ring":
            return menuBarRingIcon(charge: charge, charging: charging, phase: statusAnimationPhase)
        default:
            if SettingsStore.menuBarIconStyle == "system" {
                // В системном стиле используем именно поставляемый macOS SF Symbol,
                // а не нарисованную Kelvin имитацию батареи.
                if let image = systemMenuBarIcon(charge: charge, charging: charging) {
                    return image
                }
            }
            return SettingsStore.mainIconStyle == "battery"
                ? menuBarBatteryIcon(charge: charge, charging: charging, phase: statusAnimationPhase)
                : menuBarThermometerIcon(charge: charge, charging: charging)
        }
    }

    /// Канонический монохромный знак Kelvin: тот же термометр со шкалой, что на
    /// AppIcon, но адаптированный к 16 pt. Уровень живой, а во время зарядки по
    /// столбику проходит спокойный блик.
    private func menuBarKelvinIcon(charge: Int, charging: Bool, phase: Int) -> NSImage {
        let w: CGFloat = 16, h: CGFloat = 16
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let ink = NSColor.black
            ink.setStroke(); ink.setFill()
            let x: CGFloat = 5.4
            let bulbR: CGFloat = 3.0
            let bulbY: CGFloat = 3.4
            let stem = NSBezierPath(roundedRect: NSRect(x: x - 1.8, y: bulbY, width: 3.6, height: 11.5),
                                    xRadius: 1.8, yRadius: 1.8)
            stem.lineWidth = 1.15; stem.stroke()
            NSBezierPath(ovalIn: NSRect(x: x - bulbR, y: bulbY - bulbR,
                                        width: bulbR * 2, height: bulbR * 2)).fill()

            let level = bulbY + 1 + 9.0 * CGFloat(max(0, min(100, charge))) / 100
            NSBezierPath(roundedRect: NSRect(x: x - 0.7, y: bulbY, width: 1.4,
                                             height: max(1, level - bulbY)),
                         xRadius: 0.7, yRadius: 0.7).fill()

            let ticks = NSBezierPath()
            ticks.lineWidth = 1.05; ticks.lineCapStyle = .round
            for i in 0..<4 {
                let y = 5.3 + CGFloat(i) * 2.55
                ticks.move(to: NSPoint(x: 9.1, y: y))
                ticks.line(to: NSPoint(x: i.isMultiple(of: 2) ? 13.2 : 12.3, y: y))
            }
            ticks.stroke()

            if charging && SettingsStore.menuBarMotion && !Motion.reduced {
                let p = CGFloat(phase % 10) / 9.0
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: x - 1.0, y: 4.0 + p * 8.0,
                                            width: 2.0, height: 1.5)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Кольцевой charge-gauge — более компактная фирменная альтернатива батарее.
    private func menuBarRingIcon(charge: Int, charging: Bool, phase: Int) -> NSImage {
        let s: CGFloat = 16
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let center = NSPoint(x: s / 2, y: s / 2)
            let radius: CGFloat = 5.7
            NSColor.black.withAlphaComponent(0.28).setStroke()
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: -90, endAngle: 270)
            track.lineWidth = 1.5; track.stroke()

            let start = -90 + (charging && SettingsStore.menuBarMotion && !Motion.reduced
                               ? CGFloat(phase % 10) * 2.0 : 0)
            NSColor.black.setStroke()
            let value = NSBezierPath()
            value.appendArc(withCenter: center, radius: radius, startAngle: start,
                            endAngle: start + 360 * CGFloat(max(2, min(100, charge))) / 100)
            value.lineWidth = 2.0; value.lineCapStyle = .round; value.stroke()

            NSColor.black.setFill()
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 8.6, y: 12.0))
            bolt.line(to: NSPoint(x: 5.8, y: 7.7))
            bolt.line(to: NSPoint(x: 7.7, y: 7.7))
            bolt.line(to: NSPoint(x: 6.9, y: 4.0))
            bolt.line(to: NSPoint(x: 10.2, y: 8.7))
            bolt.line(to: NSPoint(x: 8.3, y: 8.7))
            bolt.close(); bolt.fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Офскрин QA-галерея status item (`BM_STATUS_SNAP=/path.png`).
    /// Не читает железо и не меняет UserDefaults владельца.
    private func statusSnapshotImage(_ template: NSImage, color: NSColor) -> NSImage {
        let copy = NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }

    func renderStatusIconSnapshot(to path: String) {
        let styles: [(String, (Int, Bool, Int) -> NSImage)] = [
            ("Kelvin Live", { (charge: Int, charging: Bool, phase: Int) -> NSImage in
                self.menuBarKelvinIcon(charge: charge, charging: charging, phase: phase)
            }),
            (L("Кольцо заряда"), { (charge: Int, charging: Bool, phase: Int) -> NSImage in
                self.menuBarRingIcon(charge: charge, charging: charging, phase: phase)
            }),
            (L("Термометр"), { (charge: Int, charging: Bool, _: Int) -> NSImage in
                self.menuBarThermometerIcon(charge: charge, charging: charging)
            }),
            (L("Батарея"), { (charge: Int, charging: Bool, phase: Int) -> NSImage in
                self.menuBarBatteryIcon(charge: charge, charging: charging, phase: phase)
            }),
        ]
        let states: [(String, Int, Bool, Int)] = [
            ("10%", 10, false, 0), ("45%", 45, false, 0), ("80%", 80, false, 0),
            (L("Зарядка") + " A", 45, true, 1), (L("Зарядка") + " B", 45, true, 6),
        ]
        let cellW: CGFloat = 84, rowH: CGFloat = 54, labelW: CGFloat = 120
        let size = NSSize(width: labelW + cellW * CGFloat(states.count) + 24,
                          height: 34 + rowH * CGFloat(styles.count))
        let canvas = NSImage(size: size, flipped: true) { rect in
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let smallAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            for (i, state) in states.enumerated() {
                (state.0 as NSString).draw(at: NSPoint(x: labelW + CGFloat(i) * cellW + 24, y: 10),
                                           withAttributes: smallAttrs)
            }
            for (row, style) in styles.enumerated() {
                let y = 34 + CGFloat(row) * rowH
                (style.0 as NSString).draw(at: NSPoint(x: 14, y: y + 17), withAttributes: titleAttrs)
                for (col, state) in states.enumerated() {
                    let icon = self.statusSnapshotImage(
                        style.1(state.1, state.2, state.3),
                        color: .labelColor
                    )
                    let box = NSRect(x: labelW + CGFloat(col) * cellW + 30, y: y + 8,
                                     width: 28, height: 28)
                    NSColor.controlBackgroundColor.setFill()
                    NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
                    icon.draw(in: NSRect(x: box.midX - icon.size.width / 2,
                                         y: box.midY - icon.size.height / 2,
                                         width: icon.size.width, height: icon.size.height))
                }
            }
            return true
        }
        guard let rep = NSBitmapImageRep(data: canvas.tiffRepresentation ?? Data()),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Нативная ветка использует только SF Symbols и системный template-тинт.
    /// Уровни кратны 25%, как у стандартных индикаторов macOS; точный процент остаётся рядом.
    private func systemMenuBarIcon(charge: Int, charging: Bool) -> NSImage? {
        let symbol: String
        if SettingsStore.mainIconStyle == "thermometer" {
            symbol = "thermometer.medium"
        } else {
            let level: Int
            switch charge {
            case ..<13: level = 0
            case ..<38: level = 25
            case ..<63: level = 50
            case ..<88: level = 75
            default: level = 100
            }
            // Новая percent-грамматика визуально совпадает с актуальной системной
            // батареей macOS. На старых версиях остаётся совместимый legacy-символ.
            let modern = "battery.\(level)percent"
            symbol = NSImage(systemSymbolName: modern, accessibilityDescription: nil) != nil
                ? modern
                : "battery.\(level)"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: charging ? L("Зарядка") : nil)?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        return image
    }

    /// Charge-aware батарея (горизонтальная): уровень заливки = заряд, молния-вырез при зарядке.
    private func menuBarBatteryIcon(charge: Int, charging: Bool, phase: Int) -> NSImage {
        // Размер близок к системной батарее macOS: она шире большинства SF-глифов
        // и занимает почти всю полезную высоту menu bar, не выглядя мелкой пиктограммой.
        let w: CGFloat = 19, h: CGFloat = 12
        let discharging = !lastStatusBattery.external && !charging
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let body = NSRect(x: 0.75, y: 1.45, width: w - 3.8, height: h - 2.9)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.35, yRadius: 2.35)
            outline.lineWidth = 1.15
            outline.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.65, y: h/2 - 1.65, width: 1.7, height: 3.3),
                         xRadius: 0.7, yRadius: 0.7).fill()                      // клемма
            let inset = body.insetBy(dx: 1.65, dy: 1.65)
            let fillW = inset.width * CGFloat(max(0, min(100, charge))) / 100
            if fillW > 0.5 {
                NSBezierPath(roundedRect: NSRect(x: inset.minX, y: inset.minY, width: fillW, height: inset.height),
                             xRadius: 1.0, yRadius: 1.0).fill()
            }
            // Живая дорожка направления энергии: при зарядке блик идёт к клемме,
            // при работе от батареи — обратно. Это прозрачный вырез внутри заливки,
            // поэтому template-иконка остаётся нативно монохромной в light/dark.
            let moving = charging || discharging
            if moving, fillW > 3 {
                let progress = CGFloat(phase % 60) / 59
                let travel = max(0, fillW - 1.4)
                let x = charging
                    ? inset.minX + progress * travel
                    : inset.minX + (1 - progress) * travel
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(roundedRect: NSRect(x: x, y: inset.minY, width: 1.35, height: inset.height),
                             xRadius: 0.65, yRadius: 0.65).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            if charging {                                                        // молния-вырез
                NSGraphicsContext.current?.compositingOperation = .clear
                let bx = body.midX, top = body.maxY - 1.1, bot = body.minY + 1.1, mid = body.midY
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: bx + 1.5, y: top))
                bolt.line(to: NSPoint(x: bx - 1.7, y: mid + 0.2))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid + 0.2))
                bolt.line(to: NSPoint(x: bx - 1.5, y: bot))
                bolt.line(to: NSPoint(x: bx + 1.9, y: mid - 0.2))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid - 0.2))
                bolt.close(); bolt.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func menuBarThermometerIcon(charge: Int, charging: Bool) -> NSImage {
        let w: CGFloat = 13, h: CGFloat = 16
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let cx: CGFloat = 4.8
            let stemW: CGFloat = 3.8, bulbR: CGFloat = 3.0
            let bulbCY: CGFloat = bulbR + 0.7                 // колба у низа
            let stemTop: CGFloat = h - 1.0

            // стекло: капсула-стержень + колба (обводка)
            let glass = NSBezierPath(roundedRect: NSRect(x: cx - stemW/2, y: bulbCY, width: stemW, height: stemTop - bulbCY),
                                     xRadius: stemW/2, yRadius: stemW/2)
            glass.appendOval(in: NSRect(x: cx - bulbR, y: bulbCY - bulbR, width: bulbR*2, height: bulbR*2))
            NSColor.black.setStroke(); glass.lineWidth = 1.1; glass.stroke()

            // ртуть: колба + столбик до уровня заряда
            let innerW: CGFloat = stemW - 1.8
            let colTopMax = stemTop - innerW/2
            let level = bulbCY + (colTopMax - bulbCY) * CGFloat(max(0, min(100, charge))) / 100
            let merc = NSBezierPath(roundedRect: NSRect(x: cx - innerW/2, y: bulbCY, width: innerW, height: max(0, level - bulbCY)),
                                    xRadius: innerW/2, yRadius: innerW/2)
            merc.appendOval(in: NSRect(x: cx - (bulbR - 0.9), y: bulbCY - (bulbR - 0.9), width: (bulbR - 0.9)*2, height: (bulbR - 0.9)*2))
            NSColor.black.setFill(); merc.fill()

            // шкала-риски справа
            let ticks = NSBezierPath(); ticks.lineWidth = 0.9; ticks.lineCapStyle = .round
            NSColor.black.setStroke()
            for i in 0..<3 {
                let ty = bulbCY + bulbR + 1.4 + CGFloat(i) * ((stemTop - bulbCY - bulbR - 2.2) / 2)
                ticks.move(to: NSPoint(x: cx + stemW/2 + 1.4, y: ty))
                ticks.line(to: NSPoint(x: cx + stemW/2 + 3.1, y: ty))
            }
            ticks.stroke()

            if charging {                                    // молния-вырез в столбике
                NSGraphicsContext.current?.compositingOperation = .clear
                let bx = cx, top = stemTop - 1.0, bot = bulbCY + bulbR - 0.4, mid = (top + bot)/2
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: bx + 1.3, y: top))
                bolt.line(to: NSPoint(x: bx - 1.5, y: mid + 0.3))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid + 0.3))
                bolt.line(to: NSPoint(x: bx - 1.3, y: bot))
                bolt.line(to: NSPoint(x: bx + 1.7, y: mid - 0.3))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid - 0.3))
                bolt.close(); bolt.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Обновляет иконку строки меню по выбранному режиму (battery / cpu / ram).
    /// Основной показатель строки меню (строка + иконка + ключ иконки) — общий источник для
    /// классического и объединённого видов, чтобы они не расходились.
    private func menuBarPrimaryToken(_ b: BatteryInfo, _ e: EnergySnapshot) -> (token: String, image: NSImage, imgKey: String) {
        switch SettingsStore.menuBarMode {
        case "cpu":
            let v = menuBarCPULoad
            return (figPad(String(format: "%.0f%%", v * 100), 4), usageBarImage(SystemUsage.shared.cpuHistory, value: v), "graph")
        case "ram":
            let v = menuBarRAMLoad
            return (figPad(String(format: "%.0f%%", v * 100), 4), usageBarImage(SystemUsage.shared.ramHistory, value: v), "graph")
        case "cputemp":
            let token = e.cpuTemp.map { figPad(String(format: "%.0f°", $0), 4) } ?? figPad("—°", 4)
            let image = menuBarGlyph(forID: "cputemp")
                ?? menuBarKelvinIcon(charge: b.charge, charging: b.charging, phase: statusAnimationPhase)
            return (token, image, "metric-cputemp-\(SettingsStore.menuBarIconStyle)")
        case "fan":
            let token = e.fans.first.map { figPad(String(format: "%.1fk", $0 / 1000), 4) } ?? figPad("—", 4)
            let image = menuBarGlyph(forID: "fan")
                ?? menuBarKelvinIcon(charge: b.charge, charging: b.charging, phase: statusAnimationPhase)
            return (token, image, "metric-fan-\(SettingsStore.menuBarIconStyle)")
        default:
            if b.present {
                let token = figPad(SettingsStore.menuBarShowWatts ? String(format: "%.0fW", e.systemWatts > 0.1 ? e.systemWatts : b.watts) : "\(b.charge)%", 4)
                return (token, menuBarIcon(charge: b.charge, charging: b.charging), "b\(b.charge)\(b.charging)\(SettingsStore.mainIconStyle)")
            }
            // десктоп без АКБ — вместо фейкового заряда показываем загрузку CPU
            let v = menuBarCPULoad
            return (figPad(String(format: "%.0f%%", v * 100), 4), usageBarImage(SystemUsage.shared.cpuHistory, value: v), "graph")
        }
    }

    private func updateMenuBar(_ b: BatteryInfo, _ energy: EnergySnapshot) {
        guard let btn = statusItem.button else { return }
        let powerTransition = hasStatusSnapshot
            && (b.charging != lastStatusBattery.charging || b.external != lastStatusBattery.external)
        let chargeTransition = hasStatusSnapshot && b.present
            && b.charge != lastStatusBattery.charge
        lastStatusBattery = b
        lastStatusEnergy = energy
        hasStatusSnapshot = true
        updateStatusAnimationTimer()
        if powerTransition { animateStatusTransition() }
        else if chargeTransition { animateChargeTransition() }
        let prim = menuBarPrimaryToken(b, energy)
        // Объединённый вид: рисуем всё одной template-картинкой (моно, без семантического цвета —
        // зато ОС корректно тинтует для светлой/тёмной/подсветки). Перестраиваем только при смене подписи.
        if SettingsStore.menuBarCombined {
            let icons = SettingsStore.menuBarExtraIcons
            var cells: [(id: String?, token: String)] = [(menuBarPrimaryGlyphID(b), prim.token)]
            for id in SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax) {
                if let t = menuBarExtraToken(id, b, energy) { cells.append((id, t)) }
            }
            // подпись включает флаг иконок И стиль — переключение обязано перерисовать картинку
            let sig = "combined|\(icons ? "i" : "t")|\(SettingsStore.menuBarIconStyle)|\(SettingsStore.mainIconStyle)|\(prim.imgKey)|"
                + cells.map { $0.token }.joined(separator: "|")
            if sig != lastMenuTitle {
                lastMenuTitle = sig
                lastMenuImgKey = "combined"
                btn.image = combinedMenuImage(cells, icons: icons, primaryImage: prim.image)
                btn.imagePosition = .imageOnly
                btn.attributedTitle = NSAttributedString(string: "")
            }
            let human = menuBarTooltip(b, energy)
            btn.toolTip = human
            btn.setAccessibilityTitle(human)
            return
        }
        let primary = prim.token
        let image = prim.image
        let imgKey = prim.imgKey
        // картинка фикс-ширины (графику обновляем каждый тик; батарейку — лишь при смене заряда)
        if imgKey == "graph" || imgKey != lastMenuImgKey {
            lastMenuImgKey = imgKey; btn.image = image; btn.imagePosition = .imageLeading
        }
        // доп-показатели (курируемые, с лимитом). Ширина каждого токена СТАБИЛЬНА (фигурные пробелы +
        // моноширинные цифры), а заголовок переустанавливаем лишь при реальном изменении — поэтому
        // строка меню не «дёргается» при смене значений (особенно заметно в полноэкранном режиме).
        let extras = SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax)
            .compactMap { menuBarExtraToken($0, b, energy) }
        let parts = [primary] + extras
        let sig = parts.joined(separator: "|")
        if sig != lastMenuTitle { lastMenuTitle = sig; btn.attributedTitle = menuBarTitle(parts) }
        let human = menuBarTooltip(b, energy)
        btn.toolTip = human                            // живая подсказка при наведении
        btn.setAccessibilityTitle(human)               // VoiceOver: человеческая фраза вместо «42%/18W/56°»
    }

    /// Низкочастотная смысловая анимация. Kelvin Live/кольцо движутся при зарядке,
    /// фирменная батарея также показывает направление энергии при разряде.
    private func advanceStatusAnimation() {
        let liveBattery = SettingsStore.mainIconStyle == "battery"
            && SettingsStore.menuBarIconStyle == "kelvin"
        let chargingBrandMark = lastStatusBattery.charging
            && (SettingsStore.mainIconStyle == "kelvin" || SettingsStore.mainIconStyle == "ring")
        guard SettingsStore.menuBarMotion, !Motion.reduced,
              SettingsStore.menuBarMode == "battery",
              lastStatusBattery.present, liveBattery || chargingBrandMark,
              let button = statusItem.button
        else { return }
        statusAnimationPhase = (statusAnimationPhase + 1) % 60
        if SettingsStore.menuBarCombined {
            lastMenuTitle = ""
            updateMenuBar(lastStatusBattery, lastStatusEnergy)
        } else {
            button.image = menuBarIcon(charge: lastStatusBattery.charge,
                                       charging: lastStatusBattery.charging)
            button.imagePosition = .imageLeading
        }
    }

    private func updateStatusAnimationTimer() {
        let liveBattery = SettingsStore.mainIconStyle == "battery"
            && SettingsStore.menuBarIconStyle == "kelvin"
        let chargingBrandMark = lastStatusBattery.charging
            && (SettingsStore.mainIconStyle == "kelvin" || SettingsStore.mainIconStyle == "ring")
        let shouldAnimate = SettingsStore.menuBarMotion && !Motion.reduced
            && SettingsStore.menuBarMode == "battery"
            && lastStatusBattery.present
            && (liveBattery || chargingBrandMark)
        if shouldAnimate, statusAnimationTimer == nil {
            let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
                self?.advanceStatusAnimation()
            }
            statusAnimationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !shouldAnimate, statusAnimationTimer != nil {
            statusAnimationTimer?.invalidate()
            statusAnimationTimer = nil
            statusAnimationPhase = 0
        }
    }

    /// Один короткий импульс при подключении/отключении питания — событие, а не
    /// бесконечная декоративная пульсация.
    private func animateStatusTransition() {
        guard SettingsStore.menuBarMotion, !Motion.reduced,
              let layer = statusItem.button?.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.13, 0.98, 1.0]
        animation.keyTimes = [0, 0.38, 0.72, 1]
        animation.duration = 0.34
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "powerTransition")
    }

    /// Небольшой нативный cross-fade при изменении процента: новая геометрия заливки
    /// появляется мягко, но status item не пульсирует и не отвлекает пользователя.
    private func animateChargeTransition() {
        guard SettingsStore.menuBarMotion, !Motion.reduced,
              !SettingsStore.menuBarCombined,
              SettingsStore.menuBarMode == "battery",
              let layer = statusItem.button?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.68
        fade.toValue = 1.0
        fade.duration = 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "chargeTransition")
    }
    /// Человеческая сводка для подсказки на иконке: заряд/состояние/время/ватты.
    private func menuBarTooltip(_ b: BatteryInfo, _ e: EnergySnapshot) -> String {
        let watt = e.systemWatts > 0.1 ? e.systemWatts : b.watts
        let w = "\(Int(watt.rounded())) \(L("Вт"))"
        let hint = " · \(L("правый клик: инструменты"))"
        switch SettingsStore.menuBarMode {
        case "cpu":
            return "Kelvin · CPU \(Int((menuBarCPULoad * 100).rounded()))%\(hint)"
        case "ram":
            return "Kelvin · RAM \(Int((menuBarRAMLoad * 100).rounded()))%\(hint)"
        case "cputemp":
            let value = e.cpuTemp.map { String(format: "%.0f°C", $0) } ?? "—"
            return "Kelvin · \(L("Температура CPU")) \(value)\(hint)"
        case "fan":
            let value = e.fans.first.map { String(format: "%.0f %@", $0, L("об/мин")) } ?? "—"
            return "Kelvin · \(L("Вентилятор")) \(value)\(hint)"
        default:
            break
        }
        guard b.present else { return "Kelvin · \(L("без батареи")) · \(w)\(hint)" }
        let state = b.charging ? L("зарядка") : (b.external ? L("от сети") : L("от батареи"))
        let mins = b.charging ? b.timeToFull : b.timeToEmpty
        let time = (mins > 0 && mins < 1200) ? " · \(b.charging ? L("до полного") : L("осталось")) \(mins/60):\(String(format: "%02d", mins % 60))" : ""
        return "Kelvin · \(b.charge)% (\(state)) · \(w)\(time)\(hint)"
    }
    /// Дополняет строку ведущими фигурными пробелами (ширина цифры) до стабильной ширины.
    private func figPad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: "\u{2007}", count: width - s.count) + s
    }
    /// Формат времени по локали (j → 12/24 ч автоматически), кэшируем — DateFormatter дорог в создании.
    private lazy var clockFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()
    /// Короткая дата по локали: день недели + число + месяц («Чт 26 июн»).
    private lazy var dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("EEEEEEdMMM"); return f
    }()
    /// Один доп-показатель строки меню в компактном виде (стабильной ширины), или nil если данных нет.
    private func menuBarExtraToken(_ id: String, _ b: BatteryInfo, _ e: EnergySnapshot) -> String? {
        switch id {
        case "watts":   let w = e.systemWatts > 0.1 ? e.systemWatts : b.watts; return figPad(String(format: "%.0fW", w), 4)
        case "cputemp": return e.cpuTemp.map { figPad(String(format: "%.0f°", $0), 4) } ?? figPad("—°", 4)
        case "gputemp": return e.gpuTemp.map { figPad(String(format: "%.0f° G", $0), 6) } ?? figPad("—° G", 6)
        case "fan":     return e.fans.first.map { figPad(String(format: "%.1fk", $0 / 1000), 4) } ?? figPad("—", 4)
        case "cpu":     return figPad(String(format: "%.0f%% C", menuBarCPULoad * 100), 6)
        case "ram":     return figPad(String(format: "%.0f%% R", menuBarRAMLoad * 100), 6)
        case "net":     let nu = NetUsage.shared.sample(); return "↓\(NetUsage.fmtRate(nu.down)) ↑\(NetUsage.fmtRate(nu.up))"
        case "diskio":  let d = DiskUsage.shared.sample(); return "↓\(NetUsage.fmtRate(d.read)) ↑\(NetUsage.fmtRate(d.write))"
        case "diskfree": return DiskInfo.capacity().map { figPad(String(format: "%.0fG", Double($0.free) / 1e9), 5) }
        case "btbatt":  return BTPeripherals.cachedWorst().map { figPad(String(format: "%d%%", $0), 4) } ?? figPad("—", 4)
        case "clock":   return clockFmt.string(from: Date())
        case "date":    return dateFmt.string(from: Date())
        default:        return nil
        }
    }
    /// Собирает заголовок строки меню: моноширинные цифры, разделитель « · » приглушён.
    private func menuBarTitle(_ parts: [String]) -> NSAttributedString {
        let font = Design.Font.numericBody
        let s = NSMutableAttributedString(string: " ", attributes: [.font: font])
        for (i, p) in parts.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "  ·  ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
            s.append(NSAttributedString(string: p, attributes: [.font: font]))
        }
        return s
    }
    /// Мини-график загрузки для строки меню (вертикальные бары, цвет по нагрузке).
    private func usageBarImage(_ history: [Double], value: Double) -> NSImage {
        let w: CGFloat = 30, h: CGFloat = 15
        let color: NSColor = value > 0.85 ? .systemRed : (value > 0.6 ? .systemOrange : .systemGreen)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let bars = Array(history.suffix(15))
            guard !bars.isEmpty else { return true }
            let bw = w / 15
            for (i, v) in bars.enumerated() {
                let bh = max(1.5, CGFloat(v) * (h - 2))
                let r = NSRect(x: CGFloat(i) * bw + 0.6, y: 1, width: bw - 1.2, height: bh)
                color.withAlphaComponent(0.35 + 0.55 * CGFloat(v)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Курируемые SF-глифы для показателей строки меню. Подобраны так, чтобы читаться при ~13pt
    /// в моно-template-картинке (тонкие глифы вроде «wind» отброшены в пользу плотных и узнаваемых).
    private static let menuBarGlyphs: [String: String] = [
        "battery":  "battery.100",
        "watts":    "bolt.fill",
        "cputemp":  "thermometer",
        "gputemp":  "thermometer",
        "fan":      "fanblades.fill",
        "cpu":      "cpu",
        "ram":      "memorychip",
        "net":      "arrow.up.arrow.down",
        "diskio":   "internaldrive",
        "diskfree": "internaldrive",
        "btbatt":   "wave.3.right",
        "clock":    "clock",
        "date":     "calendar",
    ]
    /// Глиф основной ячейки объединённого вида — по текущему режиму строки меню.
    private func menuBarPrimaryGlyphID(_ b: BatteryInfo) -> String? {
        switch SettingsStore.menuBarMode {
        case "cpu": return "cpu"
        case "ram": return "ram"
        case "cputemp": return "cputemp"
        case "fan": return "fan"
        default:
            guard b.present else { return "cpu" }
            if SettingsStore.mainIconStyle == "kelvin" { return "kelvin" }
            if SettingsStore.mainIconStyle == "ring" { return "ring" }
            return "battery"
        }
    }
    /// Убирает дублирующий хвостовой литер-суффикс (« G»/« C»/« R») когда глиф уже опознаёт метрику.
    private func stripGlyphSuffix(_ id: String, _ token: String) -> String {
        let drop: [String: String] = ["gputemp": " G", "cpu": " C", "ram": " R"]
        guard let suff = drop[id], token.hasSuffix(suff) else { return token }
        return String(token.dropLast(suff.count))
    }
    /// Шаблонная картинка SF-символа фиксированной высоты для строки меню (моно-template-тинт).
    private func menuBarGlyphImage(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        return img
    }
    /// Глиф показателя по выбранному стилю: kelvin (фирменный векторный) | system (SF Symbol).
    private func menuBarGlyph(forID id: String) -> NSImage? {
        if id == "kelvin" || id == "ring" {
            return KelvinGlyph.image(id, size: 13)
        }
        if SettingsStore.menuBarIconStyle == "kelvin", let img = KelvinGlyph.image(id, size: 14) { return img }
        guard let name = Self.menuBarGlyphs[id] else { return nil }
        return menuBarGlyphImage(name)
    }

    /// Объединённый вид строки меню: основной показатель + доп-показатели как ячейки с тонкими
    /// разделителями в одной template-картинке (~22pt). isTemplate=true → ОС тинтует под светлую/тёмную/подсветку.
    /// Ширина каждой ячейки фиксирована (моно-цифры + бюджет по максимально-широкой строке), поэтому 9→100,
    /// 3-значные температуры и ↓1.2M никогда не «дёргают» строку. Цена: теряется зелёный/оранжевый/красный
    /// цвет нагрузки — корректный размен ради чёткого OS-тинта.
    /// При icons=true перед значением рисуется ведущий SF-глиф; ширину ячейки расширяем РОВНО на измеренную
    /// ширину глифа+зазор, чтобы инвариант «строка не дёргается» сохранялся.
    private func combinedMenuImage(
        _ cells: [(id: String?, token: String)],
        icons: Bool,
        primaryImage: NSImage? = nil
    ) -> NSImage {
        let font = Design.Font.mono(13, .semibold)
        let h: CGFloat = 22, padX: CGFloat = 5, gap: CGFloat = 8, iconGap: CGFloat = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // глиф ячейки (если иконки включены и для id есть символ) + его картинка/ширина
        func glyph(_ id: String?, at index: Int) -> (img: NSImage, w: CGFloat)? {
            if icons, index == 0, let primaryImage {
                return (primaryImage, ceil(primaryImage.size.width))
            }
            guard icons, let id = id, let img = menuBarGlyph(forID: id) else { return nil }
            return (img, ceil(img.size.width))
        }
        // текст ячейки (со снятым дубль-суффиксом, если перед ним будет глиф)
        func text(_ c: (id: String?, token: String)) -> String {
            (icons && c.id != nil && Self.menuBarGlyphs[c.id!] != nil)
                ? stripGlyphSuffix(c.id!, c.token) : c.token
        }
        // фикс-ширина ячейки: бюджет по более широкой из (значение, эталон ширины токена этой длины) + глиф
        func textWidth(_ s: String) -> CGFloat {
            let probe = String(repeating: "0", count: max(s.count, 4))   // токены уже figPad-нуты под свою ширину
            let a = (s as NSString).size(withAttributes: attrs).width
            let b = (probe as NSString).size(withAttributes: attrs).width
            return ceil(max(a, b))
        }
        let glyphs = cells.enumerated().map { glyph($0.element.id, at: $0.offset) }
        let texts = cells.map(text)
        let tWidths = texts.map(textWidth)
        // полная ширина ячейки = глиф + зазор + текст (если глиф есть)
        let widths: [CGFloat] = zip(tWidths, glyphs).map { tw, g in g == nil ? tw : g!.w + iconGap + tw }
        let total = padX * 2 + widths.reduce(0, +) + gap * CGFloat(max(0, cells.count - 1))
        let para = NSMutableParagraphStyle(); para.alignment = .center
        var cellAttrs = attrs; cellAttrs[.paragraphStyle] = para
        let img = NSImage(size: NSSize(width: max(1, ceil(total)), height: h), flipped: false) { _ in
            var x = padX
            for i in cells.indices {
                let w = widths[i]
                if i > 0 {     // тонкий разделитель-волосок (template-картинка его тоже тинтует)
                    NSColor.black.withAlphaComponent(0.28).setStroke()
                    let sep = NSBezierPath(); sep.lineWidth = 1
                    sep.move(to: NSPoint(x: x - gap / 2, y: 4)); sep.line(to: NSPoint(x: x - gap / 2, y: h - 4)); sep.stroke()
                }
                var tx = x, tw = w
                if let g = glyphs[i] {     // ведущий глиф ячейки — слева, по вертикали по центру
                    let gs = g.img.size
                    g.img.draw(in: NSRect(x: x, y: (h - gs.height) / 2, width: g.w, height: gs.height),
                               from: .zero, operation: .sourceOver, fraction: 1)
                    tx = x + g.w + iconGap; tw = w - g.w - iconGap
                }
                let p = texts[i]
                let vh = (p as NSString).size(withAttributes: cellAttrs).height
                (p as NSString).draw(in: NSRect(x: tx, y: (h - vh) / 2, width: tw, height: vh), withAttributes: cellAttrs)
                x += w + gap
            }
            return true
        }
        img.isTemplate = true     // ОС сама красит под светлую/тёмную/подсветку, как у menuBarIcon
        return img
    }

    // MARK: обратная связь автозамены языка/опечатки (звук + индикатор + вспышка иконки)
    private func handleLangFeedback(_ fb: LangSwitcher.Feedback) {
        let sound = SettingsStore.langFeedbackSound
        let hud = SettingsStore.langFeedbackHUD
        switch fb {
        case .layout(let toRU):
            if sound { playFeedbackSound("Morse") }
            if hud { FeedbackHUD.shared.show(symbol: "globe", text: toRU ? L("Русский") : "English", tint: Design.Color.accentAdaptive) }
        case .spell(let original, let corrected, let id):
            if sound { playFeedbackSound("Pop") }
            if hud { CorrectionChoiceHUD.shared.show(original: original, corrected: corrected, id: id) }
        case .undo:
            if sound { playFeedbackSound("Tink") }
            if hud { FeedbackHUD.shared.show(symbol: "arrow.uturn.backward.circle.fill", text: L("Исходное слово возвращено"), tint: Design.Color.accentAdaptive) }
        }
        if hud { flashStatusItem() }
    }
    private func playFeedbackSound(_ name: String) {
        let s = NSSound(named: name); s?.volume = 0.3; s?.play()
    }
    private func flashStatusItem() {
        guard !Motion.reduced, let layer = statusItem.button?.layer else { return }   // «Уменьшить движение» — без вспышки иконки
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.4
        a.autoreverses = true; a.duration = 0.13
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "langflash")
    }

    /// Нужен ли строке меню тяжёлый EnergyModel.snapshot (только если выбран энергозависимый доп-показатель).
    private var menuBarNeedsEnergy: Bool {
        ["cputemp", "fan"].contains(SettingsStore.menuBarMode)
            || SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax)
                .contains { ["watts", "cputemp", "gputemp", "fan"].contains($0) }
    }

    /// Применяет сохранённые настройки локальных автоматизаций.
    func applyFeatureEntitlements() {
        LangSwitcher.shared.snippetsEnabled = SettingsStore.snippetsEnabled
        LangSwitcher.shared.spellFixEnabled = SettingsStore.spellFixEnabled
        let lm = SettingsStore.langMode
        LangSwitcher.shared.mode = (lm == "auto") ? .auto : (lm == "hotkey" ? .hotkey : .off)
    }

    func tick() {
        ClipboardHistory.shared.poll()
        Caffeine.expireIfDue()                            // синхронизируем флаг с OS-таймаутом ассерции
        nightTick += 1
        if SettingsStore.nightKeepOn && NightShift.available && nightTick % 10 == 0 { NightShift.enableNow() }
        if nightTick % 120 == 0, Licensing.shared.isPro {
            hardwareQueue.async { FanController.refreshLease() }
        }
        guard !hardwareTickInFlight else { return }
        hardwareTickInFlight = true

        let tickNumber = nightTick
        let popoverOpen = popover.isShown
        let needEnergy = popoverOpen || menuBarNeedsEnergy
        let forcedNoBatt = ProcessInfo.processInfo.environment["BM_NOBATT"] != nil
        // Mach counters are cheap and their history remains main-owned.
        let cpuLoad = SystemUsage.shared.cpu()
        let ramLoad = SystemUsage.shared.ram()
        menuBarCPULoad = cpuLoad
        menuBarRAMLoad = ramLoad

        hardwareQueue.async { [weak self] in
            guard let self else { return }
            let battery = (forcedNoBatt ? nil : BatteryReader.read()) ?? .absent
            let energy = needEnergy ? EnergyModel.snapshot() : EnergySnapshot()
            if needEnergy { SessionEnergy.accumulate(energy) }
            let components = popoverOpen ? PowerInfo.components() : ComponentPower()
            let sensors = popoverOpen
                ? SensorsModel.snapshot(cpuLoad: cpuLoad, ramLoad: ramLoad, components: components)
                : SensorsSnapshot()
            if tickNumber % 15 == 0 {
                AlertsEngine.shared.evaluate(battery: battery, popoverOpen: popoverOpen,
                                             sampledCPULoad: cpuLoad)
            }
            let historyEnergy = tickNumber % 60 == 0 && !needEnergy ? EnergyModel.snapshot() : energy

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hardwareTickInFlight = false
                self.applyHardwareFrame(battery: battery, energy: energy, historyEnergy: historyEnergy,
                                        components: components, sensors: sensors,
                                        popoverOpen: popoverOpen, tickNumber: tickNumber)
            }
        }
    }

    private func applyHardwareFrame(battery b: BatteryInfo, energy: EnergySnapshot,
                                    historyEnergy: EnergySnapshot, components: ComponentPower,
                                    sensors: SensorsSnapshot, popoverOpen: Bool, tickNumber: Int) {
        precondition(Thread.isMainThread)
        if b.present { checkFanAutoBySource(external: b.external) }

        if tickNumber % 60 == 0 {
            func temp(_ v: Double?) -> Double? { (v ?? 0) > 1 ? v : nil }
            History.shared.record(History.Sample(
                ts: Int64(Date().timeIntervalSince1970),
                charge: b.present ? Double(b.charge) : nil,
                health: (b.present && b.health > 1) ? b.displayHealth : nil,
                battTemp: b.present ? temp(b.temperature) : nil,
                cpuTemp: temp(historyEnergy.cpuTemp), gpuTemp: temp(historyEnergy.gpuTemp),
                systemW: historyEnergy.systemWatts > 0.1 ? historyEnergy.systemWatts : nil,
                fanRPM: historyEnergy.fans.max(), charging: b.charging), keepSeconds: 90 * 86400)
        }

        if popoverOpen || SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax).contains("btbatt") {
            BTPeripherals.refreshIfStale()
        }
        updateMenuBar(b, energy)
        if (popoverOpen || menuBarNeedsEnergy), b.present {
            history.append(energy.systemWatts > 0.1 ? energy.systemWatts : b.watts)
            if history.count > 90 { history.removeFirst() }
        }
        if popoverOpen {
            controller.update(battery: b, history: history, components: components,
                              energy: energy, sensors: sensors)
        }
    }

    private var lastPowerExternal: Bool? = nil
    /// Авто fan-профиль на смену источника: применяем профиль AC/battery ТОЛЬКО на реальном РЕБРЕ
    /// (первый тик — молча запоминаем, без применения). Требует Pro + включённую автоматику + демон.
    /// Реверт к системному авто при выходе/краше — по ЛИЗ-истечению (~15 мин), не мгновенно (демон).
    private func checkFanAutoBySource(external: Bool) {
        defer { lastPowerExternal = external }
        guard let prev = lastPowerExternal, prev != external else { return }   // только ребро; первый тик — молча
        guard SettingsStore.fanAutoBySource, Licensing.shared.isPro, FanController.daemonInstalled else { return }
        if AlertsEngine.shared.isBoostActive { return }                       // не перебивать аварийный форс кулеров
        FanController.applyProfileHeadless(named: external ? SettingsStore.fanProfileAC : SettingsStore.fanProfileBattery)
    }

    func refreshApps() {
        guard popover.isShown else { return }             // /usr/bin/top незачем спавнить при закрытом поповере
        PowerInfo.topApps(limit: 18) { [weak self] in self?.controller.updateApps($0) }
    }

    func checkIdleBacklight() {
        guard KeyboardBacklight.available else { return }
        guard SettingsStore.idleBacklight else {
            if idleDimmed { KeyboardBacklight.set(max(0, savedBacklight)); idleDimmed = false }
            return
        }
        let idle = IdleTime.seconds()
        let threshold = Double(SettingsStore.idleSeconds)
        if idle >= threshold && !idleDimmed {
            let cur = KeyboardBacklight.get()
            if cur > 0.02 { savedBacklight = cur; KeyboardBacklight.set(0); idleDimmed = true }
        } else if idle < threshold && idleDimmed {
            KeyboardBacklight.set(max(0, savedBacklight)); idleDimmed = false
        }
    }

    // правый клик / ⌃-клик — меню инструментов; обычный — поповер
    @objc func statusClick() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || (e?.modifierFlags.contains(.control) ?? false) {
            showToolsMenu(from: nil)
        } else {
            togglePopover()
        }
    }

    private func menuIcon(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true                     // тинтуется цветом текста меню, в т.ч. при подсветке
        return img
    }
    @objc func openToolsFromFooter(_ sender: NSButton) { showToolsMenu(from: sender) }
    /// Меню инструментов. `anchor` = вью, под которой раскрывается меню; nil → status item
    /// в строке меню (правый клик). Из футера передаём кнопку «…», иначе меню всплывало бы
    /// у иконки наверху экрана, а не под нажатой кнопкой (и .transient-поповер закрывал бы его).
    private func showToolsMenu(from anchor: NSView?) {
        let btn: NSView
        if let anchor = anchor {
            btn = anchor
        } else {
            guard let sb = statusItem.button else { return }
            btn = sb
        }
        let m = NSMenu()
        // Тумблерные строки-«не закрывай меню» (custom-view): собираем для 1Гц-refresh во время tracking
        var liveRows: [MenuToggleRow] = []
        func toggleRow(in menu: NSMenu, _ title: String, _ symbol: String?,
                       state: @escaping () -> Bool, onToggle: @escaping () -> Void) {
            let row = MenuToggleRow(title: title, symbol: symbol, state: state, onToggle: onToggle)
            let it = NSMenuItem()
            it.view = row
            menu.addItem(it)
            liveRows.append(row)
        }
        func add(_ title: String, _ symbol: String?, _ on: Bool?, _ sel: Selector, enabled: Bool = true) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.image = symbol.flatMap { menuIcon($0) }
            if let on = on { it.state = on ? .on : .off }
            it.isEnabled = enabled
            m.addItem(it)
        }
        func head(_ title: String, _ symbol: String, _ submenu: NSMenu) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.image = menuIcon(symbol)
            it.submenu = submenu
            m.addItem(it)
        }
        // Тумблеры «щёлкай подряд» — custom-view строки, меню НЕ закрывается (Caffeine/NightShift/Finder тоже)
        let caffMenu = NSMenu()
        buildCaffeineRows(into: caffMenu) { liveRows.append($0) }
        head(caffeineHeadTitle(), "cup.and.saucer.fill", caffMenu)
        head(sleepHeadTitle(), "moon.zzz.fill", sleepSubmenu())
        if NightShift.available {
            let nsMenu = NSMenu()
            buildNightShiftRows(into: nsMenu) { liveRows.append($0) }
            head(L("Night Shift"), "moon.fill", nsMenu)
        }
        if !FanController.fans().isEmpty { head(fanHeadTitle(), "fanblades.fill", fanQuickSubmenu()) }
        toggleRow(in: m, L("Тёмная тема"), "circle.lefthalf.filled",
                  state: { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" },
                  onToggle: { [weak self] in
                      DarkModeToggle.toggle()
                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                          guard let self else { return }
                          self.controller.view.appearance = nil
                          self.controller.view.needsDisplay = true
                          self.controller.buildModules()
                          self.refreshMenuBarNow()
                      }
                  })
        if WiFiToggle.available {
            toggleRow(in: m, "Wi-Fi", "wifi", state: { WiFiToggle.isOn }, onToggle: { WiFiToggle.toggle() })
        }
        if BluetoothToggle.available {
            toggleRow(in: m, "Bluetooth", "dot.radiowaves.right",
                      state: { BluetoothToggle.isOn }, onToggle: { BluetoothToggle.toggle() })
        }
        head(L("Разрешение экрана"), "display", displaySubmenu())
        m.addItem(.separator())
        let finderMenu = NSMenu()
        buildFinderRows(into: finderMenu) { liveRows.append($0) }
        head(L("Finder и рабочий стол"), "folder.fill", finderMenu)
        head(L("Для разработчиков"), "hammer.fill", devToolsSubmenu())
        head(L("Gatekeeper и карантин"), "lock.shield.fill", securitySubmenu())

        let clips = ClipboardHistory.shared.items
        if !clips.isEmpty {
            m.addItem(.separator())
            let sub = NSMenu()
            for (i, s) in clips.prefix(12).enumerated() {
                let label = String(s.prefix(48)).replacingOccurrences(of: "\n", with: " ")
                let it = NSMenuItem(title: label, action: #selector(pasteClip(_:)), keyEquivalent: "")
                it.target = self; it.tag = i
                sub.addItem(it)
            }
            head(L("История буфера"), "doc.on.clipboard", sub)
        }

        m.addItem(.separator())
        // [обновления]
        add(L("Проверить обновления…"), "arrow.triangle.2.circlepath", nil, #selector(checkUpdatesFromMenu))
        add(L("Что нового…"), "sparkle.magnifyingglass", nil, #selector(checkUpdatesFromMenu))
        m.addItem(.separator())
        // [поддержка и юридическая информация]
        add(L("Поблагодарить автора"), "heart.fill", nil, #selector(supportAuthorFromMenu))
        add(L("Обратная связь…"), "envelope", nil, #selector(sendFeedbackFromMenu))
        add(L("Лицензии компонентов…"), "doc.text", nil, #selector(openAboutFromMenu))
        m.addItem(.separator())
        add(L("Настройки…"), "gearshape", nil, #selector(openSettingsFromMenu))
        add(L("О программе Kelvin"), "info.circle", nil, #selector(openAboutFromMenu))
        add(L("Выйти из Kelvin"), "power", nil, #selector(NSApplication.terminate(_:)))
        // Если меню открыто из футера, поповер на экране и .transient закрыл бы его при
        // показе меню (потеря фокуса) — временно держим поповер открытым, восстанавливаем после.
        let fromFooter = anchor != nil
        if fromFooter { popover.behavior = .applicationDefined }
        (btn as? NSButton)?.highlight(true)            // нативная подсветка кнопки, пока открыто меню
        // 1Гц-refresh живых строк во время tracking (Wi-Fi/BT асинхронны, Finder-твики пишутся в фоне):
        // обычные таймеры в menu-tracking НЕ тикают → режим .eventTracking обязателен.
        let live = liveRows
        let refresher = Timer(timeInterval: 1.0, repeats: true) { _ in live.forEach { $0.refresh() } }
        RunLoop.main.add(refresher, forMode: .eventTracking)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height), in: btn)
        refresher.invalidate()
        (btn as? NSButton)?.highlight(false)
        if fromFooter { popover.behavior = .transient }
    }
    // (toggleCaffeine/toggleNightShift-селекторы удалены — их работу выполняют MenuToggleRow-замыкания)

    /// «1 ч 05 мин», «5 мин», «42 с» — компактный остаток для пунктов меню.
    private func remainText(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return String(format: L("%d ч %02d мин"), t / 3600, (t % 3600) / 60) }
        if t >= 60 { return String(format: L("%d мин"), (t + 59) / 60) }
        return String(format: L("%d с"), t)
    }

    // — Caffeine с длительностью —
    private func caffeineHeadTitle() -> String {
        if Caffeine.active, let r = Caffeine.remaining { return L("Не засыпать (Caffeine)") + " · " + remainText(r) }
        if Caffeine.active { return L("Не засыпать (Caffeine)") + " · " + L("бессрочно") }
        return L("Не засыпать (Caffeine)")
    }
    /// Caffeine-подменю строками-«не закрывай меню»: щёлкай режимы подряд, галочка обновляется на месте.
    /// «До времени…» остаётся нативным пунктом (открывает модал — меню обязано закрыться).
    private func buildCaffeineRows(into sub: NSMenu, collect: (MenuToggleRow) -> Void) {
        func row(_ title: String, state: @escaping () -> Bool, onToggle: @escaping () -> Void) {
            let r = MenuToggleRow(title: title, symbol: nil, state: state, onToggle: onToggle)
            let it = NSMenuItem(); it.view = r; sub.addItem(it); collect(r)
        }
        row(L("Выключено"), state: { !Caffeine.active }, onToggle: { Caffeine.stop() })
        sub.addItem(.separator())
        for (title, mins) in [(L("15 минут"), 15), (L("1 час"), 60), (L("2 часа"), 120)] {
            row(title, state: { Caffeine.active && abs((Caffeine.remaining ?? -1) - Double(mins) * 60) < 90 },
                onToggle: { Caffeine.start(seconds: TimeInterval(mins) * 60) })
        }
        let until = NSMenuItem(title: L("До времени…"), action: #selector(caffeineUntil), keyEquivalent: "")
        until.target = self
        sub.addItem(until)
        row(L("Бессрочно (пока Kelvin запущен)"),
            state: { Caffeine.active && Caffeine.deadline == nil },
            onToggle: { Caffeine.start() })
        if Caffeine.active, let r = Caffeine.remaining {
            sub.addItem(.separator())
            let info = NSMenuItem(title: String(format: L("Осталось: %@"), remainText(r)), action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
        }
    }
    // (caffeineOff/For/Indefinite удалены — Caffeine-строки зовут API напрямую через MenuToggleRow)
    @objc private func caffeineUntil() {
        guard let secs = askUntilSeconds(L("Не засыпать до времени")) else { return }
        Caffeine.start(seconds: secs)
    }

    // — Таймер сна —
    private func sleepHeadTitle() -> String {
        if let r = SleepTimer.remaining { return L("Сон") + " · " + String(format: L("через %@"), remainText(r)) }
        return L("Сон")
    }
    private func sleepSubmenu() -> NSMenu {
        let sub = NSMenu()
        func item(_ title: String, _ sel: Selector, tag: Int = 0, on: Bool = false) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self; it.tag = tag; it.state = on ? .on : .off
            sub.addItem(it)
        }
        item(L("Уснуть сейчас"), #selector(sleepNow))
        item(L("Погасить экран"), #selector(displaySleepNow))
        sub.addItem(.separator())
        let armed = SleepTimer.isArmed
        for (title, mins) in [(L("Уснуть через 15 минут"), 15), (L("Уснуть через 30 минут"), 30), (L("Уснуть через 60 минут"), 60)] {
            item(title, #selector(sleepIn(_:)), tag: mins)
        }
        item(L("Уснуть через…"), #selector(sleepInCustom))
        if armed, let r = SleepTimer.remaining {
            sub.addItem(.separator())
            let info = NSMenuItem(title: String(format: L("Сон через %@"), remainText(r)), action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            item(L("Отменить таймер сна"), #selector(cancelSleep))
        }
        return sub
    }
    @objc private func sleepNow() { SleepTimer.sleepNow() }
    @objc private func displaySleepNow() { SleepTimer.displaySleepNow() }
    @objc private func sleepIn(_ sender: NSMenuItem) { SleepTimer.arm(minutes: sender.tag) }
    @objc private func cancelSleep() { SleepTimer.cancel() }
    @objc private func sleepInCustom() {
        guard let mins = askMinutes(L("Уснуть через"), suggestion: 45) else { return }
        SleepTimer.arm(minutes: mins)
    }

    /// Запросить число минут (1…1440). nil = отмена/пусто.
    private func askMinutes(_ title: String, suggestion: Int) -> Int? {
        let a = NSAlert(); a.messageText = title
        a.informativeText = L("Сработает, только пока Kelvin запущен.")
        let field = NSTextField(string: String(suggestion))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("ОК")); a.addButton(withTitle: L("Отмена"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        guard let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), n >= 1 else { return nil }
        return min(n, 1440)
    }

    /// Запросить время «до HH:MM» и вернуть число секунд до него (сегодня или завтра).
    private func askUntilSeconds(_ title: String) -> TimeInterval? {
        let a = NSAlert(); a.messageText = title
        a.informativeText = L("Введите время в формате ЧЧ:ММ (24 ч). Удерживает, пока Kelvin запущен.")
        let now = Date()
        let cal = Calendar.current
        let hh = cal.component(.hour, from: now)
        let field = NSTextField(string: String(format: "%02d:%02d", (hh + 1) % 24, 0))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("ОК")); a.addButton(withTitle: L("Отмена"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let parts = field.stringValue.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        var comp = cal.dateComponents([.year, .month, .day], from: now)
        comp.hour = h; comp.minute = m; comp.second = 0
        guard var target = cal.date(from: comp) else { return nil }
        if target <= now { target = target.addingTimeInterval(86400) }   // уже прошло — на завтра
        return target.timeIntervalSince(now)
    }

    /// Night Shift строками-«не закрывай меню»: вкл/держать/теплота щёлкаются подряд.
    private func buildNightShiftRows(into sub: NSMenu, collect: (MenuToggleRow) -> Void) {
        func row(_ title: String, state: @escaping () -> Bool, onToggle: @escaping () -> Void) {
            let r = MenuToggleRow(title: title, symbol: nil, state: state, onToggle: onToggle)
            let it = NSMenuItem(); it.view = r; sub.addItem(it); collect(r)
        }
        row(L("Включён сейчас"), state: { NightShift.isOn }, onToggle: { NightShift.toggle() })
        row(L("Держать всегда включённым"), state: { SettingsStore.nightKeepOn },
            onToggle: { [weak self] in self?.toggleNightKeepOn() })
        sub.addItem(.separator())
        for (title, val) in [(L("Слабо"), Float(0.3)), (L("Средне"), 0.6), (L("Сильно"), 1.0)] {
            row(title, state: { abs(SettingsStore.nightStrength - val) < 0.05 },
                onToggle: {
                    SettingsStore.nightStrength = val
                    if NightShift.isOn || SettingsStore.nightKeepOn { NightShift.enableNow(strength: val) }
                    else { NightShift.setStrength(val) }
                })
        }
    }
    @objc private func toggleNightKeepOn() {
        SettingsStore.nightKeepOn.toggle()
        if SettingsStore.nightKeepOn { NightShift.enableNow() }   // включить сразу; tick будет удерживать
    }
    // (setNightStrength удалён — строки теплоты зовут API напрямую через MenuToggleRow)

    private func displaySubmenu() -> NSMenu {
        let sub = NSMenu()
        let cur = ScreenResolution.current()
        for mode in ScreenResolution.available() {
            let it = NSMenuItem(title: mode.label, action: #selector(applyResolution(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = mode
            if let c = cur, c.w == mode.w, c.h == mode.h { it.state = .on }
            sub.addItem(it)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: L("нет доступных режимов"), action: nil, keyEquivalent: "")) }
        return sub
    }
    @objc private func applyResolution(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ScreenResolution.Mode else { return }
        _ = ScreenResolution.apply(mode)
    }
    // (toggleDark/WiFi/BT-селекторы удалены — верхнеуровневые тумблеры зовут API через MenuToggleRow)
    /// Finder-твики строками-«не закрывай меню» — ГЛАВНЫЙ сценарий владельца: 8 тумблеров подряд.
    /// toggle (defaults write + killall Finder) — В ФОНЕ (синхронный Process на main вешал tracking);
    /// галочку доведёт 1Гц-refresher меню.
    private func buildFinderRows(into sub: NSMenu, collect: (MenuToggleRow) -> Void) {
        for t in FinderTweaks.tweaks {
            let r = MenuToggleRow(title: t.title, symbol: nil,
                                  state: { FinderTweaks.isOn(t) },
                                  onToggle: { DispatchQueue.global(qos: .userInitiated).async { FinderTweaks.toggle(t) } })
            let it = NSMenuItem(); it.view = r; sub.addItem(it); collect(r)
        }
    }

    private func devToolsSubmenu() -> NSMenu {
        let sub = NSMenu()
        if !DevTools.brewInstalled {
            let it = NSMenuItem(title: L("⚙ Установить Homebrew (нужен для остального)"), action: #selector(installHomebrew), keyEquivalent: "")
            it.target = self
            sub.addItem(it)
            return sub
        }
        let head = NSMenuItem(title: L("✓ Homebrew установлен"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        sub.addItem(.separator())
        for cat in DevTools.categories {
            let catItem = NSMenuItem(title: L(cat.title), action: nil, keyEquivalent: "")
            let catMenu = NSMenu()
            for tool in cat.tools {
                let it = NSMenuItem(title: tool.name, action: #selector(installDevTool(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = tool
                it.state = DevTools.isInstalled(tool) ? .on : .off
                catMenu.addItem(it)
            }
            catItem.submenu = catMenu
            sub.addItem(catItem)
        }
        return sub
    }
    @objc private func installHomebrew() {
        let a = NSAlert()
        a.messageText = L("Установить Homebrew")
        a.informativeText = L("Откроется Терминал с официальным установщиком Homebrew. Он попросит пароль и подтверждение. После установки снова открой это меню — появятся инструменты.")
        a.addButton(withTitle: L("Открыть Терминал"))
        a.addButton(withTitle: L("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DevTools.runInTerminal(DevTools.homebrewInstall)
    }
    @objc private func installDevTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? DevTools.Tool, let cmd = DevTools.installCommand(tool) else { return }
        let reinstall = DevTools.isInstalled(tool)
        let a = NSAlert()
        a.messageText = (reinstall ? L("Переустановить ") : L("Установить ")) + tool.name
        a.informativeText = String(format: L("Откроется Терминал с командой:\n\n%@\n\nПрогресс установки будет виден в окне."), cmd)
        a.addButton(withTitle: reinstall ? L("Переустановить") : L("Установить"))
        a.addButton(withTitle: L("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DevTools.runInTerminal(cmd)
    }

    private func securitySubmenu() -> NSMenu {
        let sub = NSMenu()
        let gk = SecurityTools.gatekeeperEnabled
        let gkItem = NSMenuItem(title: gk ? L("Gatekeeper: включён ✓") : L("Gatekeeper: выключен ⚠️"),
                                action: #selector(toggleGatekeeper), keyEquivalent: "")
        gkItem.target = self
        sub.addItem(gkItem)
        let q = NSMenuItem(title: L("Карантин новых загрузок"), action: #selector(toggleQuarantine), keyEquivalent: "")
        q.target = self; q.state = SecurityTools.quarantineOn ? .on : .off
        sub.addItem(q)
        sub.addItem(.separator())
        let clr = NSMenuItem(title: L("Снять карантин с приложения…"), action: #selector(clearQuarantinePick), keyEquivalent: "")
        clr.target = self
        sub.addItem(clr)
        return sub
    }
    @objc private func toggleGatekeeper() {
        let enabled = SecurityTools.gatekeeperEnabled
        let disabling = enabled
        let a = NSAlert()
        a.alertStyle = disabling ? .critical : .informational
        a.messageText = disabling ? L("Выключить Gatekeeper?") : L("Включить Gatekeeper?")
        a.informativeText = disabling
            ? L("⚠️ macOS перестанет проверять подпись приложений — запускаться сможет ЛЮБОЕ, включая вредоносное. Включи обратно, когда закончишь. Может понадобиться подтверждение в Системных настройках → Конфиденциальность и безопасность.")
            : L("Вернёт стандартную защиту: запуск только проверенных приложений.")
        a.addButton(withTitle: disabling ? L("Выключить") : L("Включить"))
        a.addButton(withTitle: L("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let ok = SecurityTools.setGatekeeper(!enabled)
        let done = NSAlert()
        done.messageText = ok ? L("Готово") : L("Не удалось")
        done.informativeText = ok
            ? (disabling ? L("Gatekeeper выключен. Если «неизвестные» приложения всё ещё блокируются — выбери «Anywhere» в Системных настройках → Конфиденциальность и безопасность.")
                         : L("Gatekeeper включён — стандартная защита."))
            : L("Действие отменено или ошибка.")
        done.runModal()
    }
    @objc private func toggleQuarantine() {
        SecurityTools.setQuarantine(!SecurityTools.quarantineOn)
    }
    @objc private func clearQuarantinePick() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = L("Выбери приложение или файл, с которого снять карантин")
        panel.prompt = L("Снять карантин")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let r = SecurityTools.clearQuarantine(url.path)
        let a = NSAlert()
        a.messageText = r.ok ? L("Карантин снят") : L("Не удалось")
        a.informativeText = r.ok
            ? String(format: L("«%@» теперь запустится без блокировки."), url.lastPathComponent)
            : L("Не удалось снять карантин (отменено или нет прав).")
        a.runModal()
    }
    @objc private func openSettingsFromMenu() { SettingsCoordinator.open() }
    @objc private func openAboutFromMenu() { SettingsCoordinator.open(); SettingsCoordinator.select("about") }
    @objc private func supportAuthorFromMenu() { AppConfig.openSupport() }

    // MARK: — быстрые пресеты охлаждения из меню-бара (Авто/Тихо/Баланс/Максимум) + заряд-состояние —
    /// Заголовок пункта «Охлаждение · <текущее состояние>». Честно: без демона или в «Авто» — «система».
    private func fanHeadTitle() -> String {
        let base = L("Охлаждение")
        let id = SettingsStore.activeFanProfileName
        if !FanController.daemonInstalled || id == "auto" { return base + " · " + L("система") }
        return base + " · " + SettingsStore.builtinFanDisplay(id)
    }
    private func fanQuickSubmenu() -> NSMenu {
        let sub = NSMenu()
        // Заряд-состояние (инфо-строка, неактивна).
        let pctText = BatteryReader.systemChargePercent().map { "\($0)%" } ?? "—"
        let chargeLineBase: String
        switch SettingsStore.chargeMode {
        case "sail": chargeLineBase = String(format: L("Заряд %@ · поддержание %d–%d%%"), pctText, SettingsStore.sailLower, SettingsStore.sailUpper)
        default:     chargeLineBase = SettingsStore.chargeLimit < 100
                        ? String(format: L("Заряд %@ · лимит %d%%"), pctText, SettingsStore.chargeLimit)
                        : String(format: L("Заряд %@ · без лимита"), pctText)
        }
        let chargeLine = chargeLineBase
            + (ChargeControl.requiresSystemControl ? " · " + L("не активно") : "")
        let info = NSMenuItem(title: chargeLine, action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        sub.addItem(.separator())
        // Пресеты. Активным считаем: под управлением — активный профиль, иначе «Авто».
        let controlled = FanController.daemonInstalled && SettingsStore.activeFanProfileName != "auto"
        let effective = controlled ? SettingsStore.activeFanProfileName : "auto"
        let presets: [(id: String, title: String, sym: String)] = [
            ("auto", L("Авто (система)"), "a.circle"),
            ("quiet", L("Тихо"), "leaf"),
            ("balance", L("Баланс"), "speedometer"),
            ("turbo", L("Максимум"), "bolt.fill"),
        ]
        for p in presets {
            let it = NSMenuItem(title: p.title, action: #selector(applyFanQuick(_:)), keyEquivalent: "")
            it.target = self
            it.image = menuIcon(p.sym)
            it.representedObject = p.id
            it.state = (p.id == effective) ? .on : .off
            sub.addItem(it)
        }
        return sub
    }
    @objc private func applyFanQuick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == "auto" {
            FanController.applyProfileHeadless(named: "auto")   // демон отпустит; без демона — уже система
            SettingsStore.activeFanProfileName = "auto"
            SettingsCoordinator.refresh()
            return
        }
        // Форс вентиляторов доступен всем; дальше проверяем только системный helper.
        guard Licensing.shared.isPro else { _ = SettingsCoordinator.requirePro(.fans); return }
        // Управление ещё не установлено — ведём в настройки (там ставится root-демон через диалог пароля).
        guard FanController.daemonInstalled else {
            SettingsCoordinator.open()
            SettingsCoordinator.select("power")
            return
        }
        FanController.applyProfileHeadless(named: id)           // сам выставит activeFanProfileName
        SettingsCoordinator.refresh()
    }

    // MARK: пункты меню — обновления и обратная связь
    @objc private func checkUpdatesFromMenu() { Updater.checkManually() }

    @objc private func sendFeedbackFromMenu() {
        if let u = AppConfig.mailto(subject: "Kelvin feedback (\(appVersion))") { NSWorkspace.shared.open(u) }
    }

    @objc private func openHelpFromMenu() {                    // trykelvin.com
        AppConfig.openWebsite()
    }


    /// Менютрекинг-трюк: пока поповер открыт над fullscreen, держим системную строку меню
    /// «в состоянии трекинга меню», чтобы она не схлопывалась обратно и поповер не моргал.
    /// Обещание строго ограничено: только «поповер над fullscreen не моргает» (НЕ «иконка всегда видна»).
    private func postMenuTracking(begin: Bool) {
        let name = begin ? "com.apple.HIToolbox.beginMenuTrackingNotification"
                         : "com.apple.HIToolbox.endMenuTrackingNotification"
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Минимальное главное меню. У LSUIElement-агента оно не видно в строке Apple, но включает
    /// стандартные горячие клавиши: ⌘Z/⌘X/⌘C/⌘V/⌘A в полях ввода и ⌘,/⌘W/⌘M/⌘Q в окнах.
    /// Без него нельзя даже вставить купленный лицензионный ключ с клавиатуры (⌘V не работал).
    private func buildMainMenu() {
        let main = NSMenu()

        // — App —
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("О программе Kelvin"), action: #selector(openAboutFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        // Служебные пункты скрытого app-меню и стандартные хоткеи.
        appMenu.addItem(withTitle: L("Проверить обновления…"), action: #selector(checkUpdatesFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Обратная связь…"), action: #selector(sendFeedbackFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Настройки…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Скрыть Kelvin"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Выйти из Kelvin"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // — Правка — (target = nil → маршрутизация по responder chain к активному полю ввода)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Правка"))
        editMenu.addItem(withTitle: L("Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Выбрать всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // — Окно —
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: L("Окно"))
        winMenu.addItem(withTitle: L("Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: L("Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }
    @objc private func pasteClip(_ item: NSMenuItem) {
        let items = ClipboardHistory.shared.items
        if item.tag < items.count { ClipboardHistory.shared.copy(items[item.tag]) }
    }

    @objc func togglePopover() { togglePopover(fromHotkey: false) }   // совместимость со statusClick/селекторами

    func togglePopover(fromHotkey: Bool) {
        if popover.isShown {
            if Motion.reduced { popover.performClose(nil); return }
            controller.playCloseAnimation { [weak self] in self?.popover.performClose(nil) }
            return
        }
        // Из хоткея приложение может быть неактивным/в чужом fullscreen-спейсе — поднимаем себя.
        if fromHotkey { NSApp.activate(ignoringOtherApps: true) }

        // Экранный rect, к которому привяжем неподвижное прозрачное окно-якорь.
        // В полноэкранном режиме строка меню авто-скрывается и УТАСКИВАЕТ кнопку-якорь наверх:
        // при вызове из хоткея со скрытой строкой якорим к ФИКС-точке у верхней кромки экрана,
        // иначе поповер «съехал» бы частично за кромку.
        let screenRect: NSRect
        var overFullscreen = false                                                 // якоримся над fullscreen (строка скрыта)?
        if fromHotkey, let btn = statusItem.button, statusBarVisible(btn), let win = btn.window {
            screenRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))   // строка видна — обычный якорь к кнопке
        } else if fromHotkey {
            screenRect = hotkeyAnchorRect()                                        // строка скрыта — фикс-точка у кромки
            overFullscreen = true
        } else if let btn = statusItem.button, let win = btn.window {
            screenRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))    // клик по иконке — прежний путь
        } else { return }

        let w = NSWindow(contentRect: screenRect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]  // показаться на fullscreen-спейсе
        w.orderFront(nil)
        popoverAnchor = w
        // Над fullscreen: держим системную строку «в трекинге меню», чтобы она не схлопнулась и поповер не моргал.
        if overFullscreen { postMenuTracking(begin: true); postedMenuTracking = true }
        let anchorView: NSView = w.contentView!

        popover.delegate = self
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        // Собственное окно NSPopover НЕ наследует поведение окна-якоря: над fullscreen без этого оно
        // уходит на дефолтный спейс и «не открывается». Явно разрешаем ему показаться на fullscreen-спейсе.
        if let pwin = popover.contentViewController?.view.window {
            pwin.collectionBehavior.insert(.canJoinAllSpaces)
            pwin.collectionBehavior.insert(.fullScreenAuxiliary)
            if overFullscreen { pwin.level = .statusBar }
            // Нативная стрелка NSPopover — часть window chrome, не AuraView. Без явного
            // цвета при прозрачном контенте AppKit оставлял её почти чёрной.
            pwin.isOpaque = false
            pwin.backgroundColor = controller.popoverChromeColor()
        }
        tick()                                        // isShown уже true → первый полный апдейт сразу
        refreshApps()
        controller.refreshHistoryIfVisible()          // переоткрытие на вкладке «История» → перечитать из БД (selectTab не сработает на той же вкладке)
        popover.contentViewController?.view.window?.makeKey()
        DispatchQueue.main.async { [weak self] in self?.controller.playOpenAnimation() }
    }

    /// Открыть поповер на вкладке «Приватность» из баннера first-conn.
    func openRadarFromAlert() {
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { togglePopover(fromHotkey: true) }
        controller.focusPrivacyTab()
    }

    /// Видна ли строка меню сейчас (т.е. кнопка в досягаемой позиции, не уехала за кромку).
    private func statusBarVisible(_ btn: NSStatusBarButton) -> Bool {
        guard let win = btn.window else { return false }
        let screenRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))
        guard let scr = btn.window?.screen ?? NSScreen.main else { return false }
        // в fullscreen окно статус-бара уезжает над кромкой — верх кнопки выходит за экран
        return screenRect.maxY <= scr.frame.maxY + 1
    }

    /// Фикс-точка у верхней кромки экрана — под обычной позицией иконки (правый край).
    private func hotkeyAnchorRect() -> NSRect {
        // экран под курсором приоритетнее (мультимонитор): в чужом fullscreen key-окно — не наше
        let mouse = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                  ?? NSScreen.main
        guard let scr else { return NSRect(x: 0, y: 0, width: 32, height: 24) }  // нет экранов (clamshell/реконфиг) → честная деградация вместо трапа
        let f = scr.frame
        let h: CGFloat = 24, wdt: CGFloat = 32, inset: CGFloat = 8
        let x = f.maxX - wdt - inset
        let y = f.maxY - h               // под верхней кромкой; поповер раскроется вниз (.minY)
        return NSRect(x: x, y: y, width: wdt, height: h)
    }

    /// Закрытие поповера (в т.ч. транзиентное по клику-вне) → убрать якорь-окно.
    func popoverDidClose(_ notification: Notification) {
        if postedMenuTracking { postMenuTracking(begin: false); postedMenuTracking = false }
        popoverAnchor?.close()
        popoverAnchor = nil
    }
    
    /// Проверка наличия crash reports и показ уведомления пользователю
    private func checkForCrashReports() {
        let scan = CrashReportStore.scan()
        let uploader = CrashReportUploader.shared

        // Восстанавливаем персистентную очередь после предыдущего завершения процесса.
        for report in scan.queuedReports { uploader.enqueue(report) }

        let actionable = scan.allReports
            .filter { $0.state == .discovered || $0.state == .reviewed }
            .sorted { ($0.crashDate ?? $0.discoveredAt) < ($1.crashDate ?? $1.discoveredAt) }
        guard !actionable.isEmpty else { return }

        if SettingsStore.autoSendCrashReports {
            // Настройка согласия уже дана пользователем: ставим в очередь ВСЕ отчёты,
            // а не только первый найденный в текущем scan.
            for report in actionable {
                try? CrashReportStore.updateState(for: report.fingerprint, to: .queued)
                uploader.enqueue(report)
            }
            return
        }

        pendingCrashReports = actionable
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.presentNextCrashReport()
        }
    }

    /// Показывает отчёты последовательно. NSAlert модален, поэтому второй диалог
    /// нельзя открывать до завершения первого.
    private func presentNextCrashReport() {
        guard !presentingCrashReport, !pendingCrashReports.isEmpty else { return }
        presentingCrashReport = true
        let report = pendingCrashReports.removeFirst()
        showCrashNotification(for: report)
        presentingCrashReport = false
        if !pendingCrashReports.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.presentNextCrashReport()
            }
        }
    }
    
    /// Показать карточку уведомления о crash report
    private func showCrashNotification(for report: CrashReportStore.ReportMetadata) {
        let alert = NSAlert()
        alert.messageText = L("Kelvin неожиданно завершил работу")
        alert.informativeText = L("Мы нашли отчёт о сбое. Вы можете отправить обезличенный отчёт разработчику, чтобы помочь исправить эту ошибку.")
        alert.addButton(withTitle: L("Посмотреть"))
        alert.addButton(withTitle: L("Отправить"))
        alert.addButton(withTitle: L("Не отправлять"))
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            try? CrashReportStore.updateState(for: report.fingerprint, to: .reviewed)
            switch previewCrashReport(for: report) {
            case .send:
                try? CrashReportStore.updateState(for: report.fingerprint, to: .consented)
                CrashReportUploader.shared.enqueue(report)
            case .decline:
                try? CrashReportStore.updateState(for: report.fingerprint, to: .declined)
            case .later:
                break // .reviewed останется actionable при следующем запуске
            }
        case .alertSecondButtonReturn:
            try? CrashReportStore.updateState(for: report.fingerprint, to: .consented)
            CrashReportUploader.shared.enqueue(report)
        case .alertThirdButtonReturn:
            try? CrashReportStore.updateState(for: report.fingerprint, to: .declined)
        default:
            break // закрыли диалог — .discovered будет предложен снова
        }
    }

    private enum CrashPreviewDecision { case send, decline, later }

    /// Модальный preview сохраняет явный выбор пользователя: отправить, отказаться
    /// или решить позже. Отдельное не-retained NSWindow раньше закрывалось без действий.
    private func previewCrashReport(for report: CrashReportStore.ReportMetadata) -> CrashPreviewDecision {
        // Санитизируем отчёт для показа
        let result = CrashReportSanitizer.sanitize(
            url: CrashReportStore.sourceURL(for: report),
            reportID: report.reportID,
            sourceFingerprint: report.fingerprint
        )
        guard case .success(let sanitized) = result, !sanitized.containsPII else { return .later }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = sanitized.jsonPreview

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView

        let contentSize = NSSize(width: 620, height: 360)
        textView.frame = NSRect(origin: .zero, size: contentSize)
        scrollView.frame = NSRect(origin: .zero, size: contentSize)

        let preview = NSAlert()
        preview.messageText = L("Обезличенный отчёт о сбое")
        preview.informativeText = report.sourceFilename
        preview.accessoryView = scrollView
        preview.addButton(withTitle: L("Отправить"))
        preview.addButton(withTitle: L("Не отправлять"))
        preview.addButton(withTitle: L("Решить позже"))
        switch preview.runModal() {
        case .alertFirstButtonReturn: return .send
        case .alertSecondButtonReturn: return .decline
        default: return .later
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusAnimationTimer?.invalidate()
        statusAnimationTimer = nil
        usbWatch.stop()        // E1 teardown: релиз итераторов + снятие run-loop source + destroy порта
        GlobalHotkey.shared.teardown()   // снять Carbon-хоткей + хендлер без утечки
        
        // Ожидание завершения активных загрузок crash reports (до 5 секунд)
        CrashReportUploader.shared.waitForCompletion(timeout: 5.0)
    }
}
