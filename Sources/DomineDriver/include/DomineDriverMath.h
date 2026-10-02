#ifndef DOMINE_DRIVER_MATH_H
#define DOMINE_DRIVER_MATH_H

/*
 * Pure helpers for the Domine virtual output driver (SPEC section 3.3).
 * No Core Audio calls, no allocation, no state: safe on any thread and
 * unit tested from DomineDriverTests.
 */

#include <stdint.h>

/** Lower end of the volume control's dB range. */
#define DOMINE_DRIVER_MIN_DB (-64.0f)
/** Upper end of the volume control's dB range. */
#define DOMINE_DRIVER_MAX_DB (0.0f)

/**
 * Clamps a volume scalar to 0...1. NaN becomes 0.
 * @param scalar Any value.
 * @return The clamped scalar.
 */
float domine_driver_clamp_scalar(float scalar);

/**
 * Volume taper: linear in dB, so each step of the scalar is the same
 * loudness change. 0 maps to DOMINE_DRIVER_MIN_DB and 1 to DOMINE_DRIVER_MAX_DB.
 * @param scalar Volume scalar; clamped to 0...1.
 * @return Gain in dB.
 */
float domine_driver_scalar_to_db(float scalar);

/**
 * Inverse of domine_driver_scalar_to_db.
 * @param db Gain in dB; clamped to the control's range. NaN maps to the minimum.
 * @return Volume scalar in 0...1.
 */
float domine_driver_db_to_scalar(float db);

/**
 * Clamps a dB value to the control's range. NaN becomes the minimum.
 * @param db Any value.
 * @return The clamped dB value.
 */
float domine_driver_clamp_db(float db);

/**
 * Host clock ticks per audio frame.
 * @param sample_rate Nominal sample rate in Hz; must be positive.
 * @param timebase_numer mach_timebase_info numer (ticks to ns).
 * @param timebase_denom mach_timebase_info denom.
 * @return Ticks per frame, or 0 for invalid input.
 */
double domine_driver_ticks_per_frame(double sample_rate, uint32_t timebase_numer, uint32_t timebase_denom);

/** Result of domine_driver_zero_timestamp. */
typedef struct DomineZeroTimestamp {
    /** Updated count of whole zero-timestamp periods since the anchor. */
    uint64_t period_count;
    /** Sample time of the most recent zero timestamp. */
    double sample_time;
    /** Host time of the most recent zero timestamp. */
    uint64_t host_time;
} DomineZeroTimestamp;

/**
 * Zero-timestamp math from Apple's NullAudio sample: the device's clock
 * ticks once every `period_frames` frames, starting at `anchor_host_time`.
 * If the next period's host time has passed, the count advances by one
 * (at most one per call, as in the sample; the HAL calls often enough).
 * @param anchor_host_time mach_absolute_time when IO started.
 * @param ticks_per_frame From domine_driver_ticks_per_frame.
 * @param period_frames Zero-timestamp period in frames.
 * @param period_count Periods counted so far.
 * @param now_host_time Current mach_absolute_time.
 * @return The new count and the timestamp to report.
 */
DomineZeroTimestamp domine_driver_zero_timestamp(uint64_t anchor_host_time,
                                                 double ticks_per_frame,
                                                 uint32_t period_frames,
                                                 uint64_t period_count,
                                                 uint64_t now_host_time);

/**
 * Whether the driver offers a sample rate (44100 or 48000 Hz).
 * @param sample_rate Rate in Hz.
 * @return 1 if supported, else 0.
 */
int domine_driver_is_supported_rate(double sample_rate);

#endif
