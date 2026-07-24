# Kelvin — Go-To-Market план

> Сведён «отделом маркетинга» (6 лидов + CMO), 28 июня 2026. Стадия: предзапуск.

## Позиционирование
**Kelvin — нативная панель в строке меню Mac, которая заменяет 5–6 отдельных утилит** (Stats + coconutBattery + AlDente + Macs Fan Control + Punto + LuLu) одним инструментом: всё видно бесплатно навсегда, управление и автоматизация — за разовые **$19 (без подписки)**, всё локально без телеметрии.

Не «ещё один монитор» (там доминирует iStat) и не «ещё один фаервол» — а категория **«всё-в-одном»**. Главный враг — зоопарк иконок в меню-баре.

**Ведущий tagline:** `One menu-bar app. Ten utilities gone.`
Альтернативы: `Watch everything. Control everything. Pay once.` · `iStat shows you. Kelvin lets you do.` · `Stop renting your Mac utilities.`

### Messaging-пилларах
1. **Всё-в-одном** (ведущий) — одна панель вместо зоопарка, одна иконка вместо шести.
2. **Управляет, а не только смотрит** — мониторы показывают цифры; Kelvin даёт ручки (вентиляторы, лимит заряда, фаервол, раскладка).
3. **Разово, без подписки** — $19 один раз, 2 Mac, триал 14 дней без карты.
4. **Локально и приватно** — данные не покидают Mac, ноль телеметрии.

### ICP (сегменты)
1. **Хранитель дорогого железа** (главный money-сегмент) — бережёт MacBook за $1.5–3.5k, триггер: деградация батареи / вой вентиляторов. Платит за лимит заряда + кривые вентиляторов. Готовность ВЫСОКАЯ (нет бесплатного нуля).
2. **Двуязычный, уставший от облака** (ниша без конкурентов) — RU/UA/PT, не хочет Punto от Яндекса (телеметрия). Платит за локальную авто-раскладку. Уникальный крючок.
3. **Анти-подписочный power user / разработчик** (евангелисты) — устал от подписок, ценит нативность. Часть на бесплатном Stats → монетизировать как Free-воронку + усилителей охвата.

---

## Прайсинг / конверсия
- Держать правило «видит всё бесплатно → платит за управление» железно.
- Lemon Squeezy: базовая цена **$29**, launch-цена **$19** через купон (честный якорь — только если реально поднимешь до $24–29 после окна 60–90 дней).
- Блок «Kelvin заменяет» с суммой цен конкурентов ($100+, часть по подписке → $19 разово).
- Free vs Pro — ОДНА таблица с галочками («Видеть всё — бесплатно. Платите только за управление»).
- Мягкий end-of-trial (anti-dark-pattern): на 14-й день мониторинг работает навсегда, Pro-фичи лочатся с одной кнопкой. Напоминания день 1/7/12.
- Контекстный апселл строго по правилу «затронул Pro-действие → inline-плашка с [Не сейчас]». НИКОГДА в мониторинговых вкладках.
- «1 лицензия = 2 Mac» — заметным пунктом, не сноской.
- Trust-бейдж под CTA: «14 дней гарантии · триал без карты · Lemon Squeezy · вернём без вопросов».
- План мажорного апгрейда v2 в FAQ СЕЙЧАС: текущая версия — обновления бесплатны; v2.0 через ~18–24 мес — платный апгрейд ~$12–15, бесплатно недавним покупателям.

---

