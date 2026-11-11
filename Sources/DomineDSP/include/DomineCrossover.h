#ifndef DOMINE_CROSSOVER_H
#define DOMINE_CROSSOVER_H

// Per-speaker role and crossover, one mono stream (contract in
// DomineEffects.h). A speaker is full range (no filter), a satellite
// (high-pass at the crossover) or a subwoofer (low-pass at the crossover).
// The filters are 4th-order Linkwitz-Riley (LR4, 24 dB/oct): two cascaded
// 2nd-order Butterworth biquads (RBJ cookbook, Q = 1/sqrt(2)) at the same
// frequency. LR4 low-pass plus LR4 high-pass sums to an allpass, so a
// satellite and a subwoofer together are flat in magnitude.
//
// The kernels run it after the effects chain and before trim gain and delay.
// Feeding a subwoofer the mono sum, and leaving it out of panning, is the
// kernel's job (DomineDSP.h, DomineSurround.h), not this module's.
//
// Full range settles to idle and leaves samples untouched bit for bit. Role
// changes crossfade between the dry, high-passed and low-passed signals over
// 10 ms (DOMINE_CROSSOVER_SMOOTH_MS); frequency changes slide the
// coefficients over the same time.

#include "DomineEffects.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

typedef enum {
    DOMINE_ROLE_FULL_RANGE = 0,
    DOMINE_ROLE_SATELLITE = 1,
    DOMINE_ROLE_SUBWOOFER = 2
} DomineSpeakerRole;

#define DOMINE_CROSSOVER_MIN_HZ 40.0
#define DOMINE_CROSSOVER_MAX_HZ 200.0
#define DOMINE_CROSSOVER_DEFAULT_HZ 80.0
#define DOMINE_CROSSOVER_SMOOTH_MS 10.0

typedef struct DomineCrossoverParams {
    int role;      // a DomineSpeakerRole; anything else is full range
    float freqHz;  // clamped to [MIN_HZ, MAX_HZ] (and below 0.45 * sampleRate); NaN is the default
} DomineCrossoverParams;

typedef struct DomineCrossover DomineCrossover;

/// Defaults: full range, 80 Hz.
DomineCrossoverParams domine_crossover_default_params(void);

DomineCrossover *_Nullable domine_crossover_create(double sampleRate);
void domine_crossover_destroy(DomineCrossover *_Nullable xo);
void domine_crossover_set_params(DomineCrossover *xo, const DomineCrossoverParams *p);
void domine_crossover_process(DomineCrossover *xo, float *samples, uint32_t frames);
int domine_crossover_is_idle(const DomineCrossover *xo);

/// Normalized coefficients of one Butterworth section of the LR4 filter
/// (the filter is this section twice), after clamping freqHz. highpass
/// nonzero gives the high-pass. out points to 5 doubles = {b0, b1, b2, a1, a2}.
void domine_crossover_coefficients(int highpass, double sampleRate, double freqHz, double *out);

#pragma clang assume_nonnull end
#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
