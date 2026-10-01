#include "include/DomineDriverMath.h"

#include <math.h>

float domine_driver_clamp_scalar(float scalar) {
    if (!(scalar > 0.0f)) return 0.0f; /* also catches NaN */
    if (scalar > 1.0f) return 1.0f;
    return scalar;
}

float domine_driver_clamp_db(float db) {
    if (!(db > DOMINE_DRIVER_MIN_DB)) return DOMINE_DRIVER_MIN_DB; /* also catches NaN */
    if (db > DOMINE_DRIVER_MAX_DB) return DOMINE_DRIVER_MAX_DB;
    return db;
}

float domine_driver_scalar_to_db(float scalar) {
    float s = domine_driver_clamp_scalar(scalar);
    return DOMINE_DRIVER_MIN_DB + s * (DOMINE_DRIVER_MAX_DB - DOMINE_DRIVER_MIN_DB);
}

float domine_driver_db_to_scalar(float db) {
    float d = domine_driver_clamp_db(db);
    return (d - DOMINE_DRIVER_MIN_DB) / (DOMINE_DRIVER_MAX_DB - DOMINE_DRIVER_MIN_DB);
}

double domine_driver_ticks_per_frame(double sample_rate, uint32_t timebase_numer, uint32_t timebase_denom) {
    if (!(sample_rate > 0.0) || timebase_numer == 0 || timebase_denom == 0) return 0.0;
    double ticks_per_second = 1.0e9 * (double)timebase_denom / (double)timebase_numer;
    return ticks_per_second / sample_rate;
}

DomineZeroTimestamp domine_driver_zero_timestamp(uint64_t anchor_host_time,
                                                 double ticks_per_frame,
                                                 uint32_t period_frames,
                                                 uint64_t period_count,
                                                 uint64_t now_host_time) {
    double ticks_per_period = ticks_per_frame * (double)period_frames;
    uint64_t next_host_time = anchor_host_time + (uint64_t)((double)(period_count + 1) * ticks_per_period);
    if (next_host_time <= now_host_time) period_count += 1;

    DomineZeroTimestamp result;
    result.period_count = period_count;
    result.sample_time = (double)period_count * (double)period_frames;
    result.host_time = anchor_host_time + (uint64_t)((double)period_count * ticks_per_period);
    return result;
}

int domine_driver_is_supported_rate(double sample_rate) {
    return sample_rate == 44100.0 || sample_rate == 48000.0;
}
