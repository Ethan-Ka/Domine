#ifndef DOMINE_EQ_H
#define DOMINE_EQ_H

// Parametric EQ of up to eight bands, one mono stream (SPEC section 5a,
// contract in DomineEffects.h). Each band is a peaking, low shelf, high
// shelf or notch filter. RBJ cookbook biquads, double precision state, float
// samples. Storage for all eight bands is allocated in domine_eq_create.

#include "DomineEffects.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

#define DOMINE_EQ_BANDS 8
#define DOMINE_EQ_DEFAULT_BANDS 5
#define DOMINE_EQ_MAX_GAIN_DB 12.0
#define DOMINE_EQ_SMOOTH_MS 10.0

typedef enum {
    DOMINE_EQ_LOW_SHELF = 0,
    DOMINE_EQ_PEAKING = 1,
    DOMINE_EQ_HIGH_SHELF = 2,
    DOMINE_EQ_NOTCH = 3, // ignores gain; always active while the EQ is enabled
} DomineEQBandType;

typedef struct DomineEQBand {
    float freqHz;  // clamped to [20, 0.45 * sampleRate]
    float gainDb;  // clamped to +-12; exactly 0 makes a peak or shelf a no-op
    float q;       // clamped to [0.1, 10]
} DomineEQBand;

typedef struct DomineEQParams {
    int enabled;   // 0 fades every band to a no-op
    DomineEQBand bands[DOMINE_EQ_BANDS];
    int bandCount; // 0...DOMINE_EQ_BANDS; bands at or past it are no-ops
    int types[DOMINE_EQ_BANDS]; // DomineEQBandType per band; unknown values act as peaking
} DomineEQParams;

typedef struct DomineEQ DomineEQ;

/// Defaults: disabled; five bands: low shelf 100 Hz, peaking 250 Hz, 1 kHz,
/// 4 kHz, high shelf 10 kHz; 0 dB; Q 0.7071 (shelves) and 1.0 (peaking).
/// Bands 5 to 7 are peaking 1 kHz, 0 dB, Q 1, outside bandCount.
DomineEQParams domine_eq_default_params(void);

DomineEQ *_Nullable domine_eq_create(double sampleRate);
void domine_eq_destroy(DomineEQ *_Nullable eq);
void domine_eq_set_params(DomineEQ *eq, const DomineEQParams *p);
void domine_eq_process(DomineEQ *eq, float *samples, uint32_t frames);
int domine_eq_is_idle(const DomineEQ *eq);

/// Normalized RBJ coefficients, out points to 5 doubles = {b0, b1, b2, a1, a2} (a0 divided out)
/// for one band, after clamping. Gain exactly 0 gives {1, 0, 0, 0, 0} except for a notch,
/// which ignores gain.
void domine_eq_coefficients(int type, double sampleRate, double freqHz, double gainDb, double q,
                            double *out);

#pragma clang assume_nonnull end
#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
