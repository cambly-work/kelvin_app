# Планы реализации Kelvin

Документы для последовательной переработки продукта:

1. `IMPLEMENTATION_PLAN_APPLE_SILICON_SENSORS.md`
   - датчики Intel/Apple Silicon;
   - пассивное охлаждение;
   - диагностика автоязыка.
2. `IMPLEMENTATION_PLAN_UPDATES.md`
   - подписанные in-app обновления;
   - appcast/release pipeline;
   - совместимость app и privileged service.
3. `IMPLEMENTATION_PLAN_CRASH_REPORTING.md`
   - добровольные обезличенные crash reports;
   - preview/consent;
   - backend, очередь и symbolication.
4. `IMPLEMENTATION_PLAN_PRIVILEGED_SERVICES.md`
   - единый root service;
   - XPC;
   - fan/charge/powermetrics/firewall/hosts/GPU;
   - однократное системное одобрение;
   - миграция и удаление старых демонов.
5. `IMPLEMENTATION_PLAN_GPU_SWITCHING.md`
   - сфокусированный GPU MVP;
   - переключение из Settings и popover;
   - одноразовая установка привилегированного сервиса;
   - автоматика по питанию от сети/батареи;
   - security и hardware QA.

## Рекомендуемый порядок проектов

1. Сначала датчики и диагностический отчёт.
2. Затем service protocol и read-only health handshake.
3. Затем crash inbox/sanitizer без отправки.
4. Затем новый updater и version compatibility.
5. Затем перенос `powermetrics` и GPU switching в service.
6. Затем перенос fan/charge после отдельного hardware QA.
7. Затем backend и добровольная отправка crash reports.
8. В последнюю очередь firewall/hosts и удаление старых privileged путей.

Причина порядка: сначала появляется наблюдаемость и versioned foundation, затем выполняются рискованные системные изменения.

## Общие release gates

- никакого скрытого расширения телеметрии;
- никакого универсального root command runner;
- подпись и identity verification для app, updates и service;
- graceful degradation;
- rollback для системных действий;
- i18n RU/UK/EN/PT;
- unit/integration/hardware QA;
- обновлённые privacy, release и recovery документы.
