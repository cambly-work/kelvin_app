# Backend API для приёма отчётов о сбоях Kelvin

## Endpoint

```
POST /api/v1/crash-reports
Content-Type: application/json
```

## Требования к серверу

### Безопасность

- **HTTPS обязателен** — транспортное шифрование
- **Max body size**: 512 KB (отклонять запросы больше с 413)
- **Rate limiting**: 
  - Максимум 10 отчётов в час с одного IP
  - Максимум 50 отчётов в день с одного IP
  - Возвращать `429 Too Many Requests` с заголовком `Retry-After`
- **Не требовать лицензионный ключ** — crash reporting не должен зависеть от лицензии
- **Не сохранять IP** в логах или минимизировать retention (≤ 24 часа)

### Validation

Сервер обязан проверять:

```json
{
  "schema_version": 1,
  "app_id": "app.trykelvin.mac",
  "app_version": "1.0",
  "build_number": "100",
  "macos_version": "14.0",
  "macos_build": "23A344",
  "hw_model": "MacBookPro18,1",
  "architecture": "arm64",
  "exception_type": "EXC_BAD_ACCESS",
  "termination_reason": "Namespace SIGNAL, Code 0x000000000000000b",
  "crashed_thread_frames": [...],
  "binary_images": [...],
  "breadcrumbs": [...],
  "timestamp": "2024-01-15T10:30:00Z"
}
```

Обязательные поля:
- `schema_version` — только версия 1 поддерживается
- `app_id` — должен быть `app.trykelvin.mac`
- `app_version` — семантическая версия
- `build_number` — integer build
- `timestamp` — ISO 8601 формат

Неизвестные поля игнорировать (forward-compatible дизайн).

### Response

Успех:
```
HTTP/1.1 202 Accepted
Content-Type: application/json

{
  "report_id": "opaque-uuid-string",
  "received_at": "2024-01-15T10:30:05Z",
  "status": "queued_for_symbolication"
}
```

Ошибки:
- `400 Bad Request` — неверная схема, отсутствующие обязательные поля
- `413 Payload Too Large` — тело больше 512 KB
- `429 Too Many Requests` — rate limit превышен
- `500 Internal Server Error` — внутренняя ошибка сервера

### Deduplication

Сервер должен дедуплицировать отчёты по fingerprint:
- Вычислять хэш от `app_version + build_number + exception_type + crashed_thread_hash`
- Если идентичный отчёт уже получен за последние 24 часа — отклонять с `409 Conflict`
- Возвращать существующий `report_id`

### Symbolication

После получения отчёта:

1. Извлечь `binary_images` из отчёта
2. Найти соответствующий dSYM по UUID бинаря
3. Запустить symbolication (например, через `symbolicatecrash` или встроенный parser)
4. Сохранить символицированный стек
5. Привязать к `report_id`

dSYM архивы должны быть загружены заранее через `archive-dsyms.sh`.

### Retention Policy

- **Raw отчёты**: хранить ≤ 90 дней
- **Symbolicated отчёты**: хранить ≤ 1 год
- **Агрегированная статистика** (без PII): бессрочно
- **IP адреса в логах**: ≤ 24 часа

### Access Logs

Минимизировать логи:
- Не логировать тело запроса
- Не логировать query parameters
- Логировать только: timestamp, status code, response time, user agent
- IP адрес — опционально, с коротким retention

### Monitoring

Отслеживать метрики:
- Количество отчётов в час/день
- Процент успешных/неуспешных загрузок
- Средний размер payload
- Rate limit срабатывания
- Ошибки symbolication

### Пример реализации на Node.js/Express

