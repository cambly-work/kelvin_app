# Tests for Crash Reporting System

## Overview

This directory contains unit and integration tests for the crash reporting system.

## Test Files

### CrashReportStoreTests.swift

Tests for `CrashReportStore`:
- Discovery of Kelvin crash reports only
- Ignoring other applications' crashes
- Duplicate detection via fingerprinting
- State transitions (discovered → reviewed → consented → queued → sent/declined)
- Automatic cleanup of expired reports
- Thread safety

### CrashReportSanitizerTests.swift

Tests for `CrashReportSanitizer`:
- Allowlist field extraction
- PII golden tests (must NOT appear in output):
  - Full home paths (`/Users/alice/Documents/...`)
  - Email addresses
  - UUIDs (hardware, serial)
  - License keys
  - Shell arguments
  - Clipboard contents
- Payload size limits
- Malformed .ips handling
- Unicode username handling
- Schema version validation

### CrashBreadcrumbTests.swift

Tests for `CrashBreadcrumbStore`:
- Adding events
- Ring buffer behavior (max 50 entries)
- Timestamp coarsening (minute-level precision)
- Persistence and recovery
- No user-controlled strings in breadcrumbs

### CrashReportUploaderTests.swift

Tests for `CrashReportUploader`:
- Queue state machine
- Retry logic with exponential backoff
- Rate limit handling (429)
- Client error handling (4xx - no retry)
- Server error handling (5xx - retry)
- Network failure handling
- Auto-send toggle behavior
- Cancellation
- Deduplication

### Integration Tests

- Offline → queue → online → sent flow
- Preview matches actual payload
- End-to-end sanitization verification
- Consent flow (manual and auto)

## Running Tests

```bash
# Build and run all tests
swift test

# Run specific test suite
swift test --filter CrashReportSanitizerTests

# Run with coverage
swift test --enable-code-coverage
```

## Golden Test Updates

When updating sanitizer behavior, golden files may need regeneration:

```bash
# Regenerate golden test fixtures
./scripts/update-golden-tests.sh
```

**Important:** Always manually verify golden outputs contain no PII before committing changes.

## Manual QA Checklist

- [ ] Artificial DEBUG crash triggers correct card on next launch
- [ ] Decline does not re-prompt for same crash
- [ ] Consent sends exactly once
- [ ] Payload contains no username/path/license/input text
- [ ] Privacy settings clear in RU/UK/EN/PT
- [ ] Auto-send works only when explicitly enabled
- [ ] Queue survives app restart
- [ ] Network errors don't block app launch
