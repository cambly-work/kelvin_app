# План оставшихся работ по системе отчётов о сбоях

## Текущий статус: 10/11 этапов завершено ✅

Все клиентские компоненты реализованы и проинтегрированы. Осталась только серверная часть.

---

## ✅ Завершённые работы

### Клиентская часть (Swift)

1. **CrashReportStore.swift** — хранилище с дедупликацией и state machine
2. **CrashReportSanitizer.swift** — санитизатор с allowlist (PII-free)
3. **CrashBreadcrumb.swift** — журнал событий (enum, без строк)
4. **CrashReportPreview.swift** — SwiftUI preview отчёта
5. **CrashNotificationView.swift** — уведомление при запуске
6. **CrashReportingSettingsView.swift** — настройки приватности
7. **CrashReportUploader.swift** — очередь с retry logic
8. **main.swift** — интеграция (breadcrumb tracking, crash detection)
9. **Settings.swift** — настройка autoSendCrashReports

### Тесты

1. **CrashReportSanitizerTests.swift** — unit тесты с PII golden tests
2. **CrashReportIntegrationTests.swift** — integration тесты workflow

### Документация

1. **docs/crash-reporting-policy.md** — политика обработки данных
2. **docs/BACKEND_API_SPEC.md** — спецификация backend API
3. **docs/privacy.html** — обновлённая privacy policy
4. **QA.md** — checklist для manual QA
5. **CRASH_REPORTING_STATUS.md** — статус реализации

### Скрипты

1. **archive-dsyms.sh** — архивация dSYM для symbolication
2. **build.sh** — обновлён для вызова archive-dsyms.sh

---

## ⏳ Оставшиеся задачи

### 1. Backend endpoint (приоритет: высокий)

**Где:** Отдельный репозиторий / сервис  
**Спецификация:** `docs/BACKEND_API_SPEC.md`

Требуется реализовать:

- [ ] HTTPS endpoint `POST /api/v1/crash-reports`
- [ ] Rate limiting (10/час, 50/день с IP)
- [ ] Validation schema version (только v1)
- [ ] Deduplication по fingerprint (24 часа)
- [ ] Symbolication pipeline (dSYM + symbolicatecrash)
- [ ] Retention policy (90 дней raw, 1 год symbolicated)
- [ ] Минимизация access logs (IP ≤ 24 часа)
- [ ] Monitoring dashboard (Grafana/Datadog)
- [ ] Alerting (>100 крашей/час, error rate >5%)

**Пример кода:** См. `docs/BACKEND_API_SPEC.md` (Node.js/Express + PostgreSQL)

**Оценка времени:** 2-3 дня на MVP

---

### 2. CI/CD интеграция (приоритет: средний)

**Где:** GitHub Actions / CircleCI / GitLab CI

Требуется добавить:

```yaml
# Пример для GitHub Actions
- name: Archive dSYMs
  run: ./archive-dsyms.sh
  
- name: Upload dSYMs to backend
  run: |
    curl -X POST https://backend.kelvin.app/api/v1/dsyms \
      -H "Authorization: Bearer $CRASH_REPORTING_TOKEN" \
      -F "file=@dsyms/Kelvin-${{ env.VERSION }}-${{ env.BUILD }}-dsyms.tar.gz"
```

- [ ] Сохранение артефактов dSYM
- [ ] Загрузка dSYM на backend после релиза
- [ ] Secret token в CI variables
- [ ] Уведомления об ошибках загрузки

**Оценка времени:** 0.5 дня

---

### 3. Manual QA (приоритет: высокий перед релизом)

**Чеклист из QA.md:**

- [ ] Искусственный DEBUG crash (через `fatalError()`)
- [ ] Следующий запуск показывает корректную карточку
- [ ] Отказ не повторяет nag (не надоедает)
- [ ] Согласие отправляет один раз (нет дубликатов)
- [ ] В payload нет username/path/license/input text
- [ ] Privacy settings понятны на RU/UK/EN/PT
- [ ] Offline → queue → online → sent работает
- [ ] Preview совпадает с отправляемым payload
- [ ] Auto-send toggle работает (вкл/выкл)

**Оценка времени:** 1 день

---

### 4. Обновление release.sh (приоритет: низкий)

Если существует отдельный скрипт для релизов:

- [ ] Добавить вызов `archive-dsyms.sh`
- [ ] Версионирование архива (version-build)
- [ ] Автозагрузка на backend (опционально)

---

## Timeline

| Задача | Оценка | Приоритет | Зависимости |
|--------|--------|-----------|-------------|
| Backend MVP | 2-3 дня | Высокий | — |
| CI/CD интеграция | 0.5 дня | Средний | Backend endpoint |
| Manual QA | 1 день | Высокий | Backend endpoint |
| Release script | 0.5 дня | Низкий | — |

**Итого:** 4-5 рабочих дней до полного завершения

---

## Риски

1. **Backend задержка** — можно релизить без автоматической отправки, только manual send
2. **Symbolication сложности** — начать с простых текстовых отчётов, symbolication добавить позже
3. **Privacy review** — заранее согласовать политику с юристами

---

## Rollout стратегия

### Phase 1 (сейчас)
- ✅ Все клиентские компоненты готовы
- ✅ Интеграция в main.swift
- ✅ Тесты написаны

### Phase 2 (после backend)
- [ ] Deploy backend на staging
- [ ] Integration тесты с реальным endpoint
- [ ] Manual QA

### Phase 3 (production)
- [ ] Backend на production
- [ ] Включить feature flag для 10% пользователей
- [ ] Мониторинг ошибок/отправкок
- [ ] Постепенное увеличение до 100%

---

## Контакты

- **Разработчик клиентской части:** [ваше имя]
- **Backend разработчик:** [требуется назначить]
- **QA инженер:** [требуется назначить]

**Дата:** 2024-01-15  
**Статус:** Готово к передаче backend-команде
