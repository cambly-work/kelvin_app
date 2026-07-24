
# План: Глубокая визуальная переработка Settings — Только дизайн

## Проблемы (по жалобе пользователя):
1. **Сайдбар** — плотный (spacing=2), скучный, плоские кнопки, крошечные иконки 20px, нет визуальных групп-заголовков
2. **Контент** — грубый, карточки слабые (тень 0.04, fill слишком прозрачный), нет визуального веса
3. **Карточки** — плоские, border/subtle fill не дают ощущения glass
4. **Типографика** — 12pt medium на сайдбаре слишком мелко, caption 11pt теряется, нет контраста между уровнями
5. **Иерархия** — 7 groupHeaders в Basics/5 в NetSec без визуального разделения, все выглядят одинаково
6. **NetSec** — лес: 5 групп, 10+ карточек, 3 уровня вложенности, до 300 строк

## Решение: 6 этапов, ~200 строк изменений

---

### Этап 1: Сайдбар — просторнее, групповые заголовки (Settings.swift, -60/+70 строк)

**buildLayout()** — правки sidebar:

| Что | Было | Станет | Почему |
|-----|-------|--------|--------|
| Icon tile size | 20×20, cornerRadius=5, symbol 11pt | **26×26, cornerRadius=6, symbol 14pt** | Крупнее, как в macOS System Settings |
| Button height | 34 | **38** | Больше воздуха |
| Stack spacing | 2 | **3** | Меньше слипаются |
| Sidebar width | 210 | **228** | Компенсировать увеличение иконок |
| Button width | 188 | **206** | = 228 - 10*2 insets |
| Top inset | 46 | **50** | Больше air над кнопками |
| Group gap | 10 (plain NSView) | **18** | Чётче разделение групп |
| Sidebar font | Design.Font.callout (12pt medium) | **13pt medium** | Читаемее |
| Button corner radius | 7 | **8** | Соответствие группе chip |

**Групповые заголовки** — добавить `SKSidebarLabel` (аналог SKGroupHeader, но для sidebar):
- Перед каждой группой кнопок: подпись "Основные", "Устройства", "Приложения"
- `Design.Font.micro` (10pt semibold, uppercase, kern +0.5, `tertiaryLabelColor`)
- Height constraint: 16
- Spacing: 12 после заголовка перед первой кнопкой, 2 между кнопками

Группы:
```
[нет заголовка]   — Поддержать Kelvin
"Основные"        — Основные
"Устройства"      — Питание и охлаждение, Клавиатура и ввод, Поповер и уведомления
"Сеть"            — Сеть и защита
"О приложении"    — О программе
```

**SidebarButton.paint()** — усиление выбранного состояния:
- Selected: accentMuted вместо controlAccentColor.withAlpha(0.26) — брендовый teal вместо синего
- Hover: labelColor alpha 0.08 вместо 0.06

---

### Этап 2: Карточки — больший вес, глубже glass (SettingsKit.swift, ~10 строк)

**SettingsCard.updateLayer()** — усиление:
| Что | Было | Станет |
|-----|-------|--------|
| Shadow opacity (dark) | 0.06 | **0.12** |
| Shadow opacity (light) | 0.04 | **0.08** |
| Shadow radius | 6 | **10** |
| Shadow offset | (0, -2) | **(0, -3)** |
| surfaceFill (dark) | white(0.10) | **white(0.12)** |
| surfaceRim (dark) | white(0.14) | **white(0.16)** |
| surfaceFill (light) | white(0.58) | **white(0.62)** |
| surfaceRim (light) | white(0.68) | **white(0.72)** |

Карточки станут более «осязаемыми» — больше shadow, чуть плотнее fill.

---

### Этап 3: Контент-область — больше воздуха, лучше ритм (Settings.swift + SettingsKit.swift)

**select() doc insets:**
| Что | Было | Станет |
|-----|-------|--------|
| Top | 30 | **36** |
| Bottom | 24 | **32** |

**SK.scaffold spacing:**
| Что | Было | Станет |
|-----|-------|--------|
| Default spacing | 12 (s3) | **14** |
| Title-to-subtitle | 4 (s1) | **6** |
| Subtitle-to-first | 16 (s4) | **20** |
| groupHeader above | 16 (s4) | **20** |
| groupHeader below | 6 | **8** |

