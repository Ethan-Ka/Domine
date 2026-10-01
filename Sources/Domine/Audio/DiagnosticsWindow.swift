import DomineDSP

/// Rates and counts over one diagnostics window, from two kernel stats
/// snapshots. Pure arithmetic so it can be tested with exact values.
struct DiagnosticsWindow: Equatable, Sendable {
    /// Seconds between the two snapshots' last cycles (nowHostTime), or nil.
    var seconds: Double?
    var cycles: UInt64
    var frames: UInt64
    var inputFrames: UInt64
    var cyclesPerSecond: Double?
    var framesPerSecond: Double?
    var inputFramesPerSecond: Double?
    /// Output sample time advance over output host time advance: the rate
    /// the aggregate's clock really runs at.
    var effectiveSampleRate: Double?
    /// Input sample time advance over input host time advance.
    var effectiveInputSampleRate: Double?
    var underrunFrames: UInt64
    var overflowFrames: UInt64
    var missingCycles: UInt64
    var shortCycles: UInt64
    var longCycles: UInt64
    var silentCycles: UInt64
    var sampleTimeJumps: UInt64
    var formatMismatchCycles: UInt64
    /// Output sample time minus input sample time at the last cycle, frames.
    var ioGapFrames: Double?
    /// How far ahead of "now" the output is scheduled, ms.
    var outputLeadMs: Double?
    /// How far behind "now" the input was captured, ms.
    var inputLagMs: Double?
    var maxCycleIntervalMs: Double?

    /// `secondsPerTick` converts host ticks (mach_absolute_time) to seconds.
    static func compute(previous p: DomineKernelStats, current c: DomineKernelStats, secondsPerTick: Double) -> DiagnosticsWindow {
        func delta(_ a: UInt64, _ b: UInt64) -> UInt64 { b >= a ? b - a : 0 }
        func valid(_ s: DomineKernelStats, _ flag: Int32) -> Bool { s.timeFlags & UInt32(flag) != 0 }
        func span(_ a: UInt64, _ b: UInt64) -> Double? {
            guard a != 0, b > a else { return nil }
            return Double(b - a) * secondsPerTick
        }

        var w = DiagnosticsWindow(
            cycles: delta(p.cycles, c.cycles),
            frames: delta(p.frames, c.frames),
            inputFrames: delta(p.inputFrames, c.inputFrames),
            underrunFrames: delta(p.underrunFrames, c.underrunFrames),
            overflowFrames: delta(p.overflowFrames, c.overflowFrames),
            missingCycles: delta(p.inputMissingCycles, c.inputMissingCycles),
            shortCycles: delta(p.inputShortCycles, c.inputShortCycles),
            longCycles: delta(p.inputLongCycles, c.inputLongCycles),
            silentCycles: delta(p.inputSilentCycles, c.inputSilentCycles),
            sampleTimeJumps: delta(p.sampleTimeJumps, c.sampleTimeJumps),
            formatMismatchCycles: delta(p.formatMismatchCycles, c.formatMismatchCycles))

        if valid(p, DOMINE_STATS_NOW_HOST_VALID), valid(c, DOMINE_STATS_NOW_HOST_VALID),
           let seconds = span(p.nowHostTime, c.nowHostTime) {
            w.seconds = seconds
            w.cyclesPerSecond = Double(w.cycles) / seconds
            w.framesPerSecond = Double(w.frames) / seconds
            w.inputFramesPerSecond = Double(w.inputFrames) / seconds
        }
        if valid(p, DOMINE_STATS_OUTPUT_HOST_VALID), valid(c, DOMINE_STATS_OUTPUT_HOST_VALID),
           valid(p, DOMINE_STATS_OUTPUT_SAMPLE_VALID), valid(c, DOMINE_STATS_OUTPUT_SAMPLE_VALID),
           let seconds = span(p.outputHostTime, c.outputHostTime) {
            w.effectiveSampleRate = (c.outputSampleTime - p.outputSampleTime) / seconds
        }
        if valid(p, DOMINE_STATS_INPUT_HOST_VALID), valid(c, DOMINE_STATS_INPUT_HOST_VALID),
           valid(p, DOMINE_STATS_INPUT_SAMPLE_VALID), valid(c, DOMINE_STATS_INPUT_SAMPLE_VALID),
           let seconds = span(p.inputHostTime, c.inputHostTime) {
            w.effectiveInputSampleRate = (c.inputSampleTime - p.inputSampleTime) / seconds
        }
        if valid(c, DOMINE_STATS_INPUT_SAMPLE_VALID), valid(c, DOMINE_STATS_OUTPUT_SAMPLE_VALID) {
            w.ioGapFrames = c.outputSampleTime - c.inputSampleTime
        }
        if valid(c, DOMINE_STATS_NOW_HOST_VALID), valid(c, DOMINE_STATS_OUTPUT_HOST_VALID) {
            w.outputLeadMs = (Double(c.outputHostTime) - Double(c.nowHostTime)) * secondsPerTick * 1000
        }
        if valid(c, DOMINE_STATS_NOW_HOST_VALID), valid(c, DOMINE_STATS_INPUT_HOST_VALID) {
            w.inputLagMs = (Double(c.nowHostTime) - Double(c.inputHostTime)) * secondsPerTick * 1000
        }
        if c.maxCycleInterval > 0 {
            w.maxCycleIntervalMs = Double(c.maxCycleInterval) * secondsPerTick * 1000
        }
        return w
    }
}