## NOW-действия (предзапуск, ничем не блокируются)
1. **Поднять EN-версию лендинга** (сейчас `lang=ru` — блокер для HN/PH/r/macapps). Минимум EN+RU.
2. **Заменить мёртвую Download (href=#) и BUY_URL** на email-форму waitlist «Get early access + launch discount» (Buttondown/Tally/Formspree). Цель **100–300 адресов** до запуска.
3. **Запустить D-U-N-S на CNPJ + Apple Developer ($99) ПРЯМО СЕЙЧАС** — самое долгое (~1–2 нед), критический путь к нотаризации.
4. **Build-in-public в X** — 2–4 поста/нед со скринами.
5. **Прогреть аккаунт Reddit** в r/macapps (10+ кармы за 4–8 нед, иначе бан в день X).
6. **Снять визуалы:** hero-GIF схемы энергопотока (вау-фича), скрины «Железо», fan-curve, лимит заряда, «6 иконок → 1».
7. **Пресс-кит** (icon 1024 + 4–6 скринов + GIF + boilerplate).
8. **Plausible/Cloudflare Analytics** (cookieless) + UTM.
9. Финализировать копию по каналам (готова ниже), вставить {DOMAIN}.
10. **Выбрать домен** — рекомендация `usekelvin.com` / `heykelvin.com` (trykelvin звучит незакоммиченно; kelvin.com.br — редирект под MEI).

---

## Timeline запуска
**T-6..-4 нед (сейчас):** D-U-N-S+Apple Dev → EN-лендинг → waitlist-форма → build-in-public → прогрев Reddit → аналитика → визуалы → пресс-кит.
**T-2 нед (пришёл Developer ID):** нотаризовать DMG → проверить на чистом Mac → завести Lemon Squeezy (storeID/productID/checkoutURL) → заменить плейсхолдеры → end-to-end прогон (скачал→триал→купил→активировал).
**T0 день X (вторник):** мягкий старт — r/macapps + нишевые сабреддиты (НЕ PH первым), дисклоуз «I'm the developer» в начале, весь день в комментах. Питч изданиям под эмбарго.
**T0+3-5 дней:** Product Hunt — отдельный день, 00:01 PT, self-hunt, промокод KELVINPH -30%, GIF.
**T0+7-10 дней:** Show HN — другой день, технический угол, заголовок по гайдлайнам.
**T0+2-4 нед:** MacRumors, alternativeto.net, comparison-страницы, нишевые рассылки, PT-BR (MacMagazine.com.br), первые честные отзывы. *Деньги придут со сдвигом ~2 нед из-за триала — нулевые продажи первые дни это норма.*

## Channel playbook (по приоритету)
- **[high] r/macapps + сабреддиты** — первый канал, мягкий старт. Прогреть аккаунт обязательно.
- **[high] Show HN** — отдельный день, технический угол. Один выстрел на продукт.
- **[high] Email waitlist** — главный множитель первого часа PH/HN. Собрать заранее.
- **[med] Product Hunt** — отдельный день, GIF схемы, self-hunt, KELVINPH -30%.
- **[med] X build-in-public** — за 3–6 нед до запуска.
- **[med] SEO comparison-страницы** — vs iStat/Stats/AlDente/TG Pro/Little Snitch + хаб «Best iStat alternatives 2026».
- **[med] PR-аутрич** — только при готовом EN-лендинге + нотаризации + пресс-ките.
- **[low] MacRumors / alternativeto / awesome-macos PR** — хвост, бэклинки.
- **[low] PT-BR сообщества** — недооценённый рынок под MEI.

## Аутрич-цели
- **9to5Mac** Indie App Spotlight — всё-в-одном, бесплатный мониторинг, без подписки.
- **MacStories** — дизайн Control Center + схема энергопотока + приватность.
- **The Sweet Setup** — «одна утилита заменяет десять» + здоровье батареи.
- **Cult of Mac** — «убийца подписок» + приватность.
- **MacRumors forums** — нативная новинка для Apple Silicon.
- **MacMagazine.com.br** (PT-BR) — стратегически под MEI.
- **Нишевые YouTube 5–50k** про mac-утилиты — лучший реальный ROI, бесплатный Pro-ключ.
- **alternativeto.net** — как альтернатива iStat/Stats/AlDente.
- **Habr / vc.ru** (RU) — «как я сделал»: SMC-реверс, нотаризация, жидкое стекло.

## Риски / анти-паттерны
- ❌ Гнать трафик на сломанную воронку (Download=#, storeID=nil, DMG не нотаризован → Gatekeeper «app is damaged»). Один выстрел — чинить ДО каналов.
- ❌ Запуск без waitlist (нет momentum в первый час).
- ❌ RU-only лендинг при англоязычных каналах.
- ❌ Совмещать PH и Show HN в один день.
- ❌ Накрутка/астротурфинг — бан публичен, убивает бренд на одном имени.
- ⚠️ Model-dependent SMC — на M-серии сенсоры могут врать; честно оговорить + механизм фикса по модели.
- ⚠️ Не конкурировать с iStat на мониторинге; не отбивать ценой бесплатный Stats — монетизировать ICP-1/ICP-2.
- ⚠️ «Фаервол» рядом с Little Snitch — говорить «быстрый фаервол / блок входящих», не «замена Little Snitch». «100% local» должно быть буквально правдой (HN проверит пакеты).
- ⚠️ Не ждать денег в день X (триал сдвигает выручку ~2 нед).

---

## ГОТОВЫЕ АССЕТЫ (копировать)

### Hero (EN-лендинг)
- **H1:** One menu-bar app. Ten utilities gone.
- **Sub:** Power, fans, battery health, quick toggles, bilingual layout fixer and network privacy — in one native macOS panel. Monitor everything free. Take control for a one-time $19. All local, zero telemetry.
- **CTA primary:** Download free · **secondary:** Get Pro — $19, no subscription
- **Micro:** Replaces Stats + coconutBattery + AlDente + Macs Fan Control + LuLu · macOS 11+ · Intel & Apple Silicon · 14-day Pro trial, no card
- *Pre-launch variant (пока store/домен не готовы):* Primary `Get early access` · Secondary `See what's free vs Pro`

### Product Hunt
**Tagline (≤60):** One menu-bar app instead of ten Mac utilities

**Первый коммент мейкера:**
> Hi Product Hunt 👋 I'm Artem, solo dev behind Kelvin.
>
> I got tired of running five separate menu bar apps — one for battery health, one for fan control, one for a firewall, one for layout switching — each with its own icon, its own update nag, some with telemetry. So I built the one I wanted: a single native (Swift/AppKit) panel in the spirit of Control Center.
>
> The rule is simple: you can SEE everything for free, forever — charge, watts, an interactive energy-flow diagram, temps, fans, load. Pro is only for CONTROL and automation (fan curves, charge limit, firewall, layout autofix, custom buttons). One-time $19, two Macs, 14-day full trial, no card needed.
>
> It's 100% local — no analytics, no calls home. It's not on the Mac App Store on purpose: fan control, charge limit, firewall and system daemons can't live inside the sandbox, so I ship a notarized DMG instead.
>
> For PH folks: KELVINPH gives 30% off the first week. Honest feedback very welcome — fire away in the comments, I'm here all day. What menu bar apps would you want this to replace?

### Show HN
**Title:** Show HN: Kelvin – a native, local-only menu bar multitool for macOS

**Первый коммент:**
> Author here. Kelvin is a macOS menu bar app I built in Swift/AppKit (no Electron) to replace the stack of single-purpose utilities I was running: battery health, fan control, a firewall, RU/EN layout autofix, quick toggles.
>
> Technical notes that might interest HN:
> - All monitoring (charge, watts, an interactive energy-flow diagram, per-bus currents, temps, fans) reads from SMC directly — no sudo for the read path. SMC key names are model-dependent, which was the most annoying part; I expose a debug dump to map them.
> - It's local-only: no analytics, no network calls home. The only outbound request is the update check.
> - It's not on the Mac App Store by design — fan control, charge limit (BCLM), firewall and system daemons can't run in the App Store sandbox, so it ships as a notarized DMG.
> - Privileged actions (installing the fan daemon, firewall) go through the system auth prompt, so you see exactly what's being asked.
> - The layout-autofix piece is a local Punto-Switcher-style fixer — no cloud.
>
> Monitoring is free forever; control features are a one-time paid upgrade. Happy to go deep on the SMC reverse-engineering, the daemon model, notarization, or anything else. Feedback and criticism welcome.

### Reddit r/macapps
**Title:** [Developer] Kelvin — I replaced 5 menu bar utilities with one native app (free monitoring, $19 one-time Pro)

**Body:**
> Hi r/macapps — solo dev here, putting my cards on the table up front.
>
> I was running coconutBattery + a fan control app + a firewall + a layout switcher, each eating a menu bar slot. So I built Kelvin: one native (Swift/AppKit) panel in the Control Center style.
>
> Free forever (monitoring): live menu bar readout (charge/watts/temps/fans/CPU/RAM), a glass popover with a charge ring, an interactive energy-flow diagram, temps/fans/load, and basic toggles (Wi-Fi/BT/Caffeine/Night Shift/dark mode), plus battery health/cycles/capacity.
>
> Pro ($19 one-time, 2 Macs, 14-day full trial, no subscription): fan control (curves + thermal protection), battery charge limit, firewall + panic mode, RU/EN layout autofix + snippets, custom command buttons, GPU switching.
>
> The rule: you see everything free, you pay only to control/automate.
>
> 100% local, zero telemetry. Notarized DMG (not App Store — those features need out-of-sandbox access). Intel + Apple Silicon, macOS 11+.
>
> One honest caveat: SMC sensor keys vary by model, so on some Macs a sensor may read oddly — if that happens, tell me your model and I'll fix it. That's exactly the feedback I'm after.
>
> Link: [landing]. AMA about the build.

*(Перед постингом проверить правила саба: флейры [Developer]/[Free]/[Paid], частоту самопромо.)*

### X / Twitter тред-анонс
> 1/ Today I'm launching Kelvin — one native macOS menu bar app that replaced 5 utilities I was juggling: battery health, fan control, a firewall, RU/EN layout autofix, quick toggles. Built solo in Swift/AppKit. 🧵
>
> 2/ The rule: you SEE everything for free, forever. Charge, watts, an interactive energy-flow diagram, temps, fans, CPU/RAM — right in the menu bar. [GIF схемы энергопотока]
>
> 3/ Pro ($19 one-time, no subscription, 2 Macs) unlocks CONTROL: fan curves, battery charge limit, firewall + panic mode, layout autofix, custom command buttons.
>
> 4/ 100% local. No analytics, no calls home. Not on the Mac App Store on purpose — fan control / charge limit / firewall can't live in the sandbox. Notarized DMG instead.
>
> 5/ Free forever + 14-day full trial, no card. Intel & Apple Silicon, macOS 11+. Try it: [link]. Built in public over the last months — thanks to everyone who followed along. RTs hugely appreciated 🙏 #buildinpublic #macOS

### Reviewer outreach email
**Subject:** Kelvin — an all-in-one Mac menu-bar tool (free monitoring, no subscription)
> Hi [First name],
>
> I'm an indie developer and I just finished Kelvin, a native macOS menu-bar app that replaces a stack of single-purpose utilities — power/thermals/fan monitoring, fan control, battery charge limit, a built-in firewall, quick toggles, and a local keyboard-layout fixer — in one Control Center-style panel.
>
> Two things that might interest your readers:
> - Monitoring is free forever; you only pay ($19 once, no subscription) to control/automate.
> - It's fully local — no analytics, no telemetry, nothing phones home.
>
> The interactive real-time power-flow diagram and the glass UI demo really well — happy to send a press kit, screenshots, and a free Pro license for [Publication].
>
> Launching [date]. I can give you early access under embargo if useful.
>
> Link: [usekelvin.com] · Press kit: [URL]
>
> Thanks for your time,
> Artem — [usekelvin.com]

*(Персонализировать первой строкой: сослаться на их недавнюю статью.)*

### Email waitlist за 24ч до PH (НЕ просить голосовать)
**Subject:** Kelvin launches tomorrow — would love your honest eyes on it
> Hi — you signed up to hear when Kelvin goes live. That's tomorrow.
>
> It's a native macOS menu bar multitool: free monitoring forever, $19 one-time Pro for control (fans, charge limit, firewall, layout autofix). 100% local, no telemetry.
>
> We're on Product Hunt tomorrow at 9am PT — if you've got a minute, I'd genuinely value your honest feedback in the comments (good or bad, it helps me more than anything). And of course you can just grab the free version any time: [link].
>
> As a thank-you for being early: KELVINPH gets you 30% off Pro this week.
>
> Thanks for following along,
> Artem
