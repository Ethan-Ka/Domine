// Parametric EQ, up to DOMINE_EQ_BANDS bands. See include/DomineEQ.h and DomineEffects.h.
//
// Real-time safe. Parameters arrive through a seqlock over atomic words.
// Each band keeps current coefficients and a per-sample step toward its
// target, so a parameter change slides the coefficients linearly over 10 ms.
// A band whose gain is exactly 0 (not a notch), or past bandCount, has
// identity coefficients; once settled it
// is skipped and its state zeroed, so an all-flat EQ leaves samples
// untouched bit for bit.

#include "include/DomineEQ.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Words: enabled, bandCount, then per band freq, gain, q, type.
#define BAND_WORDS 4
#define PARAM_WORDS (2 + DOMINE_EQ_BANDS * BAND_WORDS)
#define W_FREQ(i) (2 + BAND_WORDS * (i))
#define W_GAIN(i) (3 + BAND_WORDS * (i))
#define W_Q(i) (4 + BAND_WORDS * (i))
#define W_TYPE(i) (5 + BAND_WORDS * (i))
#define MAX_READ_TRIES 4

typedef struct {
    double cur[5];
    double step[5];
    double target[5];
    double z1, z2;
    int identity; // settled at identity coefficients, skipped
} Band;

struct DomineEQ {
    double sampleRate;
    uint32_t smoothSamples;
    _Atomic uint32_t seq;                // odd while the writer is storing
    _Atomic uint32_t words[PARAM_WORDS];

    // Render thread only.
    uint32_t seenSeq;
    uint32_t rampLeft;
    int idle;
    Band bands[DOMINE_EQ_BANDS];
};

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static const double defaultFreq[DOMINE_EQ_DEFAULT_BANDS] = { 100.0, 250.0, 1000.0, 4000.0, 10000.0 };
static const int defaultType[DOMINE_EQ_DEFAULT_BANDS] = {
    DOMINE_EQ_LOW_SHELF, DOMINE_EQ_PEAKING, DOMINE_EQ_PEAKING, DOMINE_EQ_PEAKING, DOMINE_EQ_HIGH_SHELF
};

DomineEQParams domine_eq_default_params(void) {
    DomineEQParams p;
    memset(&p, 0, sizeof p);
    p.enabled = 0;
    p.bandCount = DOMINE_EQ_DEFAULT_BANDS;
    for (int i = 0; i < DOMINE_EQ_BANDS; i++) {
        const int d = i < DOMINE_EQ_DEFAULT_BANDS;
        p.types[i] = d ? defaultType[i] : DOMINE_EQ_PEAKING;
        p.bands[i].freqHz = d ? (float)defaultFreq[i] : 1000.0f;
        p.bands[i].gainDb = 0.0f;
        p.bands[i].q = p.types[i] == DOMINE_EQ_PEAKING ? 1.0f : 0.7071f;
    }
    return p;
}

static double clampd(double v, double lo, double hi) {
    if (!(v >= lo)) return lo; // also catches NaN
    return v > hi ? hi : v;
}

