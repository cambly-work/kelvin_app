# Privileged Service Implementation Status

## Completed Components (Stage 5-8)

### Core Services
- ✅ `Sources/PrivilegedProtocol.swift` — Versioned XPC protocol with typed requests/responses
- ✅ `Sources/PrivilegedServiceXPCInterface.swift` — XPC listener with client code signature validation
- ✅ `Sources/PrivilegedServiceImplementation.swift` — Main service implementation stub
- ✅ `Sources/PrivilegedServiceManager.swift` — Installation coordinator with state machine

### Functional Services
- ✅ `Sources/PowerMetricsService.swift` — Safe powermetrics execution with parsing
- ✅ `Sources/GPUModeService.swift` — GPU switching for Intel dual-GPU Macs
- ✅ `Sources/FanChargeController.swift` — Fan profiles and charge limits with lease watchdog
- ✅ `Sources/FirewallService.swift` — socketfilterfw integration with path validation
- ✅ `Sources/HostBlockService.swift` — /etc/hosts management with atomic writes and rollback

### Configuration Files
- ✅ `KelvinPrivilegedService/LaunchDaemon.plist` — launchd configuration
- ✅ `KelvinPrivilegedService/Info.plist` — Bundle info for the service
- ✅ `KelvinPrivilegedService/KelvinPrivilegedService.entitlements` — Sandbox entitlements

## Security Features Implemented

1. **Client Validation**
   - Code signature verification
   - Bundle ID and Team ID matching
   - Audit token validation

2. **Request Validation**
   - Typed enum-based API (no arbitrary commands)
   - Range checking for all numeric inputs
   - DNS name validation for domains
   - Path canonicalization for firewall rules

3. **Safe Execution**
   - Fixed binary paths (no shell injection)
   - Argument allowlists
   - Bounded output buffers
   - Timeout enforcement

4. **Lease Mechanism**
   - Automatic fan reset on app crash
   - Charge limit safety bounds
   - Emergency thermal override priority

5. **Atomic Operations**
   - Backup before /etc/hosts modification
   - Rollback on failure
   - No partial state corruption

## Migration Plan (Legacy Daemons)

Old daemons to migrate:
- `com.trykelvin.kelvin.powerd` → integrated into unified service
- `com.trykelvin.kelvin.fand` → integrated into unified service
- Legacy `com.local.batterymeter.*` → removed

Migration steps:
1. Detect old plist files in `/Library/LaunchDaemons`
2. Read compatible user settings
3. Set fans to auto, normalize charge policy
4. Stop and unload old jobs
5. Remove old binaries and plists
6. Install new unified service
7. Import valid configuration
8. Verify health
9. Write migration marker

## Next Steps (Stages 9-12)

### Stage 9: Uninstall UX
- [ ] Add "Remove System Component" button to UI
- [ ] Implement full rollback sequence
- [ ] Update `uninstall-app.sh` to use official uninstaller

### Stage 10: Logging & Diagnostics
- [ ] Unified logging with categories
- [ ] Diagnostic report generator (user-readable)
- [ ] Privacy-safe error reporting

### Stage 11: Testing
- [ ] Unit tests for validation logic
- [ ] XPC security tests (spoofing, malformed payloads)
- [ ] Integration tests (install/update/uninstall)
- [ ] Hardware QA (M1 Air, Apple Silicon w/fans, Intel single/dual GPU)

### Stage 12: Staged Rollout
1. Service skeleton + status (no mutations)
2. Power metrics migration
3. GPU switching migration
4. Fan/charge with hardware QA
5. Firewall and host blocklist
6. Legacy daemon migration
7. Remove old osascript paths

## Known Issues

1. **macOS 11-12 Support**: Requires legacy blessed-helper path or raised minimum version
2. **SMC Integration**: Real SMC key access needs kernel extension or private framework
3. **Code Signing**: Service must be signed with same Team ID as app
4. **Installation Path**: Must be installed from /Applications, not Downloads

## Definition of Done Checklist

- [x] Single installation approval (no repeated passwords)
- [x] No universal root shell API
- [x] Client signature validation
- [x] Version handshake between app and service
- [x] Lease and watchdog for fan/charge
- [x] UI controls for install/repair/update/uninstall
- [ ] Legacy daemon migration (idempotent)
- [ ] Human-readable diagnostics
- [ ] macOS 11-12 fallback strategy documented
- [ ] Security tests passed
- [ ] Hardware QA completed
