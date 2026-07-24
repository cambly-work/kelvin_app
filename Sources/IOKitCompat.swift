import Foundation
import IOKit

/// Unified IOKit master port that works on both Big Sur (kIOMasterPortDefault)
/// and Monterey+ (kIOMainPortDefault). Use this everywhere instead of calling
/// kIOMainPortDefault directly.
func ioPort() -> mach_port_t {
    if #available(macOS 12, *) {
        return kIOMainPortDefault
    } else {
        return kIOMasterPortDefault
    }
}