void domine_eq_coefficients(int type, double sampleRate, double freqHz, double gainDb, double q,
                            double *out) {
    gainDb = clampd(gainDb, -DOMINE_EQ_MAX_GAIN_DB, DOMINE_EQ_MAX_GAIN_DB);
    if (gainDb == 0.0 && type != DOMINE_EQ_NOTCH) {
        out[0] = 1.0; out[1] = out[2] = out[3] = out[4] = 0.0;
        return;
    }
    freqHz = clampd(freqHz, 20.0, 0.45 * sampleRate);
    q = clampd(q, 0.1, 10.0);
    const double A = pow(10.0, gainDb / 40.0);
    const double w0 = 2.0 * M_PI * freqHz / sampleRate;
    const double cw = cos(w0), sw = sin(w0);
    const double alpha = sw / (2.0 * q);
    double b0, b1, b2, a0, a1, a2;
    if (type == DOMINE_EQ_NOTCH) {
        b0 = 1.0;
        b1 = -2.0 * cw;
        b2 = 1.0;
        a0 = 1.0 + alpha;
        a1 = -2.0 * cw;
        a2 = 1.0 - alpha;
    } else if (type != DOMINE_EQ_LOW_SHELF && type != DOMINE_EQ_HIGH_SHELF) {
        b0 = 1.0 + alpha * A;
        b1 = -2.0 * cw;
        b2 = 1.0 - alpha * A;
        a0 = 1.0 + alpha / A;
        a1 = -2.0 * cw;
        a2 = 1.0 - alpha / A;
    } else {
        const double t = 2.0 * sqrt(A) * alpha;
        if (type == DOMINE_EQ_LOW_SHELF) {
            b0 = A * ((A + 1.0) - (A - 1.0) * cw + t);
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
            b2 = A * ((A + 1.0) - (A - 1.0) * cw - t);
            a0 = (A + 1.0) + (A - 1.0) * cw + t;
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
            a2 = (A + 1.0) + (A - 1.0) * cw - t;
        } else {
            b0 = A * ((A + 1.0) + (A - 1.0) * cw + t);
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
            b2 = A * ((A + 1.0) + (A - 1.0) * cw - t);
            a0 = (A + 1.0) - (A - 1.0) * cw + t;
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw);
            a2 = (A + 1.0) - (A - 1.0) * cw - t;
        }
    }
    out[0] = b0 / a0; out[1] = b1 / a0; out[2] = b2 / a0; out[3] = a1 / a0; out[4] = a2 / a0;
}

DomineEQ *domine_eq_create(double sampleRate) {
    if (!(sampleRate > 0.0)) return NULL;
    DomineEQ *eq = calloc(1, sizeof(DomineEQ));
    if (eq == NULL) return NULL;
    eq->sampleRate = sampleRate;
    uint32_t n = (uint32_t)lround(sampleRate * DOMINE_EQ_SMOOTH_MS / 1000.0);
    eq->smoothSamples = n > 0 ? n : 1;
    atomic_init(&eq->seq, 0);
    const DomineEQParams d = domine_eq_default_params();
    atomic_init(&eq->words[0], 0);
    atomic_init(&eq->words[1], (uint32_t)d.bandCount);
    for (int i = 0; i < DOMINE_EQ_BANDS; i++) {
        atomic_init(&eq->words[W_FREQ(i)], f2u(d.bands[i].freqHz));
        atomic_init(&eq->words[W_GAIN(i)], f2u(d.bands[i].gainDb));
        atomic_init(&eq->words[W_Q(i)], f2u(d.bands[i].q));
        atomic_init(&eq->words[W_TYPE(i)], (uint32_t)d.types[i]);
        Band *b = &eq->bands[i];
        b->cur[0] = b->target[0] = 1.0;
        b->identity = 1;
    }
    eq->idle = 1;
    return eq;
}

void domine_eq_destroy(DomineEQ *eq) { free(eq); }

void domine_eq_set_params(DomineEQ *eq, const DomineEQParams *p) {
    const uint32_t s = atomic_load_explicit(&eq->seq, memory_order_relaxed);
    atomic_store_explicit(&eq->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&eq->words[0], p->enabled ? 1u : 0u, memory_order_relaxed);
    const int count = p->bandCount < 0 ? 0 : (p->bandCount > DOMINE_EQ_BANDS ? DOMINE_EQ_BANDS : p->bandCount);
    atomic_store_explicit(&eq->words[1], (uint32_t)count, memory_order_relaxed);
    for (int i = 0; i < DOMINE_EQ_BANDS; i++) {
        atomic_store_explicit(&eq->words[W_FREQ(i)], f2u(p->bands[i].freqHz), memory_order_relaxed);
        atomic_store_explicit(&eq->words[W_GAIN(i)], f2u(p->bands[i].gainDb), memory_order_relaxed);
        atomic_store_explicit(&eq->words[W_Q(i)], f2u(p->bands[i].q), memory_order_relaxed);
        atomic_store_explicit(&eq->words[W_TYPE(i)], (uint32_t)p->types[i], memory_order_relaxed);
    }
    atomic_store_explicit(&eq->seq, s + 2, memory_order_release);
}

