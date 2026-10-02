#include "DomineCompressor.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define KNEE_DB 6.0
#define LIMITER_RELEASE_S 0.05
#define FADE_S 0.01
#define PARAM_WORDS ((sizeof(DomineCompressorParams) + 3) / 4)
#define MAX_READ_TRIES 4

_Static_assert(sizeof(DomineCompressorParams) % 4 == 0, "params must pack into whole words");

struct DomineCompressor {
    double sampleRate;
    // Parameters cross threads through a seqlock over atomic words (odd seq =
    // writer mid-store), so the audio thread never reads a half-written set.
    _Atomic uint32_t seq;
    _Atomic uint32_t words[PARAM_WORDS];
    DomineCompressorParams cur; // last consistent set (audio thread only)
    double gainDb;      // smoothed compressor gain (audio thread only)
    double limGain;     // linear limiter gain, <= 1 (audio thread only)
    double mix;         // 0 = dry, 1 = processed; ramps over FADE_S (audio thread only)
    int primed;         // set once process has run, so the first call snaps mix
};

static DomineCompressorParams default_params(void) {
    DomineCompressorParams p = {0, -18.0f, 3.0f, 10.0f, 100.0f, 0.0f, -1.0f};
    return p;
}

DomineCompressor *domine_compressor_create(double sampleRate) {
    DomineCompressor *c = calloc(1, sizeof(DomineCompressor));
    if (!c) return NULL;
    c->sampleRate = sampleRate > 0 ? sampleRate : 48000.0;
    c->cur = default_params();
    uint32_t w[PARAM_WORDS];
    memcpy(w, &c->cur, sizeof c->cur);
    atomic_init(&c->seq, 0);
    for (size_t i = 0; i < PARAM_WORDS; i++) atomic_init(&c->words[i], w[i]);
    c->limGain = 1.0;
    return c;
}

void domine_compressor_destroy(DomineCompressor *c) { free(c); }

void domine_compressor_set_params(DomineCompressor *c, const DomineCompressorParams *p) {
    if (!c || !p) return;
    uint32_t w[PARAM_WORDS];
    memcpy(w, p, sizeof *p);
    const uint32_t s = atomic_load_explicit(&c->seq, memory_order_relaxed);
    atomic_store_explicit(&c->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    for (size_t i = 0; i < PARAM_WORDS; i++) atomic_store_explicit(&c->words[i], w[i], memory_order_relaxed);
    atomic_store_explicit(&c->seq, s + 2, memory_order_release);
}

// Latest consistent parameters, or the last ones read if the writer is busy.
static DomineCompressorParams read_params(const DomineCompressor *c) {
    DomineCompressor *m = (DomineCompressor *)c;
    for (int tries = 0; tries < MAX_READ_TRIES; tries++) {
        const uint32_t s1 = atomic_load_explicit(&m->seq, memory_order_acquire);
        if (s1 & 1u) continue;
        uint32_t w[PARAM_WORDS];
        for (size_t i = 0; i < PARAM_WORDS; i++) w[i] = atomic_load_explicit(&m->words[i], memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&m->seq, memory_order_relaxed) != s1) continue;
        DomineCompressorParams p;
        memcpy(&p, w, sizeof p);
        return p;
    }
    return c->cur;
}

static double coeff(double ms, double sr) {
    double s = ms > 0.01 ? ms * 0.001 : 0.00001;
    return exp(-1.0 / (s * sr));
}

/// Gain in dB (excluding makeup) for a detected level in dB.
static double static_gain_db(double level, double thr, double ratio) {
    double over = level - thr;
    double slope = 1.0 / ratio - 1.0;
    if (2.0 * over < -KNEE_DB) return 0.0;
    if (2.0 * fabs(over) <= KNEE_DB) {
        double x = over + KNEE_DB * 0.5;
        return slope * x * x / (2.0 * KNEE_DB);
    }
    return slope * over;
}

void domine_compressor_process(DomineCompressor *c, float *samples, uint32_t frames) {
    if (!c || !samples) return;
    c->cur = read_params(c);
    const DomineCompressorParams *p = &c->cur;
    if (!c->primed) {
        c->primed = 1;
        c->mix = p->enabled ? 1.0 : 0.0;
    }
    if (!p->enabled && c->mix <= 0.0) return; // settled: bit-exact passthrough
    if (p->enabled && c->mix <= 0.0) { // leaving rest: start from a clean state
        c->gainDb = 0.0;
        c->limGain = 1.0;
    }
    const double target_mix = p->enabled ? 1.0 : 0.0;
    const double mixStep = 1.0 / (FADE_S * c->sampleRate);
    double m = c->mix;

    const double thr = p->thresholdDb;
    const double ratio = p->ratio < 1.0f ? 1.0 : p->ratio;
    const double makeup = p->makeupDb;
    const double aC = coeff(p->attackMs, c->sampleRate);
    const double rC = coeff(p->releaseMs, c->sampleRate);
    const double limR = exp(-1.0 / (LIMITER_RELEASE_S * c->sampleRate));
    const float ceil = (float)pow(10.0, p->limiterCeilingDb / 20.0);

    double g = c->gainDb;
    double lg = c->limGain;
    for (uint32_t i = 0; i < frames; i++) {
        float x = samples[i];
        double a = fabs((double)x);
        if (a < 1e-6) a = 1e-6;
        double target = static_gain_db(20.0 * log10(a), thr, ratio) + makeup;
        double k = target < g ? aC : rC;
        g = target + k * (g - target);

        float y = x * (float)pow(10.0, g / 20.0);
        float ay = fabsf(y);
        if (ay * (float)lg > ceil) {
            lg = (double)ceil / (double)ay; // instant attack
        } else {
            lg = 1.0 + limR * (lg - 1.0);
        }
        y *= (float)lg;
        if (y > ceil) y = ceil;
        else if (y < -ceil) y = -ceil;
        if (m != target_mix) {
            m += m < target_mix ? mixStep : -mixStep;
            if (m > 1.0) m = 1.0;
            if (m < 0.0) m = 0.0;
        }
        samples[i] = m >= 1.0 ? y : x + (float)m * (y - x);
    }
    c->mix = m;
    c->gainDb = g;
    c->limGain = lg;
}

int domine_compressor_is_idle(const DomineCompressor *c) {
    if (!c) return 1;
    return !read_params(c).enabled && c->mix <= 0.0;
}
