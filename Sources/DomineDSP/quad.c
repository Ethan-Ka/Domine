#include "DomineQuad.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define NPOS DOMINE_QUAD_POSITIONS
#define RING_MIN_RATE 96000.0
#define GAIN_RAMP_S 0.03

typedef struct {
    float applied, start, target;
    uint32_t i, len;
    int init;
} GainState;

struct DomineQuad {
    double sampleRate;
    _Atomic uint32_t gainBits[NPOS];
    _Atomic uint32_t delaySamples[NPOS];
    _Atomic uint32_t rearMode;
    _Atomic uint32_t rearTrimBits;
    _Atomic uint32_t peakBits[NPOS];
    uint32_t maxDelay;

    // Render thread state.
    GainState gain[NPOS];
    float *ring[NPOS];
    uint32_t ringMask;
    uint32_t ringPos;
    DomineEQ *eq[NPOS];
    DomineBass *bass[NPOS];
    DomineCompressor *comp[NPOS];
};

typedef struct { float *data; uint32_t stride, frames; } OutCh;
typedef struct { const float *data; uint32_t stride, frames; } InCh;

static inline uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static inline float clamp01(float g) {
    if (!isfinite(g) || !(g > 0.0f)) return 0.0f;
    return g < 1.0f ? g : 1.0f;
}

static uint32_t next_pow2(uint32_t v) { uint32_t p = 1; while (p < v) p <<= 1; return p; }

DomineQuad *domine_quad_create(double sampleRate, uint32_t maxFrames) {
    (void)maxFrames;
    if (!(sampleRate > 0.0) || !isfinite(sampleRate)) return NULL;
    DomineQuad *q = calloc(1, sizeof *q);
    if (q == NULL) return NULL;
    q->sampleRate = sampleRate;
    double ringRate = sampleRate > RING_MIN_RATE ? sampleRate : RING_MIN_RATE;
    q->maxDelay = (uint32_t)ceil(ringRate * DOMINE_MAX_DELAY_MS / 1000.0);
    uint32_t size = next_pow2(q->maxDelay + 1);
    q->ringMask = size - 1;
    for (int i = 0; i < NPOS; i++) {
        q->ring[i] = calloc(size, sizeof(float));
        q->eq[i] = domine_eq_create(sampleRate);
        q->bass[i] = domine_bass_create(sampleRate);
        q->comp[i] = domine_compressor_create(sampleRate);
        atomic_init(&q->gainBits[i], f2u(1.0f));
        atomic_init(&q->delaySamples[i], 0);
        atomic_init(&q->peakBits[i], 0);
    }
    atomic_init(&q->rearMode, DOMINE_REAR_MIRROR);
    atomic_init(&q->rearTrimBits, f2u(1.0f));
    for (int i = 0; i < NPOS; i++) {
        if (!q->ring[i] || !q->eq[i] || !q->bass[i] || !q->comp[i]) {
            domine_quad_destroy(q);
            return NULL;
        }
    }
    return q;
}

void domine_quad_destroy(DomineQuad *q) {
    if (q == NULL) return;
    for (int i = 0; i < NPOS; i++) {
        free(q->ring[i]);
        if (q->eq[i]) domine_eq_destroy(q->eq[i]);
        if (q->bass[i]) domine_bass_destroy(q->bass[i]);
        if (q->comp[i]) domine_compressor_destroy(q->comp[i]);
    }
    free(q);
}

void domine_quad_set_gain(DomineQuad *q, int pos, float gain) {
    if (pos < 0 || pos >= NPOS) return;
    atomic_store_explicit(&q->gainBits[pos], f2u(clamp01(gain)), memory_order_relaxed);
}

