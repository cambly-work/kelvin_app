import Foundation

private var failures = 0

private func expect(_ actual: String, _ expected: String, _ name: String) {
    if actual == expected {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name): expected \(expected), got \(actual)")
    }
}

expect(
    AppEnergyFormatting.memory(
        megabytes: 512,
        megabytesFormat: "%.0f MB",
        gigabytesFormat: "%.1f GB"
    ),
    "512 MB",
    "memory below one GiB"
)
expect(
    AppEnergyFormatting.memory(
        megabytes: 1536,
        megabytesFormat: "%.0f MB",
        gigabytesFormat: "%.1f GB"
    ),
    "1.5 GB",
    "memory above one GiB"
)
expect(
    AppEnergyFormatting.memory(
        megabytes: .nan,
        megabytesFormat: "%.0f MB",
        gigabytesFormat: "%.1f GB"
    ),
    "—",
    "invalid memory"
)
expect(AppEnergyFormatting.impact(12.34), "12.3", "impact precision")
expect(AppEnergyFormatting.impact(.infinity), "—", "invalid impact")
expect(AppEnergyFormatting.cpu(128.6), "129%", "multi-core CPU")
expect(AppEnergyFormatting.cpu(.nan), "—", "invalid CPU")

if failures > 0 {
    print("✗ AppEnergyFormatting: \(failures) failures")
    exit(1)
}
print("✓ AppEnergyFormatting (7 checks)")
