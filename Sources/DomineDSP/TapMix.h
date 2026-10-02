// Multi-tap input mixer shared by the stereo and quad kernels (private header).
// Real-time rules apply: no allocation, no locks. The layout crosses threads
// through a seqlock over atomic words, gains through atomics.
#ifndef DOMINE_TAPMIX_H
#define DOMINE_TAPMIX_H

#include <CoreAudio/CoreAudioTypes.h>
#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#define TAP_MAX 8
#define TAP_RAMP_S 0.02

typedef struct { const float *data; uint32_t stride, frames; } TapIn;

typedef struct {
    uint32_t n;
    TapIn l[TAP_MAX], r[TAP_MAX];
} TapSet;

typedef struct {
    // Control side (any thread).
    _Atomic uint32_t seq;
    _Atomic uint32_t count;
    _Atomic uint32_t first[TAP_MAX], channels[TAP_MAX], interleaved[TAP_MAX];
    _Atomic uint32_t gainBits[TAP_MAX];
    // Render side.
    uint32_t n;
    uint32_t rfirst[TAP_MAX], rch[TAP_MAX], rint[TAP_MAX];
    float start[TAP_MAX], target[TAP_MAX], cur[TAP_MAX];
    uint32_t pos[TAP_MAX], rampLen;
    uint8_t primed[TAP_MAX];
} TapMixer;

static inline uint32_t tap_f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float tap_u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static inline void tapmix_init(TapMixer *m, double sampleRate) {
    memset(m, 0, sizeof *m);
    const uint32_t ramp = (uint32_t)llround(TAP_RAMP_S * sampleRate);
    m->rampLen = ramp > 0 ? ramp : 1;
    for (int i = 0; i < TAP_MAX; i++) atomic_init(&m->gainBits[i], tap_f2u(1.0f));
}

static inline void tapmix_set_layout(TapMixer *m, uint32_t count, const uint32_t *first,
                                     const uint32_t *channels, const uint32_t *interleaved) {
    if (count > TAP_MAX) count = TAP_MAX;
    if (count > 0 && (first == NULL || channels == NULL || interleaved == NULL)) return;
    const uint32_t s = atomic_load_explicit(&m->seq, memory_order_relaxed);
    atomic_store_explicit(&m->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&m->count, count, memory_order_relaxed);
    for (uint32_t i = 0; i < count; i++) {
        atomic_store_explicit(&m->first[i], first[i], memory_order_relaxed);
        atomic_store_explicit(&m->channels[i], channels[i], memory_order_relaxed);
        atomic_store_explicit(&m->interleaved[i], interleaved[i] != 0, memory_order_relaxed);
    }
    atomic_store_explicit(&m->seq, s + 2, memory_order_release);
}

static inline void tapmix_set_gain(TapMixer *m, uint32_t tap, float gain) {
    if (tap >= TAP_MAX) return;
    if (!isfinite(gain) || !(gain > 0.0f)) gain = 0.0f;
    if (gain > 1.0f) gain = 1.0f;
    atomic_store_explicit(&m->gainBits[tap], tap_f2u(gain), memory_order_relaxed);
}

