# BatteryMeter

Лёгкий монитор батареи в строке меню macOS (в духе AlDente/iStat), полностью локальный,
без телеметрии. В строке меню — **🔋NN%**, по клику — поповер с расходом в ваттах,
живым графиком, здоровьем АКБ, температурой, балансом ячеек, разбивкой по железу
(CPU/GPU/DRAM) и топом приложений по энергии.

## Что показывает

**Без прав (сразу):**
- ⚡ Мгновенный расход в ваттах + живой график (90 сек)
- 🌊 **Интерактивная схема потоков энергии** — анимированная диаграмма «адаптер/батарея →
  система → потребители». Ток «течёт» пунктиром по проводам, толщина и скорость ∝ амперам,
  направление меняется при заряде/разряде. Данные из **SMC** (без sudo): напряжения, токи
  по шинам (дисплей, память, CPU, GPU, прочее), адаптер, температуры, вентиляторы.
- 🔋 Заряд, здоровье, циклы, температура, напряжение, ёмкость (Вт·ч)
- 🔬 Баланс по ячейкам (per-cell voltage, из SMC `BC1V/2V/3V`)
- ⏱ Время до разряда
- 📊 Топ приложений по энергии (через `top`, как вкладка «Энергия» в Мониторинге)
- 🪟 Стеклянный фон (`NSVisualEffectView`). *Liquid Glass из macOS 26 — отдельный SDK;
  на Sequoia используется нативный vibrancy.*

**С root-хелпером (опционально):**
- Разбивка мощности по железу: CPU / GPU / DRAM / Package (через `powermetrics`)

> SMC-ключи зависят от модели. Этот билд настроен под MacBookPro11,x (Intel). На других
> маках имена ключей (`B0AC`, `ILDc`, `IC0r`, …) могут отличаться — проверь через
> отладочный дамп и поправь в `EnergyModel.swift`.

## Сборка

Нужны только Command Line Tools (полный Xcode не требуется):

```bash
./build.sh          # → BatteryMeter.app
```

## Установка

```bash
./install-app.sh    # копирует в /Applications + автозапуск + запуск
```

Разбивка по железу (один раз, нужен sudo — powermetrics требует root):
открой поповер → «Установить хелпер…», либо вручную:

```bash
sudo /Applications/BatteryMeter.app/Contents/Resources/install-helper.sh
```

Хелпер ставит фоновый `LaunchDaemon`, который раз в секунду снимает `powermetrics`
и пишет последний сэмпл в `/Library/Application Support/BatteryMeter/power.txt`.
Само приложение работает без прав и просто читает этот файл.

## Удаление

```bash
./uninstall-app.sh                                                   # приложение + автозапуск
sudo /Applications/BatteryMeter.app/Contents/Resources/uninstall-helper.sh   # root-демон
```

## Отладочные режимы (env)

- `BM_DUMP=1` — печатает все значения (включая SMC-энергопоток) в консоль и выходит
- `BM_SHOWCASE=1` — показывает весь UI в обычном окне (для скриншотов диаграммы)
- `BM_AUTOSHOW=1` — автопоказ поповера при запуске
- `BM_POWERFILE=/path` — переопределяет файл хелпера powermetrics (для тестов парсера)

## Структура

```
Sources/BatteryReader.swift   чтение IORegistry (AppleSmartBattery), без sudo
Sources/SMCReader.swift       низкоуровневый доступ к Apple SMC (80-байт структура)
Sources/EnergyModel.swift     снимок энергопотока: токи/напряжения/темпы/вентиляторы
Sources/FlowView.swift        анимированная схема потоков тока (CALayer + пунктир)
Sources/PowerInfo.swift       парсинг powermetrics + топ приложений (top)
Sources/GraphView.swift       спарклайн расхода
Sources/main.swift            строка меню (NSStatusItem) + стеклянный поповер
helper/                       root-демон powermetrics + установщики
```

## Примечание про powermetrics

Парсер ищет строки `CPU Power:`, `GPU Power:`, `DRAM Power:`, `Package Power:`
и `derived package power`. На разных версиях macOS/железе подписи могут отличаться —
если в поповере по железу прочерки, посмотри реальный вывод
`sudo powermetrics -s cpu_power -n 1` и поправь метки в `PowerInfo.watts(...)`.
