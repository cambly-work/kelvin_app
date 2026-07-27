# Privileged Service Implementation Status

## ✅ Completed (Этапы 1-8)

### Core Infrastructure
- **PrivilegedProtocol.swift** — Versioned XPC protocol with:
  - Typed requests/responses (no arbitrary commands)
  - Capability enumeration
  - Machine-readable error codes
  - LeaseID for ownership tracking
  - Validated data types (ValidatedFanProfile, ValidatedFirewallRule, ValidatedDomain)

- **PrivilegedServiceManager.swift** — Installation coordinator with:
  - State machine (notInstalled → approvalRequired → installing → healthy)
  - macOS version detection (modern vs legacy)
  - Health check monitoring
  - Repair/uninstall flows

- **PrivilegedServiceImplementation.swift** — Root daemon with:
  - XPC listener delegate
  - Client validation (audit token, code signature placeholder)
  - Request routing to all services
  - Unified logging

### Service Implementations

#### PowerMetricsService
- Safe execution of `/usr/bin/powermetrics`
- Fixed argument allowlist
- Bounded timeout and output
- Structured parsing (no raw text)

#### GPUModeService  
- Intel dual-GPU detection
- Direct `/usr/bin/pmset gpuswitch` calls
- Mode verification after change
- No AppleScript dependency

#### FanChargeService ⭐ NEW
- Lease management with 30s expiry
- RPM range validation (0-6000)
- Temperature safety limits (<100°C critical)
- Charge limit bounds (50-100%)
- Emergency thermal override (>95°C → max fans)
- Automatic rollback on lease expiry

#### FirewallService ⭐ NEW
- socketfilterfw integration
- Path canonicalization and validation
- .app bundle verification
- Atomic enable/disable operations
- Rule add/remove with existence checks

#### HostBlockService ⭐ NEW
- /etc/hosts atomic updates
- Kelvin-marked section isolation
- Backup before modification
- Rollback on failure
- Domain count limit (1000)
- DNS name validation regex

## 📋 Security Features

| Feature | Status | Notes |
|---------|--------|-------|
| No shell injection | ✅ | All args as arrays, no string interpolation |
| Code signature validation | 🟡 | Placeholder, needs SecCode API |
| Bundle ID verification | 🟡 | Mock implementation |
| Fixed binary paths | ✅ | Hardcoded absolute paths |
| Environment sanitization | ✅ | PATH restricted in Process |
| Input validation | ✅ | Ranges, regex, existence checks |
| Lease watchdog | ✅ | Auto-rollback on expiry |
| Atomic file operations | ✅ | Temp file + rename pattern |
| Backup/rollback | ✅ | Hosts and firewall states |
| Emergency overrides | ✅ | Thermal threshold priority |

## 🔧 Next Steps (Remaining Work)

### 1. Launch Daemon Configuration
Create:
- `KelvinPrivilegedService.plist` for launchd
- MachServices registration
- Entitlements file
- Code signing requirements

### 2. Real Code Signature Validation
Replace mock in `validateClient()` with:
```swift
SecCodeCopyGuestWithAttributes(...)
SecCodeCopySigningInformation(...)
// Check kSecCodeInfoBundleIdentifier
// Check kSecCodeInfoTeamIdentifier
```

### 3. Hardware Integration
- Actual SMC access for fan control (needs driver/library)
- Battery charge limit implementation (hardware-specific)
- Model detection for capability filtering

### 4. Migration Logic
- Detect old `powerd`/`fand` daemons
- Stop and remove legacy jobs
- Import compatible settings
- Idempotent migration marker

### 5. UI Integration
- PrivilegedServiceManager bindings to SwiftUI
- Pre-flight dialog before installation
- Status card with health indicator
- Repair/retry flows

### 6. Testing
- Unit tests for validation logic
- XPC security tests (spoofed clients)
- Integration tests (install → operate → uninstall)
- Hardware QA (M1, M2, Intel single/dual GPU)

## 📁 File Structure

```
Sources/
├── PrivilegedProtocol.swift          # Protocol definitions
├── PrivilegedServiceManager.swift    # Installation coordinator
├── PrivilegedServiceImplementation.swift  # Root daemon
├── PowerMetricsService.swift         # powermetrics wrapper
├── GPUModeService.swift              # pmset gpuswitch wrapper
├── FanChargeService.swift            # Fan/lease/thermal management
├── FirewallService.swift             # socketfilterfw wrapper
└── HostBlockService.swift            # /etc/hosts manager

docs/
├── PRIVILEGED_OPERATIONS_INVENTORY.md
└── PRIVILEGED_SERVICE_IMPLEMENTATION.md
```

## 🎯 Definition of Done Progress

| Requirement | Status |
|-------------|--------|
| Single approval for install | 🟡 Manager ready, needs SM integration |
| No password for routine ops | ✅ XPC design supports this |
| No universal root shell API | ✅ Typed enum-only API |
| Client signature validation | 🟡 Framework ready, needs SecCode |
| Version handshake | ✅ Protocol version + capabilities |
| Fan/charge watchdog | ✅ Lease with auto-rollback |
| UI install/repair/uninstall | 🟡 Manager has state machine |
| Legacy daemon migration | ❌ Not implemented |
| Human-readable diagnostics | ✅ Error codes + descriptions |
| macOS 11-12 fallback | 🟡 Manager detects version |
| Security tests | ❌ Not implemented |
| Hardware QA | ❌ Not implemented |

## 🚀 Commit History

1. `f1b8885` — Initial framework with protocol, manager, power metrics, GPU mode
2. `fe29e05` — Fan/Charge/Firewall/HostBlock services with safety checks

---

**Ready for:** Launch daemon plist creation, real code signing integration, and UI binding.