// Render thread, once per cycle: picks up the layout (keeps the previous one
// if a write is in progress) and starts gain ramps. Returns 1 when taps are in use.
static inline int tapmix_begin(TapMixer *m) {
    for (int attempt = 0; attempt < 4; attempt++) {
        const uint32_t a = atomic_load_explicit(&m->seq, memory_order_acquire);
        if (a & 1u) continue;
        uint32_t n = atomic_load_explicit(&m->count, memory_order_relaxed);
        if (n > TAP_MAX) n = TAP_MAX;
        uint32_t f[TAP_MAX], c[TAP_MAX], il[TAP_MAX];
        for (uint32_t i = 0; i < n; i++) {
            f[i] = atomic_load_explicit(&m->first[i], memory_order_relaxed);
            c[i] = atomic_load_explicit(&m->channels[i], memory_order_relaxed);
            il[i] = atomic_load_explicit(&m->interleaved[i], memory_order_relaxed);
        }
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&m->seq, memory_order_relaxed) != a) continue;
        m->n = n;
        for (uint32_t i = 0; i < n; i++) { m->rfirst[i] = f[i]; m->rch[i] = c[i]; m->rint[i] = il[i]; }
        break;
    }
    for (uint32_t t = 0; t < m->n; t++) {
        const float g = tap_u2f(atomic_load_explicit(&m->gainBits[t], memory_order_relaxed));
        if (!m->primed[t]) {
            m->primed[t] = 1;
            m->cur[t] = m->start[t] = m->target[t] = g;
            m->pos[t] = 0;
            continue;
        }
        if (g != m->target[t]) {
            m->start[t] = m->cur[t];
            m->target[t] = g;
            m->pos[t] = 0;
        }
    }
    return m->n > 0;
}

static inline TapIn tap_channel(const AudioBuffer *b, uint32_t ch) {
    TapIn c = { NULL, 1, 0 };
    if (b->mData == NULL || b->mNumberChannels == 0 || ch >= b->mNumberChannels) return c;
    c.data = (const float *)b->mData + ch;
    c.stride = b->mNumberChannels;
    c.frames = b->mDataByteSize / (uint32_t)(sizeof(float) * b->mNumberChannels);
    return c;
}

// Resolves each tap in `list` to a stereo pair. Returns the largest frame
// count any tap holds (0 when every tap is missing); *missing is set to 1
// when no tap has data.
static inline uint32_t tapmix_resolve(const TapMixer *m, const AudioBufferList *list,
                                      TapSet *set, int *missing) {
    const TapIn none = { NULL, 1, 0 };
    set->n = m->n;
    uint32_t maxFrames = 0;
    int any = 0;
    const uint32_t count = list != NULL ? list->mNumberBuffers : 0;
    for (uint32_t t = 0; t < m->n; t++) {
        set->l[t] = set->r[t] = none;
        const uint32_t first = m->rfirst[t];
        if (first >= count) continue;
        const AudioBuffer *b0 = &list->mBuffers[first];
        TapIn l = tap_channel(b0, 0), r = l;
        if (b0->mNumberChannels >= 2) {
            r = tap_channel(b0, 1);
        } else if (m->rch[t] >= 2 && !m->rint[t] && first + 1 < count) {
            r = tap_channel(&list->mBuffers[first + 1], 0);
        }
        set->l[t] = l;
        set->r[t] = r;
        if (l.data == NULL) continue;
        any = 1;
        uint32_t fr = l.frames;
        if (r.data != NULL && r.frames < fr) fr = r.frames;
        if (fr > maxFrames) maxFrames = fr;
    }
    if (missing != NULL) *missing = !any;
    return maxFrames;
}

static inline float tap_read(const TapIn *c, uint32_t f) {
    return (c->data != NULL && f < c->frames) ? c->data[(size_t)f * c->stride] : 0.0f;
}

// Mixes input frame f of every tap. Call once per input frame, in order.
static inline void tapmix_read(TapMixer *m, const TapSet *s, uint32_t f, float *outL, float *outR) {
    float l = 0.0f, r = 0.0f;
    for (uint32_t t = 0; t < s->n; t++) {
        if (m->pos[t] < m->rampLen && m->target[t] != m->cur[t]) {
            m->pos[t]++;
            m->cur[t] = m->pos[t] == m->rampLen ? m->target[t]
                : m->start[t] + (m->target[t] - m->start[t]) * (float)m->pos[t] / (float)m->rampLen;
        }
        const float g = m->cur[t];
        float a = tap_read(&s->l[t], f), b = tap_read(&s->r[t], f);
        if (g != 1.0f) { a *= g; b *= g; }
        if (t == 0) { l = a; r = b; } else { l += a; r += b; }
    }
    *outL = l;
    *outR = r;
}

#endif
