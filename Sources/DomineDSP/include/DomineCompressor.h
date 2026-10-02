#ifndef DOMINE_COMPRESSOR_H
#define DOMINE_COMPRESSOR_H

#include <stdint.h>

/// Mono feed-forward compressor with a 6 dB soft knee, followed by a
/// brickwall-ish limiter. Real-time safe: `process` does no allocation, locking or I/O.
/// `enabled == 0` leaves samples bit-exact.
typedef struct {
    int enabled;
    float thresholdDb;      // default -18
    float ratio;            // >= 1, default 3
    float attackMs;         // default 10
    float releaseMs;        // default 100
    float makeupDb;         // default 0
    float limiterCeilingDb; // default -1
} DomineCompressorParams;

typedef struct DomineCompressor DomineCompressor;

/// Not real-time safe (allocates). Starts disabled with default parameters.
DomineCompressor *domine_compressor_create(double sampleRate);
void domine_compressor_destroy(DomineCompressor *c);

/// Safe from any one control thread while `process` runs on the audio thread.
void domine_compressor_set_params(DomineCompressor *c, const DomineCompressorParams *p);

/// Processes mono samples in place.
void domine_compressor_process(DomineCompressor *c, float *samples, uint32_t frames);

/// Nonzero when the active parameters are disabled, so the caller may skip process.
int domine_compressor_is_idle(const DomineCompressor *c);

#endif
