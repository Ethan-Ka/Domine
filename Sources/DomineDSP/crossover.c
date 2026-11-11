// Per-speaker role and LR4 crossover. See include/DomineCrossover.h.
//
// Real-time safe. Parameters arrive through a seqlock over atomic words.
// The output is a mix dry * x + hp * HP(x) + lp * LP(x); a role sets the
// target mix (full range 1/0/0, satellite 0/1/0, subwoofer 0/0/1) and the
// mix ramps linearly over 10 ms, landing exactly on its target. Once a full
// range target has settled the module is idle and skipped, its state zeroed,
// so samples pass bit for bit. Coefficients slide linearly over 10 ms on a
// frequency change while a filter is running, and snap while idle.

#include "include/DomineCrossover.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define PARAM_WORDS 2
#define MAX_READ_TRIES 4

enum { MIX_DRY = 0, MIX_HP = 1, MIX_LP = 2, MIX_COUNT = 3 };

typedef struct {
    double cur[5], step[5], target[5];
    double z[2][2]; // two cascaded sections, transposed direct form II
} Filter;

struct DomineCrossover {
    double sampleRate;
    uint32_t smoothSamples;
    _Atomic uint32_t seq; // odd while the writer is storing
    _Atomic uint32_t words[PARAM_WORDS];

    // Render thread only.
    uint32_t seenSeq;
    int idle;
    uint32_t coefLeft;
    uint32_t mixLeft;
    double mix[MIX_COUNT], mixStep[MIX_COUNT], mixTarget[MIX_COUNT];
    Filter hp, lp;
};

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

DomineCrossoverParams domine_crossover_default_params(void) {
    DomineCrossoverParams p;
    p.role = DOMINE_ROLE_FULL_RANGE;
    p.freqHz = (float)DOMINE_CROSSOVER_DEFAULT_HZ;
    return p;
}

static double clamp_freq(double hz, double sampleRate) {
    if (!isfinite(hz)) hz = DOMINE_CROSSOVER_DEFAULT_HZ;
    if (hz < DOMINE_CROSSOVER_MIN_HZ) hz = DOMINE_CROSSOVER_MIN_HZ;
    if (hz > DOMINE_CROSSOVER_MAX_HZ) hz = DOMINE_CROSSOVER_MAX_HZ;
    const double nyquistLimit = 0.45 * sampleRate;
    return hz > nyquistLimit ? nyquistLimit : hz;
}

void domine_crossover_coefficients(int highpass, double sampleRate, double freqHz, double *out) {
    freqHz = clamp_freq(freqHz, sampleRate);
    const double w0 = 2.0 * M_PI * freqHz / sampleRate;
    const double cw = cos(w0);
    const double alpha = sin(w0) / (2.0 * M_SQRT1_2);
    const double a0 = 1.0 + alpha;
    double b0, b1;
    if (highpass) {
        b0 = (1.0 + cw) * 0.5;
        b1 = -(1.0 + cw);
    } else {
        b0 = (1.0 - cw) * 0.5;
        b1 = 1.0 - cw;
    }
    out[0] = b0 / a0;
    out[1] = b1 / a0;
    out[2] = b0 / a0;
    out[3] = -2.0 * cw / a0;
    out[4] = (1.0 - alpha) / a0;
}

DomineCrossover *domine_crossover_create(double sampleRate) {
    if (!(sampleRate > 0.0) || !isfinite(sampleRate)) return NULL;
    DomineCrossover *xo = calloc(1, sizeof(DomineCrossover));
    if (xo == NULL) return NULL;
    xo->sampleRate = sampleRate;
    const uint32_t n = (uint32_t)lround(sampleRate * DOMINE_CROSSOVER_SMOOTH_MS / 1000.0);
    xo->smoothSamples = n > 0 ? n : 1;
    atomic_init(&xo->seq, 0);
    atomic_init(&xo->words[0], DOMINE_ROLE_FULL_RANGE);
    atomic_init(&xo->words[1], f2u((float)DOMINE_CROSSOVER_DEFAULT_HZ));
    domine_crossover_coefficients(1, sampleRate, DOMINE_CROSSOVER_DEFAULT_HZ, xo->hp.cur);
    domine_crossover_coefficients(0, sampleRate, DOMINE_CROSSOVER_DEFAULT_HZ, xo->lp.cur);
    memcpy(xo->hp.target, xo->hp.cur, sizeof xo->hp.cur);
    memcpy(xo->lp.target, xo->lp.cur, sizeof xo->lp.cur);
    xo->mix[MIX_DRY] = xo->mixTarget[MIX_DRY] = 1.0;
    xo->idle = 1;
    return xo;
}

void domine_crossover_destroy(DomineCrossover *xo) { free(xo); }

void domine_crossover_set_params(DomineCrossover *xo, const DomineCrossoverParams *p) {
    const int role = p->role == DOMINE_ROLE_SATELLITE || p->role == DOMINE_ROLE_SUBWOOFER
        ? p->role : DOMINE_ROLE_FULL_RANGE;
    const uint32_t s = atomic_load_explicit(&xo->seq, memory_order_relaxed);
    atomic_store_explicit(&xo->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&xo->words[0], (uint32_t)role, memory_order_relaxed);
    atomic_store_explicit(&xo->words[1], f2u(p->freqHz), memory_order_relaxed);
    atomic_store_explicit(&xo->seq, s + 2, memory_order_release);
}

