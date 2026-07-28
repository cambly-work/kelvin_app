import Foundation

// MARK: - Lightweight test harness (no XCTest)

private var failures = 0
private var passed = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        passed += 1
    } else {
        print("  ✗ \(message)")
        failures += 1
    }
}

// MARK: - CorrectionStateMachine: extractable state logic from LangSwitcher

/// Mirrors the correction state management in LangSwitcher without
/// CGEventTap, NSSpellChecker, or AppKit. Safe to test in isolation.
struct CorrectionStateMachine {
    var pending: PendingCorrection?
    var typedAfter: Bool = true   // analogous to userTypedSinceConversion for spell

    // MARK: - Operations

    /// Records a new spell correction. Returns the ID that should be
    /// passed to subsequent undo/accept calls.
    mutating func applyCorrection(original: String, corrected: String, bundleID: String? = nil) -> UUID {
        let id = UUID()
        pending = PendingCorrection(
            id: id,
            original: original,
            corrected: corrected,
            bundleID: bundleID,
            createdAt: Date(),
            status: .pending
        )
        typedAfter = false
        return id
    }

    /// Attempts to undo a correction identified by `id`. Returns the original
    /// text if undo succeeded, nil otherwise (wrong ID, already undone, etc.).
    mutating func undo(id: UUID) -> String? {
        guard let p = pending, p.id == id, p.isActive, !typedAfter else { return nil }
        let original = p.original
        pending?.status = .restored
        typedAfter = true
        return original
    }

    /// Accepts a correction identified by `id`. Returns true if accepted.
    mutating func accept(id: UUID) -> Bool {
        guard let p = pending, p.id == id, p.isActive else { return false }
        pending?.status = .accepted
        return true
    }

    /// Simulates continued typing after a correction — should block undo.
    mutating func recordTyping() {
        typedAfter = true
        if pending?.isActive == true {
            pending?.status = .invalidated
        }
    }

    /// Explicitly invalidates the current correction (e.g. app switch, caret move).
    mutating func invalidate() {
        if pending?.isActive == true {
            pending?.status = .invalidated
        }
    }

    /// Applies a new correction, implicitly invalidating any older one.
    mutating func newCorrectionInvalidatesOld(original: String, corrected: String, bundleID: String? = nil) -> UUID {
        if pending?.isActive == true {
            pending?.status = .invalidated
        }
        return applyCorrection(original: original, corrected: corrected, bundleID: bundleID)
    }

    /// Simulates timer-based dismissal — equivalent to accept.
    mutating func timerDismiss() {
        if pending?.isActive == true {
            pending?.status = .accepted
        }
    }
}

// MARK: - Tests

var sm = CorrectionStateMachine()

// 1. Correction → undo → original word restored
sm = CorrectionStateMachine()
let id1 = sm.applyCorrection(original: "teh ", corrected: "the ")
let undo1 = sm.undo(id: id1)
expect(undo1 == "teh " && !sm.pending!.isActive,
       "1. undo restores original text (pre-correction) and marks restored")
expect(sm.typedAfter == true,
       "1. typedAfter is true after undo")

// 2. Correction → accept → undo impossible
sm = CorrectionStateMachine()
let id2 = sm.applyCorrection(original: "teh ", corrected: "the ")
let accepted = sm.accept(id: id2)
expect(accepted == true,
       "2. accept returns true")
let undo2 = sm.undo(id: id2)
expect(undo2 == nil,
       "2. undo after accept returns nil")

// 3. Correction → typing → old undo rejected
sm = CorrectionStateMachine()
let id3 = sm.applyCorrection(original: "teh ", corrected: "the ")
sm.recordTyping()
let undo3 = sm.undo(id: id3)
expect(undo3 == nil,
       "3. undo after typing returns nil")
expect(sm.pending?.status == .invalidated,
       "3. pending status is invalidated after typing")

// 4. Correction A → correction B → HUD A cannot undo B
sm = CorrectionStateMachine()
let id4a = sm.applyCorrection(original: "teh ", corrected: "the ")
let id4b = sm.newCorrectionInvalidatesOld(original: "wrogn ", corrected: "wrong ")
let undo4a = sm.undo(id: id4a)
let undo4b = sm.undo(id: id4b)
expect(undo4a == nil,
       "4. undo old correction A returns nil")
