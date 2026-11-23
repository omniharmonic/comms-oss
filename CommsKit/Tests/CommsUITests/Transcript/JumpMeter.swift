import Foundation

/// Measures unexplained on-screen movement of rows between samples (ported from the Phase 0
/// spike, spikes/TranscriptSpike/Shared/JumpMeter.swift).
///
/// `scrollDelta` is the scroll offset change between samples; a row's screen y is expected to
/// move by -scrollDelta, anything else is a jump. An anchor row is tracked by LAYOUT position
/// even when it is off-screen after an insert, so a prepend that pushes every previously
/// visible row away still registers (no blind spot). A run is INVALID if any insert tick
/// compared zero rows.
struct JumpMeter {
    private var prev: [String: Double] = [:]
    private var anchorID: String?
    private var prevAnchorY: Double?
    private(set) var maxJump = 0.0
    private(set) var maxJumpAtInsert = 0.0
    private(set) var samples = 0
    private(set) var insertSamples = 0
    private(set) var jumpsOver1pt = 0
    private(set) var minComparedAtInsert = Int.max

    /// `visible`: id → screen y of rows currently visible. `anchorPosition`: layout screen y
    /// for any row id (even off-screen).
    mutating func sample(_ visible: [String: Double], anchorPosition: (String) -> Double?, scrollDelta: Double, insertedThisTick: Bool) {
        if prev.isEmpty {
            anchorID = visible.min { $0.value < $1.value }?.key
            prevAnchorY = anchorID.flatMap { visible[$0] }
            prev = visible
            return
        }
        var tickMax = 0.0
        var compared = 0
        for (id, y) in visible {
            if let p = prev[id] {
                compared += 1
                tickMax = max(tickMax, abs(y - (p - scrollDelta)))
            }
        }
        if let a = anchorID, let pa = prevAnchorY, visible[a] == nil, let ya = anchorPosition(a) {
            compared += 1
            tickMax = max(tickMax, abs(ya - (pa - scrollDelta)))
        }
        maxJump = max(maxJump, tickMax)
        if insertedThisTick {
            maxJumpAtInsert = max(maxJumpAtInsert, tickMax)
            insertSamples += 1
            minComparedAtInsert = min(minComparedAtInsert, compared)
        }
        if tickMax > 1 { jumpsOver1pt += 1 }
        if anchorID == nil || visible[anchorID!] == nil {
            anchorID = visible.min { $0.value < $1.value }?.key
        }
        prevAnchorY = anchorID.flatMap { visible[$0] }
        prev = visible
        samples += 1
    }

    var valid: Bool { insertSamples == 0 || minComparedAtInsert > 0 }

    func summary(inserts: Int) -> String {
        String(format: "inserts=%d samples=%d insertTicks=%d minRowsComparedAtInsert=%d maxJump=%.3f maxJumpAtInsert=%.3f ticksOver1pt=%d %@",
               inserts, samples, insertSamples, insertSamples == 0 ? -1 : minComparedAtInsert,
               maxJump, maxJumpAtInsert, jumpsOver1pt, valid ? "valid" : "INVALID")
    }
}
