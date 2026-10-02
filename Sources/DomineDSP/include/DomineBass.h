#ifndef DOMINE_BASS_H
#define DOMINE_BASS_H

// Psychoacoustic bass enhancer for a small driver (JBL Grip, response from
// about 70 Hz). Mono, in place. Real-time safe in process: no allocation, no
// locks, no I/O. Parameters cross threads with C11 atomics (inactive copy plus
// index swap, single writer) and are smoothed over about 10 ms.
//
// Path: 2nd order low-pass at cutoff, smooth waveshaper (tanh plus rectified
// tanh) to make 2nd and 3rd harmonics, band-pass 1x to 4x cutoff, plus a gentle
// shelf term (up to +4 dB at amount 1). The whole boost path is high-passed at
// 60 Hz so nothing is added below that. The boost is limited to the running
// input peak, so output peak stays under +6 dB. enabled = 0 is bit-exact
// passthrough.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int enabled;
    float amount;   // 0...1
    float cutoffHz; // default 120
} DomineBassParams;

typedef struct DomineBass DomineBass;

DomineBass *domine_bass_create(double sampleRate);
void domine_bass_destroy(DomineBass *bass);
void domine_bass_set_params(DomineBass *bass, const DomineBassParams *params);
void domine_bass_process(DomineBass *bass, float *samples, uint32_t frames);
/// Nonzero when disabled (or amount 0) and fully faded out, so the caller may skip process.
int domine_bass_is_idle(const DomineBass *bass);

#ifdef __cplusplus
}
#endif

#endif
