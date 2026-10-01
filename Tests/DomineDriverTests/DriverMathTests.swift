import DomineDriverMath
import Testing

/// Pure helpers behind the virtual output driver: volume taper, clamping,
/// host clock math, and the zero-timestamp clock.
struct DriverMathTests {
    @Test func scalarEndsMapToTheDecibelRange() {
        #expect(domine_driver_scalar_to_db(0) == -64)
        #expect(domine_driver_scalar_to_db(1) == 0)
        #expect(domine_driver_scalar_to_db(0.5) == -32)
        #expect(domine_driver_scalar_to_db(0.75) == -16)
    }

    @Test func decibelsMapBackToScalar() {
        #expect(domine_driver_db_to_scalar(-64) == 0)
        #expect(domine_driver_db_to_scalar(0) == 1)
        #expect(domine_driver_db_to_scalar(-32) == 0.5)
        #expect(domine_driver_db_to_scalar(-48) == 0.25)
    }

    @Test func roundTripsEverySixteenthStep() {
        for step in 0...16 {
            let scalar = Float(step) / 16
            #expect(domine_driver_db_to_scalar(domine_driver_scalar_to_db(scalar)) == scalar)
        }
    }

    @Test func clampsOutOfRangeAndNaN() {
        #expect(domine_driver_clamp_scalar(-0.5) == 0)
        #expect(domine_driver_clamp_scalar(1.5) == 1)
        #expect(domine_driver_clamp_scalar(.nan) == 0)
        #expect(domine_driver_scalar_to_db(2) == 0)
        #expect(domine_driver_db_to_scalar(-100) == 0)
        #expect(domine_driver_db_to_scalar(6) == 1)
        #expect(domine_driver_db_to_scalar(.nan) == 0)
        #expect(domine_driver_clamp_db(.nan) == -64)
    }

    @Test func ticksPerFrame() {
        // Intel timebase: 1 tick = 1 ns.
        #expect(domine_driver_ticks_per_frame(48000, 1, 1) == 1e9 / 48000)
        // Apple silicon timebase 125/3: 24 MHz ticks.
        #expect(domine_driver_ticks_per_frame(48000, 125, 3) == 500)
        #expect(domine_driver_ticks_per_frame(44100, 125, 3) == 24e6 / 44100)
        #expect(domine_driver_ticks_per_frame(0, 1, 1) == 0)
        #expect(domine_driver_ticks_per_frame(48000, 0, 1) == 0)
        #expect(domine_driver_ticks_per_frame(48000, 1, 0) == 0)
    }

    @Test func zeroTimestampHoldsUntilAPeriodPasses() {
        // 500 ticks per frame, 100-frame periods: one period is 50_000 ticks.
        let ts = domine_driver_zero_timestamp(1_000, 500, 100, 0, 1_000 + 49_999)
        #expect(ts.period_count == 0)
        #expect(ts.sample_time == 0)
        #expect(ts.host_time == 1_000)
    }

    @Test func zeroTimestampAdvancesOnThePeriodBoundary() {
        let ts = domine_driver_zero_timestamp(1_000, 500, 100, 0, 1_000 + 50_000)
        #expect(ts.period_count == 1)
        #expect(ts.sample_time == 100)
        #expect(ts.host_time == 51_000)
    }

    @Test func zeroTimestampAdvancesOnePeriodPerCall() {
        // Far behind: catches up one period at a time, as in Apple's sample.
        let first = domine_driver_zero_timestamp(0, 500, 100, 3, 10_000_000)
        #expect(first.period_count == 4)
        #expect(first.sample_time == 400)
        #expect(first.host_time == 200_000)
    }

    @Test func zeroTimestampAt44100OnAppleSilicon() {
        let ticks = domine_driver_ticks_per_frame(44100, 125, 3)
        let period = UInt32(16384)
        let ticksPerPeriod = UInt64(ticks * Double(period))
        let ts = domine_driver_zero_timestamp(0, ticks, period, 0, ticksPerPeriod + 1)
        #expect(ts.period_count == 1)
        #expect(ts.sample_time == 16384)
        #expect(ts.host_time == ticksPerPeriod)
    }

    @Test func supportedRates() {
        #expect(domine_driver_is_supported_rate(44100) == 1)
        #expect(domine_driver_is_supported_rate(48000) == 1)
        #expect(domine_driver_is_supported_rate(96000) == 0)
        #expect(domine_driver_is_supported_rate(0) == 0)
    }
}
