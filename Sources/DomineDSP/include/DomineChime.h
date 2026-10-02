#ifndef DOMINE_CHIME_H
#define DOMINE_CHIME_H

// Warm two-note bass chime shared by the engine test tone and the
// single-device identification tone. Real-time safe: pure function of time,
// no allocation, no state, only sin and exp from libm.
//
// Each note is fundamental + 0.35 * 2nd harmonic + 0.12 * 3rd harmonic with an
// 8 ms linear attack and an exponential decay (time constant 250 ms). Note 1
// is 110 Hz and starts at t = 0; note 2 is 165 Hz (a fifth up) and starts at
// 180 ms. The sum is scaled so its peak is DOMINE_CHIME_PEAK (0.3). The
// fundamentals stay at or above 110 Hz because the JBL Grip rolls off near
// 70 Hz.

#ifdef __cplusplus
extern "C" {
#endif

#define DOMINE_CHIME_NOTE1_HZ 110.0
#define DOMINE_CHIME_NOTE2_HZ 165.0
#define DOMINE_CHIME_HARMONIC2 0.35
#define DOMINE_CHIME_HARMONIC3 0.12
#define DOMINE_CHIME_ATTACK_S 0.008
#define DOMINE_CHIME_DECAY_S 0.25
#define DOMINE_CHIME_NOTE2_DELAY_S 0.18
/// Length of one chime pattern; the engine tone repeats at this period.
#define DOMINE_CHIME_PERIOD_S 1.5
/// Absolute peak of the chime after normalization.
#define DOMINE_CHIME_PEAK 0.3
/// 0.3 divided by the raw peak of the unscaled sum (1.56684).
#define DOMINE_CHIME_GAIN 0.1914

/// The chime at `t` seconds after the pattern starts. Zero for t < 0.
/// |result| <= DOMINE_CHIME_PEAK for every t.
double domine_chime_sample(double t);

#ifdef __cplusplus
}
#endif

#endif
