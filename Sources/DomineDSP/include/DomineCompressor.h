#ifndef DOMINE_COMPRESSOR_H
#define DOMINE_COMPRESSOR_H

#include <stdint.h>

/// Mono feed-forward compressor with a 6 dB soft knee, followed by a
/// brickwall-ish limiter. Real-time safe: `process` does no allocation, locking or I/O.
/// `enabled == 0` leaves samples bit-exact once the 10 ms crossfade to dry has finished.
typedef struct {
    int enabled;
    float thresholdDb;      // default -18
    float ratio;            // >= 1, default 3
    float attackMs;         // default 10
    float releaseMs;        // default 100
    float makeupDb;         // default 0
    float limiterCeilingDb; // default -1
} DomineCompressorParams;

/// Parameter ranges. set_params clamps finite values into them and replaces
/// NaN or infinite values with the defaults above, so the gain state can never
/// become non-finite. While processing (not idle), a NaN or infinite input
/// sample is treated as silence.
#define DOMINE_COMP_THRESHOLD_MIN_DB (-80.0f) // ... 0
#define DOMINE_COMP_RATIO_MAX 100.0f          // 1 ...
#define DOMINE_COMP_ATTACK_MAX_MS 2000.0f     // 0 ...
#define DOMINE_COMP_RELEASE_MAX_MS 5000.0f    // 0 ...
#define DOMINE_COMP_MAKEUP_MAX_DB 24.0f       // -24 ...
#define DOMINE_COMP_CEILING_MIN_DB (-60.0f)   // ... 0

typedef struct DomineCompressor DomineCompressor;

/// The parameters set_params actually applies (clamped, non-finite to default).
DomineCompressorParams domine_compressor_sanitize(const DomineCompressorParams *p);

/// Not real-time safe (allocates). Starts disabled with default parameters.
DomineCompressor *domine_compressor_create(double sampleRate);
void domine_compressor_destroy(DomineCompressor *c);

/// Safe from any one control thread while `process` runs on the audio thread.
void domine_compressor_set_params(DomineCompressor *c, const DomineCompressorParams *p);

/// Processes mono samples in place.
void domine_compressor_process(DomineCompressor *c, float *samples, uint32_t frames);

/// Nonzero when disabled and the fade to dry has finished, so the caller may skip process.
int domine_compressor_is_idle(const DomineCompressor *c);

#endif
