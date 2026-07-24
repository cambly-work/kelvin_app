import Foundation

// Юнит-тест чистой логики форматирования скорости (NetUsage.fmtRate) — компилируется
// вместе с настоящим Sources/NetUsage.swift, т.е. проверяет реальный код, не копию.
var fails = 0
func expect(_ got: String, _ want: String, _ name: String) {
    if got != want { FileHandle.standardError.write(Data("  FAIL \(name): got «\(got)» want «\(want)»\n".utf8)); fails += 1 }
}

expect(NetUsage.fmtRate(0),          "0",    "zero")
expect(NetUsage.fmtRate(512),        "512",  "bytes")
expect(NetUsage.fmtRate(999),        "999",  "sub-kilo")
expect(NetUsage.fmtRate(1_000),      "1K",   "exactly-1k")
expect(NetUsage.fmtRate(23_000),     "23K",  "tens-of-k")
expect(NetUsage.fmtRate(1_500_000),  "1.5M", "mega-fraction")
expect(NetUsage.fmtRate(2_000_000),  "2.0M", "mega-round")

if fails > 0 { print("fmtRate: \(fails) проверок упало"); exit(1) }
print("  ✓ NetUsage.fmtRate (7 проверок)")