```javascript
const express = require('express');
const rateLimit = require('express-rate-limit');
const crypto = require('crypto');

const app = express();

// Max body size: 512 KB
app.use(express.json({ limit: '512kb' }));

// Rate limiting: 10 requests per hour per IP
const limiter = rateLimit({
  windowMs: 60 * 60 * 1000, // 1 hour
  max: 10,
  message: { error: 'Too many requests', retry_after: 3600 },
  standardHeaders: true,
  legacyHeaders: false,
});

app.post('/api/v1/crash-reports', limiter, async (req, res) => {
  const report = req.body;
  
  // Validate schema version
  if (report.schema_version !== 1) {
    return res.status(400).json({ error: 'Unsupported schema version' });
  }
  
  // Validate required fields
  const required = ['app_id', 'app_version', 'build_number', 'timestamp'];
  for (const field of required) {
    if (!report[field]) {
      return res.status(400).json({ error: `Missing required field: ${field}` });
    }
  }
  
  // Validate app_id
  if (report.app_id !== 'app.trykelvin.mac') {
    return res.status(400).json({ error: 'Invalid app_id' });
  }
  
  // Compute fingerprint for deduplication
  const fingerprintData = `${report.app_version}-${report.build_number}-${report.exception_type}-${JSON.stringify(report.crashed_thread_frames?.slice(0, 5))}`;
  const fingerprint = crypto.createHash('sha256').update(fingerprintData).digest('hex');
  
  // Check for duplicate (last 24 hours)
  const existingReport = await database.findRecentReport(fingerprint, hours: 24);
  if (existingReport) {
    return res.status(409).json({ 
      report_id: existingReport.id,
      status: 'duplicate'
    });
  }
  
  // Generate report ID
  const reportId = crypto.randomUUID();
  
  // Store report
  await database.insertReport({
    id: reportId,
    fingerprint,
    ...report,
    received_at: new Date().toISOString(),
    status: 'queued_for_symbolication'
  });
  
  // Queue for symbolication
  await symbolicationQueue.add({ reportId, report });
  
  // Respond
  res.status(202).json({
    report_id: reportId,
    received_at: new Date().toISOString(),
    status: 'queued_for_symbolication'
  });
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

app.listen(3000, () => {
  console.log('Crash reporting server running on port 3000');
});
```

### Database Schema (PostgreSQL)

```sql
CREATE TABLE crash_reports (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  fingerprint TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  app_id TEXT NOT NULL,
  app_version TEXT NOT NULL,
  build_number TEXT NOT NULL,
  macos_version TEXT,
  macos_build TEXT,
  hw_model TEXT,
  architecture TEXT,
  exception_type TEXT,
  termination_reason TEXT,
  crashed_thread_frames JSONB,
  binary_images JSONB,
  breadcrumbs JSONB,
  timestamp TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ DEFAULT NOW(),
  status TEXT DEFAULT 'queued_for_symbolication',
  symbolicated_at TIMESTAMPTZ,
  ip_address INET,  -- удаляется через 24 часа
  user_agent TEXT
);

-- Index for deduplication
CREATE INDEX idx_crash_reports_fingerprint_received ON crash_reports(fingerprint, received_at);

-- Index for querying by version
CREATE INDEX idx_crash_reports_app_version ON crash_reports(app_version, build_number);

-- Function to auto-delete old IP addresses
CREATE OR REPLACE FUNCTION purge_old_ip_addresses() RETURNS trigger AS $$
BEGIN
  UPDATE crash_reports SET ip_address = NULL WHERE received_at < NOW() - INTERVAL '24 hours';
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Trigger to purge IPs every hour
CREATE EVENT TRIGGER purge_ips_hourly
ON ddl_command_end
WHEN TAG IN ('CREATE TABLE', 'ALTER TABLE')
EXECUTE FUNCTION purge_old_ip_addresses();
```

### CI/CD Integration

Добавить в CI pipeline после успешного билда:

```yaml
# Пример для GitHub Actions
- name: Archive dSYMs
  run: ./archive-dsyms.sh
  
- name: Upload dSYMs to backend
  run: |
    curl -X POST https://backend.example.com/api/v1/dsyms \
      -H "Authorization: Bearer $SECRET_TOKEN" \
      -F "file=@dsyms/Kelvin-${{ env.VERSION }}-${{ env.BUILD }}-dsyms.tar.gz"
```

## Privacy Compliance

Сервер должен соответствовать заявленной privacy policy:

- [ ] Не собирать IP адреса на постоянной основе
- [ ] Не требовать лицензионный ключ
- [ ] Не связывать crash reports с аналитикой
- [ ] Не передавать данные третьим сторонам
- [ ] Шифровать данные at rest и in transit
- [ ] Иметь политику удаления данных
- [ ] Предоставлять пользователю информацию о хранящихся отчётах (опционально)

## Testing

Тестовый endpoint для разработки:

```
POST https://httpbin.org/post  # Echo back request for debugging
```

Для production testing использовать staging environment:

```
POST https://staging.kelvin.app/api/v1/crash-reports
```

## Monitoring Dashboard

Рекомендуемые метрики для Grafana/Datadog:

1. **Volume**: Crash reports per hour/day
2. **Success Rate**: 2xx vs 4xx/5xx responses
3. **Latency**: P50/P95/P99 upload time
4. **Deduplication**: Duplicate reports rejected
5. **Symbolication**: Success/failure rate, processing time
6. **Storage**: Total reports, storage growth

## Alerting

Настроить алерты на:

- > 100 crash reports в час (возможна проблема в релизе)
- Error rate > 5% (проблемы с backend)
- Symbolication failure rate > 10%
- Storage > 80% capacity

---

**Контакт для вопросов**: разработчик Kelvin
**Дата последнего обновления**: 2024-01-15
