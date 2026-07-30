import Foundation

private var failures = 0

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    if actual == expected {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name): expected \(expected), got \(actual)")
    }
}

private let alpha = AppEnergy(name: "Alpha", impact: 4, cpu: 20)
private let beta = AppEnergy(name: "Beta", impact: 8, cpu: 10)
private let gamma = AppEnergy(name: "Gamma", impact: 2, cpu: nil)
private let network: AppEnergyPresentation.NetworkCount = {
    ["Alpha": 1, "Beta": 3][$0.name] ?? 0
}

expect(
    AppEnergyPresentation.sorted([alpha, beta, gamma], by: .impact, networkCount: network).map(\.name),
    ["Beta", "Alpha", "Gamma"],
    "impact sort"
)
expect(
    AppEnergyPresentation.sorted([alpha, beta, gamma], by: .cpu, networkCount: network).map(\.name),
    ["Alpha", "Beta", "Gamma"],
    "CPU sort"
)
expect(
    AppEnergyPresentation.sorted([alpha, beta, gamma], by: .net, networkCount: network).map(\.name),
    ["Beta", "Alpha", "Gamma"],
    "network sort"
)
expect(
    AppEnergyPresentation.valueText(for: gamma, sort: .cpu, networkCount: network),
    "—",
    "missing CPU text"
)
expect(
    AppEnergyPresentation.valueText(for: beta, sort: .net, networkCount: network),
    "3",
    "network value text"
)
expect(
    AppEnergyPresentation.metric(
        for: AppEnergy(name: "Invalid", impact: .nan, cpu: -.infinity),
        sort: .cpu,
        networkCount: { _ in -2 }
    ),
    0,
    "invalid metric is clamped"
)

private let tied = [
    AppEnergy(name: "Zulu", impact: 1),
    AppEnergy(name: "Alpha", impact: 1)
]
expect(
    AppEnergyPresentation.sorted(tied, by: .impact, networkCount: { _ in 0 }).map(\.name),
    ["Alpha", "Zulu"],
    "deterministic tie-break"
)

if failures > 0 {
    print("✗ AppEnergyPresentation: \(failures) failures")
    exit(1)
}
print("✓ AppEnergyPresentation (7 checks)")