// Picks up new parameters if the writer is not mid-store and the set is new.
static void pick_up(DomineEQ *eq) {
    for (int tries = 0; tries < MAX_READ_TRIES; tries++) {
        const uint32_t s1 = atomic_load_explicit(&eq->seq, memory_order_acquire);
        if (s1 == eq->seenSeq) return;
        if (s1 & 1u) continue;
        uint32_t w[PARAM_WORDS];
        for (int i = 0; i < PARAM_WORDS; i++) w[i] = atomic_load_explicit(&eq->words[i], memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&eq->seq, memory_order_relaxed) != s1) continue;
        eq->seenSeq = s1;
        const int enabled = w[0] != 0;
        const uint32_t count = w[1];
        for (int i = 0; i < DOMINE_EQ_BANDS; i++) {
            Band *b = &eq->bands[i];
            double t[5] = { 1.0, 0.0, 0.0, 0.0, 0.0 };
            if (enabled && (uint32_t)i < count) {
                domine_eq_coefficients((int)w[W_TYPE(i)], eq->sampleRate, (double)u2f(w[W_FREQ(i)]),
                                       (double)u2f(w[W_GAIN(i)]), (double)u2f(w[W_Q(i)]), t);
            }
            for (int c = 0; c < 5; c++) {
                b->target[c] = t[c];
                b->step[c] = (t[c] - b->cur[c]) / (double)eq->smoothSamples;
            }
            b->identity = 0;
        }
        eq->rampLeft = eq->smoothSamples;
        eq->idle = 0;
        return;
    }
}

static void clear_state(DomineEQ *eq) {
    for (int i = 0; i < DOMINE_EQ_BANDS; i++) eq->bands[i].z1 = eq->bands[i].z2 = 0.0;
}

static int band_target_is_identity(const Band *b) {
    return b->target[0] == 1.0 && b->target[1] == 0.0 && b->target[2] == 0.0
        && b->target[3] == 0.0 && b->target[4] == 0.0;
}

int domine_eq_is_idle(const DomineEQ *eq) {
    return eq->idle && atomic_load_explicit(&eq->seq, memory_order_acquire) == eq->seenSeq;
}

void domine_eq_process(DomineEQ *eq, float *samples, uint32_t frames) {
    pick_up(eq);
    if (eq->idle) return;
    for (uint32_t n = 0; n < frames; n++) {
        const int ramping = eq->rampLeft > 0;
        double x = (double)samples[n];
        for (int i = 0; i < DOMINE_EQ_BANDS; i++) {
            Band *b = &eq->bands[i];
            if (b->identity) continue;
            if (ramping) {
                if (eq->rampLeft == 1) {
                    for (int c = 0; c < 5; c++) b->cur[c] = b->target[c];
                } else {
                    for (int c = 0; c < 5; c++) b->cur[c] += b->step[c];
                }
            }
            const double y = b->cur[0] * x + b->z1;
            b->z1 = b->cur[1] * x - b->cur[3] * y + b->z2;
            b->z2 = b->cur[2] * x - b->cur[4] * y;
            // Decayed far below audibility: zero both states together, so the
            // band never goes subnormal (slow on Intel) and no limit cycle
            // forms. Identity bands are skipped, so the flat path is untouched.
            if (fabs(b->z1) < DOMINE_EQ_FLUSH && fabs(b->z2) < DOMINE_EQ_FLUSH) b->z1 = b->z2 = 0.0;
            x = y;
        }
        const float out = (float)x;
        if (isfinite(out)) {
            samples[n] = out;
        } else { // NaN or inf never stays in the state
            clear_state(eq);
            samples[n] = 0.0f;
        }
        if (ramping && --eq->rampLeft == 0) {
            int allIdentity = 1;
            for (int i = 0; i < DOMINE_EQ_BANDS; i++) {
                Band *b = &eq->bands[i];
                if (band_target_is_identity(b)) {
                    b->identity = 1;
                    b->z1 = b->z2 = 0.0;
                } else {
                    allIdentity = 0;
                }
            }
            if (allIdentity) {
                eq->idle = 1;
                return;
            }
        }
    }
}