**SK.rowHeight:** 40 → **44** (возвращает предыдущее значение — строки не были «were 44» по ошибке, 44 даёт лучший воздух)

**SK.infoRow minHeight:** 34 → **38**

**SK.readoutRow minHeight:** 48 → **52**

**SK.card separator:** Leading inset 14 → **16** (больше отступ от края)

---

### Этап 4: Типографика — контраст между уровнями (Design.swift, 6 строк)

| Токен | Было | Станет | Зачем |
|-------|-------|--------|-------|
| title | 20pt semibold | **22pt semibold** | Сильнее акцент секции |
| headline | 15pt semibold | **15pt semibold** | Без изменений |
| body | 13pt regular | **13pt regular** | Без изменений |
| caption | 11pt regular | **11pt regular** | Без изменений |
| callout | 12pt medium | **12pt medium** | Без изменений (sidebar теперь 13pt inline) |
| micro | 10pt semibold | **10pt semibold** | Без изменений |
| groupHeader (SKGroupHeader) | calloutEmph (12pt semibold) | **13pt semibold** | Чуть крупнее для контраста |

---

### Этап 5: NetSec — сокращение групп, визуальные breaks (Settings.swift, ~20 строк)

**buildNetSec()** — сливаем 5 групп в 3:

```
Группа 1: "Защита"
  — Фаервол toggle + stealth + block unsigned (было отдельной группой)
  — VPN статус + профили (было отдельной группой)
  
Группа 2: "Подключения"
  — Список активных подключений (оставляем как есть)

Группа 3: "Дополнительно"
  — Disclosure: Правила по программам
  — Disclosure: Журнал сеанса  
  — Disclosure: Блокировка доменов
```

Статус-карточку (netsecStatusCard) оставляем перед первой группой без groupHeader.

VPN orphan infoRow оборачиваем в SK.card.

---

### Этап 6: Устранение визуальных несогласованностей (Settings.swift, ~15 строк)

Все orphan `SK.infoRow` / `SK.disclosure` вне карточек оборачиваем:

1. **buildPower → buildFansItems():**
   - Standalone `SK.disclosure("Auto by power source")` → обернуть в `SK.card([disclosure])`
   - Standalone `SK.infoRow("Safety note")` → обернуть в `SK.card([infoRow])`

2. **buildHub():**
   - Standalone `SK.disclosure("Custom toggle")` → обернуть в `SK.card([disclosure])`
   - Standalone `SK.infoRow("Threshold rules...")` → обернуть в `SK.card([infoRow])`

3. **buildNetSec():**
   - VPN orphan `infoRow` → обернуть в `SK.card([infoRow])`

---

## Не делаем (сохраняем функциональность):
- ✗ Не трогаем билд-методы (select, switch, build*)
- ✗ Не удаляем ни один обработчик
- ✗ Не трогаем FanCurveView, LiveTraceView, GlassButton
- ✗ Не рефакторим NetSec функционал (только перестановка визуальных групп)
- ✗ Не добавляем новых SK.* компонентов
- ✗ Не трогаем Design.swift кроме 2 токенов (title, groupHeader)

## Ожидаемый эффект:
- Сайдбар: крупнее иконки, больше воздуха, групповые заголовки — «аэропорт табло» вместо плотного списка
- Карточки: ощутимая глубина, тени заметнее, fill плотнее
- Контент: ритмичнее spacing, строки выше → меньше тесноты
- NetSec: 3 группы вместо 5 — в 2 раза меньше визуального «шума»
- Все orphan rows внутри карточек — единообразие

## Порядок реализации:
1. Этап 2 (SettingsKit —卡片 вес) — независим от всего
2. Этап 3 (SettingsKit spacing + Settings insets) — зависит от 2
3. Этап 4 (Design.swift типографика) — независим
4. Этап 1 (Settings.swift сайдбар) — зависит от 4
5. Этап 5 (NetSec группы) — зависит от 2,3
6. Этап 6 (orphan wrapping) — зависит от 2,5
7. Компиляция и проверка
