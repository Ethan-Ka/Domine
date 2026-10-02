#include "DomineSpatial.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define NSTAGES 3
#define PARAM_WORDS 3
#define SMOOTH_S 0.010
#define MAX_ROOM_MS 30.0f
#define SHELF_K 0.6f          // about -4.4 dB above the corner
#define AMB_GAIN 1.41421356f  // sqrt(2): side has half the power of L or R
#define AP_G 0.5f
#define RIGHT_DELAY_RATIO 1.13f

typedef struct { float *buf; uint32_t len, pos; } Allpass;

struct DomineSpatial {
    double sampleRate;
    _Atomic uint32_t seq;
    _Atomic uint32_t words[PARAM_WORDS];

    // Render thread state.
    uint32_t seenSeq;
    double amountTarget, roomTarget;
    float lpCoef;
    double amount, roomMs; // double so smoothing reaches the target exactly
    float lpL, lpR;
    double smoothCoef;
    float *ring;
    uint32_t ringMask, ringPos;
    Allpass ap[2][NSTAGES];
    float *apMem;
};

static inline uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static float clampf(float v, float lo, float hi, float dflt) {
    if (!isfinite(v)) return dflt;
    return v < lo ? lo : (v > hi ? hi : v);
}

static void sanitize(const DomineSpatialParams *p, float w[PARAM_WORDS]) {
    w[0] = clampf(p->amount, 0.0f, 1.0f, 0.0f);
    w[1] = clampf(p->roomMs, 5.0f, MAX_ROOM_MS, 15.0f);
    w[2] = clampf(p->highCutHz, 1000.0f, 16000.0f, 5000.0f);
}

static uint32_t next_pow2(uint32_t v) { uint32_t p = 1; while (p < v) p <<= 1; return p; }

static float lp_coef(double sr, float hz) {
    return (float)(1.0 - exp(-2.0 * M_PI * (double)hz / sr));
}

DomineSpatial *domine_spatial_create(double sampleRate) {
    if (!(sampleRate > 0.0) || !isfinite(sampleRate)) return NULL;
    DomineSpatial *s = calloc(1, sizeof *s);
    if (s == NULL) return NULL;
    s->sampleRate = sampleRate;
    s->smoothCoef = 1.0 - exp(-1.0 / (SMOOTH_S * sampleRate));
    // Longest read: 30 ms times 1.13, plus interpolation margin.
    uint32_t ringLen = next_pow2((uint32_t)ceil(sampleRate * MAX_ROOM_MS * RIGHT_DELAY_RATIO / 1000.0) + 4);
    s->ring = calloc(ringLen, sizeof(float));
    s->ringMask = ringLen - 1;
    static const uint32_t base[2][NSTAGES] = { { 142, 107, 379 }, { 113, 211, 337 } }; // at 48 kHz
    uint32_t total = 0, lens[2][NSTAGES];
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < NSTAGES; i++) {
            uint32_t n = (uint32_t)lround(base[c][i] * sampleRate / 48000.0);
            lens[c][i] = n > 1 ? n : 1;
            total += lens[c][i];
        }
    s->apMem = calloc(total, sizeof(float));
    if (s->ring == NULL || s->apMem == NULL) { domine_spatial_destroy(s); return NULL; }
    float *m = s->apMem;
    for (int c = 0; c < 2; c++)
        for (int i = 0; i < NSTAGES; i++) { s->ap[c][i].buf = m; s->ap[c][i].len = lens[c][i]; m += lens[c][i]; }

    DomineSpatialParams d = { 0.0f, 15.0f, 5000.0f };
    float w[PARAM_WORDS];
    sanitize(&d, w);
    atomic_init(&s->seq, 0);
    for (int i = 0; i < PARAM_WORDS; i++) atomic_init(&s->words[i], f2u(w[i]));
    s->amountTarget = s->amount = w[0];
    s->roomTarget = s->roomMs = w[1];
    s->lpCoef = lp_coef(sampleRate, w[2]);
    return s;
}

void domine_spatial_destroy(DomineSpatial *s) {
    if (s == NULL) return;
    free(s->ring);
    free(s->apMem);
    free(s);
}