expect(undo4b == "wrogn ",
       "4. undo new correction B returns original")

// 5. Click on «Вернуть» does not invalidate before checking
//    (mouse-down calls resetBufferOnly which does NOT touch pendingCorrection)
sm = CorrectionStateMachine()
let id5 = sm.applyCorrection(original: "teh ", corrected: "the ")
// Simulate: resetTypingState(keepingLastConversion: true) — does NOT invalidate
// This is the key fix: mouse click no longer clears pendingCorrection
let undo5 = sm.undo(id: id5)
expect(undo5 == "teh ",
       "5. undo after mouse-click resetBufferOnly still works")

// 6. Click outside HUD — typedAfter becomes true via resetTypingState
//    In our model: mouse click sets typedAfter=true but does NOT invalidate pendingCorrection
//    However, continued typing would block undo
sm = CorrectionStateMachine()
let id6 = sm.applyCorrection(original: "teh ", corrected: "the ")
// Simulate click outside: typedAfter = true (from resetTypingState keeping lastConversion)
sm.typedAfter = true  // resetTypingState sets this even when keepingLastConversion
let undo6 = sm.undo(id: id6)
expect(undo6 == nil,
       "6. undo after click outside (typedAfter=true) returns nil")

// 7. App switch invalidates correction
sm = CorrectionStateMachine()
let id7 = sm.applyCorrection(original: "teh ", corrected: "the ")
sm.invalidate()
let undo7 = sm.undo(id: id7)
expect(undo7 == nil,
       "7. undo after app switch (invalidate) returns nil")
expect(sm.pending?.status == .invalidated,
       "7. pending status is invalidated after app switch")

// 8. Timer safely accepts correction
sm = CorrectionStateMachine()
let id8 = sm.applyCorrection(original: "teh ", corrected: "the ")
sm.timerDismiss()
let undo8 = sm.undo(id: id8)
expect(undo8 == nil,
       "8. undo after timer dismiss returns nil")
expect(sm.pending?.status == .accepted,
       "8. pending status is accepted after timer")

// 9. Long words don't break layout
sm = CorrectionStateMachine()
let longOrig = String(repeating: "a", count: 60) + " "
let longCorr = String(repeating: "b", count: 60) + " "
let id9 = sm.applyCorrection(original: longOrig, corrected: longCorr)
expect(sm.pending?.original == longOrig,
       "9. long original word stored correctly")
expect(sm.pending?.corrected == longCorr,
       "9. long corrected word stored correctly")
let undo9 = sm.undo(id: id9)
expect(undo9 == longOrig,
       "9. long word undo returns full original")

// 10. Double undo is safe (no double text replacement)
sm = CorrectionStateMachine()
let id10 = sm.applyCorrection(original: "teh ", corrected: "the ")
let _ = sm.undo(id: id10)
let undo10b = sm.undo(id: id10)
expect(undo10b == nil,
       "10. second undo returns nil (no double replacement)")

// 11. Accept with wrong ID is safe
sm = CorrectionStateMachine()
let id11 = sm.applyCorrection(original: "teh ", corrected: "the ")
let accept11 = sm.accept(id: UUID())
expect(accept11 == false,
       "11. accept with wrong ID returns false")
let undo11 = sm.undo(id: id11)
expect(undo11 == "teh ",
       "11. undo with correct ID still works after wrong-ID accept")

// 12. Unicode words work
sm = CorrectionStateMachine()
let id12 = sm.applyCorrection(original: "превед ", corrected: "привет ")
let undo12 = sm.undo(id: id12)
expect(undo12 == "превед ",
       "12. Unicode word undo returns pre-correction original")

// MARK: - Results

if failures > 0 {
    print("✗ PendingCorrection state machine: \(failures) failures out of \(passed + failures) checks")
    exit(1)
}
print("  ✓ PendingCorrection state machine (\(passed) checks)")