void domine_quad_set_delay_ms(DomineQuad *q, int pos, float ms) {
    if (pos < 0 || pos >= NPOS) return;
    if (!isfinite(ms) || ms < 0.0f) ms = 0.0f;
    if (ms > DOMINE_MAX_DELAY_MS) ms = DOMINE_MAX_DELAY_MS;
    uint32_t n = (uint32_t)llround((double)ms * q->sampleRate / 1000.0);
    if (n > q->maxDelay) n = q->maxDelay;
    atomic_store_explicit(&q->delaySamples[pos], n, memory_order_relaxed);
}

void domine_quad_set_rear_mode(DomineQuad *q, int mode) {
    uint32_t m = mode == DOMINE_REAR_MATRIX ? DOMINE_REAR_MATRIX
               : mode == DOMINE_REAR_DIRECT ? DOMINE_REAR_DIRECT : DOMINE_REAR_MIRROR;
    atomic_store_explicit(&q->rearMode, m, memory_order_relaxed);
}

void domine_quad_set_rear_trim(DomineQuad *q, float gain) {
    atomic_store_explicit(&q->rearTrimBits, f2u(clamp01(gain)), memory_order_relaxed);
}

void domine_quad_set_eq(DomineQuad *q, int pos, const DomineEQParams *p) {
    if (pos >= 0 && pos < NPOS) domine_eq_set_params(q->eq[pos], p);
}
void domine_quad_set_bass(DomineQuad *q, int pos, const DomineBassParams *p) {
    if (pos >= 0 && pos < NPOS) domine_bass_set_params(q->bass[pos], p);
}
void domine_quad_set_compressor(DomineQuad *q, int pos, const DomineCompressorParams *p) {
    if (pos >= 0 && pos < NPOS) domine_compressor_set_params(q->comp[pos], p);
}

float domine_quad_peak(DomineQuad *q, int pos) {
    if (pos < 0 || pos >= NPOS) return 0.0f;
    return u2f(atomic_load_explicit(&q->peakBits[pos], memory_order_relaxed));
}

static InCh in_channel(const AudioBuffer *b, uint32_t ch) {
    InCh c = { NULL, 1, 0 };
    if (b->mData == NULL || b->mNumberChannels == 0 || ch >= b->mNumberChannels) return c;
    c.data = (const float *)b->mData + ch;
    c.stride = b->mNumberChannels;
    c.frames = b->mDataByteSize / (uint32_t)(sizeof(float) * b->mNumberChannels);
    return c;
}

static inline float read_in(const InCh *c, uint32_t f) {
    return (c->data != NULL && f < c->frames) ? c->data[(size_t)f * c->stride] : 0.0f;
}

static int map_out(AudioBufferList *abl, uint32_t flat, OutCh *o) {
    if (flat == DOMINE_NO_DEVICE) return 0;
    uint32_t base = 0;
    for (uint32_t b = 0; b < abl->mNumberBuffers; b++) {
        AudioBuffer *buf = &abl->mBuffers[b];
        uint32_t n = buf->mNumberChannels;
        if (n == 0) continue;
        if (flat < base + n) {
            if (buf->mData == NULL) return 0;
            o->data = (float *)buf->mData + (flat - base);
            o->stride = n;
            o->frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * n);
            return 1;
        }
        base += n;
    }
    return 0;
}

