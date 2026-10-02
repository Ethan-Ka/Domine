#include "DomineCompressor.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>

#define KNEE_DB 6.0
#define LIMITER_RELEASE_S 0.05

struct DomineCompressor {
    double sampleRate;
    DomineCompressorParams params[2];
    _Atomic int active; // index of the params copy the audio thread reads
    double gainDb;      // smoothed compressor gain (audio thread only)
    double limGain;     // linear limiter gain, <= 1 (audio thread only)
};

static DomineCompressorParams default_params(void) {
    DomineCompressorParams p = {0, -18.0f, 3.0f, 10.0f, 100.0f, 0.0f, -1.0f};
    return p;
}

DomineCompressor *domine_compressor_create(double sampleRate) {
    DomineCompressor *c = calloc(1, sizeof(DomineCompressor));
    if (!c) return NULL;
    c->sampleRate = sampleRate > 0 ? sampleRate : 48000.0;
    c->params[0] = c->params[1] = default_params();
    atomic_init(&c->active, 0);
    c->limGain = 1.0;
    return c;
}

void domine_compressor_destroy(DomineCompressor *c) { free(c); }

void domine_compressor_set_params(DomineCompressor *c, const DomineCompressorParams *p) {
    if (!c || !p) return;
    int cur = atomic_load_explicit(&c->active, memory_order_relaxed);
    int next = 1 - cur;
    c->params[next] = *p;
    atomic_store_explicit(&c->active, next, memory_order_release);
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
    int idx = atomic_load_explicit(&c->active, memory_order_acquire);
    const DomineCompressorParams *p = &c->params[idx];
    if (!p->enabled) return;

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
        samples[i] = y;
    }
    c->gainDb = g;
    c->limGain = lg;
}
