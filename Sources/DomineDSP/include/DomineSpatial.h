#ifndef DOMINE_SPATIAL_H
#define DOMINE_SPATIAL_H

// Stereo to quad spatial upmixer (SPEC section 11.6a). Input L, R; output the
// two rear channels RL, RR (the fronts are the untouched input, so the caller
// plays FL = L, FR = R). Follows the effect contract (DomineEffects.h) except
// that the stream is stereo in, rear pair out, so it is not in place.
//
// Rear = (1 - amount) * mirror + amount * ambience. Ambience is the side
// signal S = (L - R) / 2, delayed by the room size, run through a different
// short all-pass chain per rear (RR is also polarity inverted), high-shelf cut
// above highCutHz, scaled by sqrt(2) so uncorrelated material keeps its level,
// and clamped to +-1. Mono input (L = R) gives S = 0, so the rears fall to
// silence as amount rises. For inputs within +-1 the rear output stays within
// +-1. amount 0 (settled) copies L and R bit for bit.
//
// Real-time safe in process: no allocation, locks, logging, I/O. Parameters
// cross threads through a seqlock over atomic words and are smoothed (~10 ms).

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    float amount;     // 0...1, default 0 (mirror)
    float roomMs;     // rear delay, clamped 5...30, default 15
    float highCutHz;  // shelf corner for the rears, clamped 1000...16000, default 5000
} DomineSpatialParams;

typedef struct DomineSpatial DomineSpatial;

DomineSpatial *domine_spatial_create(double sampleRate);
void domine_spatial_destroy(DomineSpatial *sp);
void domine_spatial_set_params(DomineSpatial *sp, const DomineSpatialParams *params);
/// Renders `frames` frames. rl and rr must not alias l or r.
void domine_spatial_process(DomineSpatial *sp, const float *l, const float *r,
                            float *rl, float *rr, uint32_t frames);
/// One frame; same result as process with frames = 1.
void domine_spatial_tick(DomineSpatial *sp, float l, float r, float *rl, float *rr);
/// Nonzero when amount is 0 and settled (rears equal the mirror).
int domine_spatial_is_idle(const DomineSpatial *sp);

#ifdef __cplusplus
}
#endif

#endif
