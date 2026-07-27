# Privileged Service Installation Guide

## Overview

Kelvin now uses a unified privileged service architecture to perform system-level operations safely. This guide explains the installation process, security model, and troubleshooting steps.

## Architecture

```
Kelvin.app (User Space)
    ↓ XPC (Mach Services)
KelvinPrivilegedService (Root, LaunchDaemon)
    ├── FanChargeService
    ├── PowerMetricsService  
    ├── GPUModeService
    ├── FirewallService
    └── HostBlockService
```

## Security Model

### Client Validation
The privileged service validates every connecting client:
- **Code Signature**: Must be signed with Kelvin's Team ID
- **Bundle Identifier**: Must match `com.trykelvin.kelvin`
- **Audit Token**: Verified against running process

### Request Validation
All requests are strongly typed:
- No arbitrary command execution
- Enum-based operations only
- Range validation for numeric parameters
- Path canonicalization and existence checks
- Domain name validation for host blocking

### Lease Mechanism
Fan and charge control use a lease system:
- App must renew lease every 30 seconds
- Automatic rollback to safe state on lease expiry
- Prevents orphaned manual control

## Installation Requirements

### System Requirements
- macOS 11.0 or later
- Admin user credentials (one-time approval)
- Application must be in `/Applications` folder
- Valid code signature

### File Locations
After installation:
- Launch Daemon Plist: `/Library/LaunchDaemons/com.trykelvin.kelvin.privileged.plist`
- Executable: `/Library/PrivilegedHelperTools/com.trykelvin.kelvin.privileged`
- Logs: `/var/log/com.trykelvin.kelvin.privileged.log`

## Installation Process

### Step 1: Pre-flight Check
Before requesting installation, the app verifies:
1. App is located in `/Applications`
2. App has valid code signature
3. User has admin privileges
4. No conflicting legacy daemons running

### Step 2: User Approval
macOS will present a system dialog:
```
"Kelvin" wants to install a privileged helper tool.
This requires administrator privileges.
```

**What this means:**
- One-time approval for the service
- Service runs as root
- Limited to predefined operations only

### Step 3: Service Registration
The system:
1. Copies executable to protected location
2. Installs launchd plist
3. Loads the daemon
4. Establishes XPC connection

### Step 4: Health Check
App verifies:
- Service responds to ping
- Protocol version matches
- All capabilities available
- No errors in initial state

## Post-Installation

### Normal Operation
After successful installation:
- ✅ No password prompts for routine operations
- ✅ Fan profiles apply instantly
- ✅ GPU switching works without AppleScript
- ✅ Firewall rules update silently
- ✅ Host blocklist changes atomically

### Status Indicators
The Settings panel shows:
- 🟢 **Healthy**: Service running normally
- 🟡 **Degraded**: Service available but some features limited
- 🔴 **Unavailable**: Service not responding
- ⚪ **Not Installed**: Needs installation

## Update Process

### Automatic Updates
When app updates:
1. Service checks protocol compatibility
2. If compatible: continues running
3. If incompatible: prompts for service update
4. Update preserves user settings

### Manual Update
If service becomes corrupted:
1. Go to Settings → System Functions
2. Click "Repair" or "Reinstall"
3. Re-authenticate if required

## Uninstallation

### Via UI (Recommended)
1. Settings → System Functions
2. Click "Uninstall System Component"
3. Service performs safe rollback:
   - Fans → Automatic
   - Charge limit → 80%
   - Firewall rules → preserved
   - Hosts file → Kelvin entries removed
4. Service unregisters from launchd
5. Files removed

### Manual Removal
If app is already deleted:
```bash
# Unload daemon
sudo launchctl bootout system/com.trykelvin.kelvin.privileged

# Remove files
sudo rm /Library/LaunchDaemons/com.trykelvin.kelvin.privileged.plist
sudo rm /Library/PrivilegedHelperTools/com.trykelvin.kelvin.privileged
sudo rm /var/log/com.trykelvin.kelvin.privileged.*
```

## Troubleshooting

### "Service Not Available"
**Causes:**
- Service failed to start
- XPC connection blocked
- Code signature invalid

**Solutions:**
1. Check Console.app for error logs
2. Verify app location is `/Applications/Kelvin.app`
3. Try "Repair" in settings
4. Reinstall application

### "Protocol Version Mismatch"
**Cause:** App and service versions incompatible

**Solution:**
- Update app to latest version
- Or reinstall service via settings

### "Client Validation Failed"
**Causes:**
- App modified after signing
- Running from Downloads folder
- Code signature expired

**Solutions:**
1. Move app to Applications
2. Re-download from official source
3. Check system date/time

### Legacy Daemon Conflicts
If old `fand` or `powerd` daemons exist:

**Symptoms:**
- Fan control not working
- Duplicate processes
- Conflicting settings

**Resolution:**
```bash
# Stop legacy daemons
sudo launchctl unload /Library/LaunchDaemons/com.trykelvin.kelvin.fand.plist
sudo launchctl unload /Library/LaunchDaemons/com.trykelvin.kelvin.powerd.plist

# Remove old files
sudo rm /Library/LaunchDaemons/com.trykelvin.kelvin.fand.plist
sudo rm /Library/LaunchDaemons/com.trykelvin.kelvin.powerd.plist
sudo rm /Library/PrivilegedHelperTools/fand
sudo rm /Library/PrivilegedHelperTools/powerd
```

Then reinstall Kelvin service via UI.

## Capabilities Reference

| Capability | Description | Requires Root | Rollback Support |
|------------|-------------|---------------|------------------|
| Fan Control | Manual fan speed profiles | Yes | Auto on lease expiry |
| Charge Limit | Battery charging threshold | Yes | Reset to 80% |
| Power Metrics | Real-time power consumption | Yes | N/A (read-only) |
| GPU Switching | Toggle GPU modes (Intel only) | Yes | Preserves last state |
| Firewall | App allow/block rules | Yes | Rules persist |
| Host Blocking | DNS-level domain blocking | Yes | Clean removal |

## Security Audit

### What the Service CAN Do:
- Execute specific system binaries with fixed arguments
- Modify /etc/hosts (Kelvin section only)
- Configure firewall via socketfilterfw
- Write to SMC registers (fan/charge)
- Read power metrics from powermetrics

### What the Service CANNOT Do:
- Execute arbitrary shell commands
- Access user files outside system paths
- Disable Gatekeeper or SIP
- Modify other applications
- Network communication (local XPC only)

## Migration from Legacy

If upgrading from older Kelvin versions:

1. **Automatic Detection**: App detects old daemons
2. **Safe State**: Fans set to automatic temporarily
3. **Backup**: Current settings backed up
4. **Removal**: Old daemons unloaded and deleted
5. **Installation**: New service installed
6. **Restore**: Compatible settings migrated
7. **Verification**: Health check confirms success

Migration is idempotent—safe to retry if interrupted.

## Support

For issues not covered here:
1. Generate diagnostic report from Settings
2. Check `/var/log/com.trykelvin.kelvin.privileged.log`
3. Contact support with logs attached

---

**Last Updated**: 2024
**Service Version**: 1.0.0
**Protocol Version**: 1