void domine_quad_process(DomineQuad *q, const AudioBufferList *in, AudioBufferList *out,
                         uint32_t frames, const uint32_t *out_offsets) {
    if (q == NULL || out == NULL || out_offsets == NULL) return;

    for (uint32_t b = 0; b < out->mNumberBuffers; b++) {
        if (out->mBuffers[b].mData != NULL) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    }

    InCh inL = { NULL, 1, 0 }, inR = inL;
    if (in != NULL && in->mNumberBuffers > 0) {
        const AudioBuffer *b0 = &in->mBuffers[0];
        if (b0->mNumberChannels >= 2) { inL = in_channel(b0, 0); inR = in_channel(b0, 1); }
        else if (in->mNumberBuffers >= 2) { inL = in_channel(b0, 0); inR = in_channel(&in->mBuffers[1], 0); }
        else { inL = in_channel(b0, 0); inR = inL; }
    }

    // Presence for folding follows the offsets; writing follows the buffers.
    OutCh oc[NPOS][2];
    int has[NPOS], count = 0;
    for (int p = 0; p < NPOS; p++) {
        has[p] = out_offsets[p] != DOMINE_NO_DEVICE;
        count += has[p];
        int a = map_out(out, out_offsets[p], &oc[p][0]);
        int b = has[p] && out_offsets[p] != UINT32_MAX - 1 && map_out(out, out_offsets[p] + 1, &oc[p][1]);
        if (!a) oc[p][0].data = NULL;
        if (!b) oc[p][1].data = NULL;
    }

    const uint32_t mode = atomic_load_explicit(&q->rearMode, memory_order_relaxed);
    const float trim = u2f(atomic_load_explicit(&q->rearTrimBits, memory_order_relaxed));
    uint32_t delay[NPOS];
    for (int p = 0; p < NPOS; p++) {
        float target = u2f(atomic_load_explicit(&q->gainBits[p], memory_order_relaxed));
        GainState *g = &q->gain[p];
        if (!g->init) {
            g->init = 1; g->applied = g->start = g->target = target; g->i = g->len = 0;
        } else if (target != g->target) {
            g->start = g->applied;
            g->target = target;
            g->i = 0;
            g->len = (uint32_t)llround(GAIN_RAMP_S * q->sampleRate);
            if (g->len == 0) g->applied = target;
        }
        delay[p] = atomic_load_explicit(&q->delaySamples[p], memory_order_relaxed);
    }

    float peak[NPOS] = { 0, 0, 0, 0 };
    for (uint32_t f = 0; f < frames; f++) {
        const float L = read_in(&inL, f), R = read_in(&inR, f);
        float rl = L, rr = R;
        if (mode == DOMINE_REAR_MATRIX) {
            rl = DOMINE_REAR_MATRIX_K * (L - 0.5f * R);
            rr = DOMINE_REAR_MATRIX_K * (R - 0.5f * L);
        }
        rl *= trim;
        rr *= trim;

        float src[NPOS] = { L, R, rl, rr };
        if (count == 1) {
            const float mono = 0.5f * (L + R);
            for (int p = 0; p < NPOS; p++) src[p] = mono;
        } else {
            if (has[0] != has[1]) src[0] = src[1] = 0.5f * (L + R);
            if (has[2] != has[3]) src[2] = src[3] = 0.5f * (rl + rr);
        }

        for (int p = 0; p < NPOS; p++) {
            float s = src[p];
            if (!domine_eq_is_idle(q->eq[p])) domine_eq_process(q->eq[p], &s, 1);
            if (!domine_bass_is_idle(q->bass[p])) domine_bass_process(q->bass[p], &s, 1);
            if (!domine_compressor_is_idle(q->comp[p])) domine_compressor_process(q->comp[p], &s, 1);

            GainState *g = &q->gain[p];
            if (g->i < g->len) {
                g->i++;
                g->applied = g->i == g->len ? g->target
                    : g->start + (g->target - g->start) * (float)g->i / (float)g->len;
            }
            if (g->applied != 1.0f) s *= g->applied;

            q->ring[p][q->ringPos & q->ringMask] = s;
            const float o = delay[p] > 0 ? q->ring[p][(q->ringPos - delay[p]) & q->ringMask] : s;
            if (has[p]) {
                const float a = fabsf(o);
                if (a > peak[p]) peak[p] = a;
                for (int c = 0; c < 2; c++) {
                    const OutCh *ch = &oc[p][c];
                    if (ch->data != NULL && f < ch->frames) ch->data[(size_t)f * ch->stride] = o;
                }
            }
        }
        q->ringPos++;
    }
    for (int p = 0; p < NPOS; p++) {
        atomic_store_explicit(&q->peakBits[p], f2u(peak[p]), memory_order_relaxed);
    }
}
