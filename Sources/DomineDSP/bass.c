// Bass enhancer. Real-time safe in process: no allocation, no locks, no I/O.

#include "include/DomineBass.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float b0, b1, b2, a1, a2; } Coef;
typedef struct { float z1, z2; } State;

struct DomineBass {
    double sampleRate;
    DomineBassParams slots[2];
    atomic_int active;      // index of the slot the audio thread reads
    float cutoff;           // cutoff the coefficients were built for
    float wet;              // smoothed amount (0 when disabled)
    float smoothA;
    float env;              // running input peak
    float envRelease;
    Coef lp, hp, bpLp, hp60;
    State sLp, sHp, sBpLp, sHp60, sHp60b;
};

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

static Coef biquad(double sr, double fc, int highpass) {
    const double w = 2.0 * M_PI * fc / sr;
    const double c = cos(w), alpha = sin(w) / (2.0 * 0.70710678118654752);
    const double a0 = 1.0 + alpha;
    double b0, b1, b2;
    if (highpass) { b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2; }
    else { b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2; }
    Coef k = { (float)(b0 / a0), (float)(b1 / a0), (float)(b2 / a0),
               (float)(-2.0 * c / a0), (float)((1.0 - alpha) / a0) };
    return k;
}

static float run(const Coef *k, State *s, float x) {
    const float y = k->b0 * x + s->z1;
    s->z1 = k->b1 * x - k->a1 * y + s->z2;
    s->z2 = k->b2 * x - k->a2 * y;
    return y;
}

static void build(DomineBass *b, float cutoff) {
    b->cutoff = cutoff;
    b->lp = biquad(b->sampleRate, cutoff, 0);
    b->hp = biquad(b->sampleRate, cutoff, 1);
    b->bpLp = biquad(b->sampleRate, fmin(4.0 * cutoff, 0.45 * b->sampleRate), 0);
}

static void reset(DomineBass *b) {
    b->sLp = b->sHp = b->sBpLp = b->sHp60 = b->sHp60b = (State){0, 0};
    b->env = 0.0f;
}

DomineBass *domine_bass_create(double sampleRate) {
    DomineBass *b = calloc(1, sizeof(DomineBass));
    if (!b) return NULL;
    b->sampleRate = sampleRate;
    for (int i = 0; i < 2; i++) {
        b->slots[i].enabled = 0;
        b->slots[i].amount = 0;
        b->slots[i].cutoffHz = 120;
    }
    atomic_init(&b->active, 0);
    b->smoothA = (float)(1.0 - exp(-1.0 / (0.0033 * sampleRate)));
    b->envRelease = (float)exp(-1.0 / (0.05 * sampleRate));
    b->hp60 = biquad(sampleRate, 60.0, 1);
    build(b, 120.0f);
    return b;
}

void domine_bass_destroy(DomineBass *b) { free(b); }

void domine_bass_set_params(DomineBass *b, const DomineBassParams *p) {
    const int next = 1 - atomic_load_explicit(&b->active, memory_order_relaxed);
    b->slots[next] = *p;
    atomic_store_explicit(&b->active, next, memory_order_release);
}

void domine_bass_process(DomineBass *b, float *x, uint32_t frames) {
    const DomineBassParams p = b->slots[atomic_load_explicit(&b->active, memory_order_acquire)];
    const float target = p.enabled ? clampf(p.amount, 0.0f, 1.0f) : 0.0f;
    if (target == 0.0f && b->wet == 0.0f) { reset(b); return; }
    const float cutoff = clampf(p.cutoffHz, 80.0f, (float)(0.1 * b->sampleRate));
    if (cutoff != b->cutoff) build(b, cutoff);
    const float shelfGain = 0.58489f; // 10^(4/20) - 1
    for (uint32_t i = 0; i < frames; i++) {
        b->wet += (target - b->wet) * b->smoothA;
        if (target == 0.0f && b->wet < 1e-6f) b->wet = 0.0f;
        const float in = x[i];
        const float low = run(&b->lp, &b->sLp, in);
        // Odd harmonics from tanh, even from rectified tanh (DC removed below).
        const float shaped = tanhf(3.0f * low) + tanhf(3.0f * fabsf(low));
        const float band = run(&b->bpLp, &b->sBpLp, run(&b->hp, &b->sHp, shaped));
        float boost = 0.5f * band + shelfGain * low;
        boost = run(&b->hp60, &b->sHp60b, run(&b->hp60, &b->sHp60, boost)); // 4th order, nothing added below 60 Hz
        boost *= b->wet;
        const float a = fabsf(in);
        b->env = a > b->env ? a : b->env * b->envRelease;
        const float lim = 0.9f * b->env + 1e-9f;
        x[i] = in + lim * tanhf(boost / lim);
    }
    // Fully faded out: clear state now, since the kernel skips idle calls.
    if (target == 0.0f && b->wet == 0.0f) reset(b);
}

int domine_bass_is_idle(const DomineBass *b) {
    const DomineBassParams *p = &b->slots[atomic_load_explicit(&((DomineBass *)b)->active, memory_order_acquire)];
    const int off = !p->enabled || !(p->amount > 0.0f);
    return off && b->wet == 0.0f;
}