static void filter_reset(Filter *f) { memset(f->z, 0, sizeof f->z); }

static void filter_target(Filter *f, const double *t, int snap, uint32_t len) {
    for (int c = 0; c < 5; c++) {
        f->target[c] = t[c];
        if (snap) f->cur[c] = t[c];
        f->step[c] = snap ? 0.0 : (t[c] - f->cur[c]) / (double)len;
    }
}

static void pick_up(DomineCrossover *xo) {
    for (int tries = 0; tries < MAX_READ_TRIES; tries++) {
        const uint32_t s1 = atomic_load_explicit(&xo->seq, memory_order_acquire);
        if (s1 == xo->seenSeq) return;
        if (s1 & 1u) continue;
        uint32_t w[PARAM_WORDS];
        for (int i = 0; i < PARAM_WORDS; i++) w[i] = atomic_load_explicit(&xo->words[i], memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&xo->seq, memory_order_relaxed) != s1) continue;
        xo->seenSeq = s1;

        const int role = (int)w[0];
        const double hz = (double)u2f(w[1]);
        double hp[5], lp[5];
        domine_crossover_coefficients(1, xo->sampleRate, hz, hp);
        domine_crossover_coefficients(0, xo->sampleRate, hz, lp);
        // A filter that is silent in the mix has no audible state: snap.
        const int snapHP = xo->idle || (xo->mix[MIX_HP] == 0.0 && xo->mixTarget[MIX_HP] == 0.0);
        const int snapLP = xo->idle || (xo->mix[MIX_LP] == 0.0 && xo->mixTarget[MIX_LP] == 0.0);
        filter_target(&xo->hp, hp, snapHP, xo->smoothSamples);
        filter_target(&xo->lp, lp, snapLP, xo->smoothSamples);
        xo->coefLeft = snapHP && snapLP ? 0 : xo->smoothSamples;

        double t[MIX_COUNT] = { 0.0, 0.0, 0.0 };
        t[role == DOMINE_ROLE_SATELLITE ? MIX_HP : role == DOMINE_ROLE_SUBWOOFER ? MIX_LP : MIX_DRY] = 1.0;
        if (xo->idle && t[MIX_DRY] == 1.0) return; // full range stays idle
        int changed = 0;
        for (int i = 0; i < MIX_COUNT; i++) if (t[i] != xo->mixTarget[i] || xo->mix[i] != t[i]) changed = 1;
        if (changed) {
            for (int i = 0; i < MIX_COUNT; i++) {
                xo->mixTarget[i] = t[i];
                xo->mixStep[i] = (t[i] - xo->mix[i]) / (double)xo->smoothSamples;
            }
            xo->mixLeft = xo->smoothSamples;
        }
        xo->idle = 0;
        return;
    }
}

int domine_crossover_is_idle(const DomineCrossover *xo) {
    return xo->idle && atomic_load_explicit(&xo->seq, memory_order_acquire) == xo->seenSeq;
}

static inline double biquad(const double *c, double *z, double x) {
    const double y = c[0] * x + z[0];
    z[0] = c[1] * x - c[3] * y + z[1];
    z[1] = c[2] * x - c[4] * y;
    return y;
}

static inline double lr4(Filter *f, double x) {
    return biquad(f->cur, f->z[1], biquad(f->cur, f->z[0], x));
}

static void filter_step(Filter *f, int lastStep) {
    for (int c = 0; c < 5; c++) f->cur[c] = lastStep ? f->target[c] : f->cur[c] + f->step[c];
}

void domine_crossover_process(DomineCrossover *xo, float *samples, uint32_t frames) {
    pick_up(xo);
    if (xo->idle) return;
    for (uint32_t n = 0; n < frames; n++) {
        if (xo->coefLeft > 0) {
            const int lastStep = xo->coefLeft == 1;
            filter_step(&xo->hp, lastStep);
            filter_step(&xo->lp, lastStep);
            xo->coefLeft--;
        }
        if (xo->mixLeft > 0) {
            const int lastStep = xo->mixLeft == 1;
            for (int i = 0; i < MIX_COUNT; i++)
                xo->mix[i] = lastStep ? xo->mixTarget[i] : xo->mix[i] + xo->mixStep[i];
            xo->mixLeft--;
        }
        const double x = (double)samples[n];
        double y = 0.0;
        if (xo->mix[MIX_DRY] != 0.0) y += xo->mix[MIX_DRY] * x;
        if (xo->mix[MIX_HP] != 0.0 || xo->mixTarget[MIX_HP] != 0.0) y += xo->mix[MIX_HP] * lr4(&xo->hp, x);
        if (xo->mix[MIX_LP] != 0.0 || xo->mixTarget[MIX_LP] != 0.0) y += xo->mix[MIX_LP] * lr4(&xo->lp, x);
        samples[n] = (float)y;

        if (xo->mixLeft == 0) {
            if (xo->mix[MIX_HP] == 0.0) filter_reset(&xo->hp);
            if (xo->mix[MIX_LP] == 0.0) filter_reset(&xo->lp);
            if (xo->mix[MIX_DRY] == 1.0) {
                memcpy(xo->hp.cur, xo->hp.target, sizeof xo->hp.cur);
                memcpy(xo->lp.cur, xo->lp.target, sizeof xo->lp.cur);
                xo->coefLeft = 0;
                xo->idle = 1;
                return;
            }
        }
    }
}
