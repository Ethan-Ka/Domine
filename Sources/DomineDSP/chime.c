// Shared chime synth. Real-time safe: no allocation, no state, no I/O.

#include "include/DomineChime.h"

#include <math.h>

static double note(double t, double hz) {
    if (t < 0.0) return 0.0;
    const double attack = t < DOMINE_CHIME_ATTACK_S ? t / DOMINE_CHIME_ATTACK_S : 1.0;
    const double w = 2.0 * M_PI * hz * t;
    const double partials = sin(w) + DOMINE_CHIME_HARMONIC2 * sin(2.0 * w)
                          + DOMINE_CHIME_HARMONIC3 * sin(3.0 * w);
    return attack * exp(-t / DOMINE_CHIME_DECAY_S) * partials;
}

double domine_chime_sample(double t) {
    return DOMINE_CHIME_GAIN * (note(t, DOMINE_CHIME_NOTE1_HZ)
                              + note(t - DOMINE_CHIME_NOTE2_DELAY_S, DOMINE_CHIME_NOTE2_HZ));
}
