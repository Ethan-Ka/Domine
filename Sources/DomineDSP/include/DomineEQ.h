#ifndef DOMINE_EQ_H
#define DOMINE_EQ_H

// Five-band parametric EQ, one mono stream (SPEC section 5a, contract in
// DomineEffects.h). Bands: 0 low shelf, 1 to 3 peaking, 4 high shelf. RBJ
// cookbook biquads, double precision state, float samples.

#include "DomineEffects.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

#define DOMINE_EQ_BANDS 5
#define DOMINE_EQ_MAX_GAIN_DB 12.0
#define DOMINE_EQ_SMOOTH_MS 10.0

typedef enum { DOMINE_EQ_LOW_SHELF = 0, DOMINE_EQ_PEAKING = 1, DOMINE_EQ_HIGH_SHELF = 2 } DomineEQBandType;

typedef struct DomineEQBand {
    float freqHz;  // clamped to [20, 0.45 * sampleRate]
    float gainDb;  // clamped to +-12; exactly 0 makes the band a no-op
    float q;       // clamped to [0.1, 10]
} DomineEQBand;

typedef struct DomineEQParams {
    int enabled;   // 0 fades every band to a no-op
    DomineEQBand bands[DOMINE_EQ_BANDS];
} DomineEQParams;

typedef struct DomineEQ DomineEQ;

/// Defaults: disabled; 100 Hz, 250 Hz, 1 kHz, 4 kHz, 10 kHz; 0 dB; Q 0.7071
/// (shelves) and 1.0 (peaking).
DomineEQParams domine_eq_default_params(void);

DomineEQ *_Nullable domine_eq_create(double sampleRate);
void domine_eq_destroy(DomineEQ *_Nullable eq);
void domine_eq_set_params(DomineEQ *eq, const DomineEQParams *p);
void domine_eq_process(DomineEQ *eq, float *samples, uint32_t frames);
int domine_eq_is_idle(const DomineEQ *eq);

/// Normalized RBJ coefficients, out points to 5 doubles = {b0, b1, b2, a1, a2} (a0 divided out)
/// for one band, after clamping. Gain exactly 0 gives {1, 0, 0, 0, 0}.
void domine_eq_coefficients(int type, double sampleRate, double freqHz, double gainDb, double q,
                            double *out);

#pragma clang assume_nonnull end
#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