void domine_spatial_set_params(DomineSpatial *s, const DomineSpatialParams *p) {
    if (s == NULL || p == NULL) return;
    float w[PARAM_WORDS];
    sanitize(p, w);
    const uint32_t q = atomic_load_explicit(&s->seq, memory_order_relaxed);
    atomic_store_explicit(&s->seq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    for (int i = 0; i < PARAM_WORDS; i++) atomic_store_explicit(&s->words[i], f2u(w[i]), memory_order_relaxed);
    atomic_store_explicit(&s->seq, q + 2, memory_order_release);
}

// Reads a consistent set if one is available; otherwise keeps the old targets.
static void pickup(DomineSpatial *s) {
    for (int tries = 0; tries < 4; tries++) {
        const uint32_t s1 = atomic_load_explicit(&s->seq, memory_order_acquire);
        if (s1 == s->seenSeq) return;
        if (s1 & 1u) continue;
        float w[PARAM_WORDS];
        for (int i = 0; i < PARAM_WORDS; i++) w[i] = u2f(atomic_load_explicit(&s->words[i], memory_order_relaxed));
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&s->seq, memory_order_relaxed) != s1) continue;
        s->seenSeq = s1;
        s->amountTarget = w[0];
        s->roomTarget = w[1];
        s->lpCoef = lp_coef(s->sampleRate, w[2]);
        return;
    }
}

static inline float allpass(Allpass *a, float x) {
    const float d = a->buf[a->pos];
    const float v = x + AP_G * d;
    a->buf[a->pos] = v;
    if (++a->pos == a->len) a->pos = 0;
    return d - AP_G * v;
}

static inline float clamp1(float v) { return v > 1.0f ? 1.0f : (v < -1.0f ? -1.0f : v); }

static inline float read_delay(const DomineSpatial *s, float delay) {
    const uint32_t whole = (uint32_t)delay;
    const float frac = delay - (float)whole;
    const float a = s->ring[(s->ringPos - whole) & s->ringMask];
    const float b = s->ring[(s->ringPos - whole - 1) & s->ringMask];
    return a + frac * (b - a);
}

static inline void frame(DomineSpatial *s, float l, float r, float *rl, float *rr) {
    const double c = s->smoothCoef;
    s->amount += c * (s->amountTarget - s->amount);
    if (fabs(s->amountTarget - s->amount) < 1e-9) s->amount = s->amountTarget;
    s->roomMs += c * (s->roomTarget - s->roomMs);
    if (fabs(s->roomTarget - s->roomMs) < 1e-6) s->roomMs = s->roomTarget;

    // Ambience path always runs so its state is warm when amount rises.
    const float side = 0.5f * (l - r);
    s->ringPos++;
    s->ring[s->ringPos & s->ringMask] = side;
    const float samplesPerMs = (float)(s->sampleRate / 1000.0);
    float a = read_delay(s, (float)s->roomMs * samplesPerMs);
    float b = read_delay(s, (float)s->roomMs * RIGHT_DELAY_RATIO * samplesPerMs);
    for (int i = 0; i < NSTAGES; i++) { a = allpass(&s->ap[0][i], a); b = allpass(&s->ap[1][i], b); }
    b = -b;
    s->lpL += s->lpCoef * (a - s->lpL);
    s->lpR += s->lpCoef * (b - s->lpR);
    const float ambL = clamp1(AMB_GAIN * (s->lpL + SHELF_K * (a - s->lpL)));
    const float ambR = clamp1(AMB_GAIN * (s->lpR + SHELF_K * (b - s->lpR)));

    if (s->amount == 0.0f) { *rl = l; *rr = r; return; }
    const float w = (float)s->amount, m = 1.0f - w;
    *rl = m * l + w * ambL;
    *rr = m * r + w * ambR;
}

void domine_spatial_tick(DomineSpatial *s, float l, float r, float *rl, float *rr) {
    pickup(s);
    frame(s, l, r, rl, rr);
}

void domine_spatial_process(DomineSpatial *s, const float *l, const float *r,
                            float *rl, float *rr, uint32_t frames) {
    if (s == NULL) return;
    pickup(s);
    for (uint32_t i = 0; i < frames; i++) frame(s, l[i], r[i], &rl[i], &rr[i]);
}

int domine_spatial_is_idle(const DomineSpatial *s) {
    return s->amount == 0.0f && s->amountTarget == 0.0f;
}
