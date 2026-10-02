// Bass enhancer. Real-time safe in process: no allocation, no locks, no I/O.

#include "include/DomineBass.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define PARAM_WORDS ((sizeof(DomineBassParams) + 3) / 4)
#define MAX_READ_TRIES 4

_Static_assert(sizeof(DomineBassParams) % 4 == 0, "params must pack into whole words");

typedef struct { float b0, b1, b2, a1, a2; } Coef;
typedef struct { float z1, z2; } State;

struct DomineBass {
    double sampleRate;
    // Parameters cross threads through a seqlock over atomic words (odd seq =
    // writer mid-store), so the audio thread never reads a half-written set.
    _Atomic uint32_t seq;
    _Atomic uint32_t words[PARAM_WORDS];
    DomineBassParams cur;   // last consistent set (audio thread only)
    float cutoff;           // cutoff the coefficients were built for
    float wet;              // smoothed amount (0 when disabled)
    float smoothA;
    float env;              // running input peak
    float envRelease;
    Coef lp, hp, bpLp, hp60;
    State sLp, sHp, sBpLp, sHp60, sHp60b;
};

// NaN clamps to lo, so a bad parameter can never poison the filter state.
static float clampf(float v, float lo, float hi) { return !(v >= lo) ? lo : (v > hi ? hi : v); }

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
    b->cur.enabled = 0;
    b->cur.amount = 0;
    b->cur.cutoffHz = 120;
    uint32_t w[PARAM_WORDS];
    memcpy(w, &b->cur, sizeof b->cur);
    atomic_init(&b->seq, 0);
    for (size_t i = 0; i < PARAM_WORDS; i++) atomic_init(&b->words[i], w[i]);
    b->smoothA = (float)(1.0 - exp(-1.0 / (0.0033 * sampleRate)));
    b->envRelease = (float)exp(-1.0 / (0.05 * sampleRate));
    b->hp60 = biquad(sampleRate, 60.0, 1);
    build(b, 120.0f);
    return b;
}

void domine_bass_destroy(DomineBass *b) { free(b); }

void domine_bass_set_params(DomineBass *b, const DomineBassParams *p) {
    uint32_t w[PARAM_WORDS];
    memcpy(w, p, sizeof *p);
    const uint32_t s = atomic_load_explicit(&b->seq, memory_order_relaxed);
    atomic_store_explicit(&b->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    for (size_t i = 0; i < PARAM_WORDS; i++) atomic_store_explicit(&b->words[i], w[i], memory_order_relaxed);
    atomic_store_explicit(&b->seq, s + 2, memory_order_release);
}

// Latest consistent parameters, or the last ones read if the writer is busy.
static DomineBassParams read_params(const DomineBass *b) {
    DomineBass *m = (DomineBass *)b;
    for (int tries = 0; tries < MAX_READ_TRIES; tries++) {
        const uint32_t s1 = atomic_load_explicit(&m->seq, memory_order_acquire);
        if (s1 & 1u) continue;
        uint32_t w[PARAM_WORDS];
        for (size_t i = 0; i < PARAM_WORDS; i++) w[i] = atomic_load_explicit(&m->words[i], memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&m->seq, memory_order_relaxed) != s1) continue;
        DomineBassParams p;
        memcpy(&p, w, sizeof p);
        return p;
    }
    return b->cur;
}

void domine_bass_process(DomineBass *b, float *x, uint32_t frames) {
    b->cur = read_params(b);
    const DomineBassParams p = b->cur;
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
    const DomineBassParams p = read_params(b);
    const int off = !p.enabled || !(p.amount > 0.0f);
    return off && b->wet == 0.0f;
}
