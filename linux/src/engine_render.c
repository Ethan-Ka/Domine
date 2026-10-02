// Domine for Linux: render path between the capture stream, the surround
// kernel and the per-speaker rings. See engine_render.h.
#include "engine_render.h"
#include "DomineChime.h"
#include "DomineDSP.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static uint32_t next_pow2(uint32_t v) {
    uint32_t p = 1;
    while (p < v && p < (1u << 30)) p <<= 1;
    return p;
}

static float clamp01(float v) {
    if (!isfinite(v) || v < 0.0f) return 0.0f;
    return v > 1.0f ? 1.0f : v;
}

float dl_click_sample(uint32_t n, double sampleRate) {
    const uint32_t len = (uint32_t)llround(DOMINE_CLICK_MS / 1000.0 * sampleRate);
    if (n >= len || len == 0) return 0.0f;
    const double w = 0.5 - 0.5 * cos(2.0 * M_PI * n / len);
    return (float)(DOMINE_CLICK_AMPLITUDE * w * sin(2.0 * M_PI * DOMINE_CLICK_HZ * n / sampleRate));
}

DLRender *dl_render_create(double sampleRate, uint32_t count, uint32_t maxFrames,
                           uint32_t ringFrames, uint32_t target, uint32_t high) {
    if (count == 0 || count > DL_MAX_SPEAKERS || maxFrames == 0 || !(sampleRate > 0)) return NULL;
    DLRender *r = calloc(1, sizeof *r);
    if (r == NULL) return NULL;
    r->rate = sampleRate;
    r->count = count;
    r->maxFrames = maxFrames;
    const uint32_t cap = next_pow2(ringFrames < 2 * maxFrames ? 2 * maxFrames : ringFrames);
    if (high >= cap) high = cap - 1;
    if (target > high) target = high;
    r->target = target;
    r->high = high;
    pthread_mutex_init(&r->lock, NULL);
    r->scratch = calloc((size_t)2 * count * maxFrames, sizeof(float));
    r->pair = calloc((size_t)2 * maxFrames, sizeof(float));
    r->ringData = calloc((size_t)2 * count * cap, sizeof(float));
    r->kernel = domine_surround_create(sampleRate, maxFrames);
    if (r->scratch == NULL || r->pair == NULL || r->ringData == NULL || r->kernel == NULL) {
        dl_render_destroy(r);
        return NULL;
    }
    for (uint32_t i = 0; i < count; i++) {
        dl_ring_init(&r->rings[i], r->ringData + (size_t)2 * cap * i, cap);
    }
    for (uint32_t i = 0; i < DL_MAX_SPEAKERS; i++) {
        atomic_init(&r->present[i], 0);
        atomic_init(&r->gainBits[i], f2u(1.0f));
        atomic_init(&r->delayFrames[i], 0);
        atomic_init(&r->peakBits[i], 0);
        atomic_init(&r->underruns[i], 0);
        atomic_init(&r->drops[i], 0);
        atomic_init(&r->overflows[i], 0);
        r->speakers[i].distance = 1.0f;
        r->speakers[i].trim = 1.0f;
    }
    atomic_init(&r->mono, DL_NO_SPEAKER);
    atomic_init(&r->toneReq, -1);
    atomic_init(&r->clickReq, 0);
    r->master = 1.0f;
    r->appliedMono = DL_NO_SPEAKER;
    r->fadeLen = (uint32_t)llround(DOMINE_TONE_FADE_MS / 1000.0 * sampleRate);
    if (r->fadeLen == 0) r->fadeLen = 1;
    r->toneCur = -1;
    r->clickPeriod = (uint32_t)llround(DOMINE_CLICK_PERIOD_MS / 1000.0 * sampleRate);
    r->clickLen = (uint32_t)llround(DOMINE_CLICK_MS / 1000.0 * sampleRate);
    return r;
}

void dl_render_destroy(DLRender *r) {
    if (r == NULL) return;
    domine_surround_destroy(r->kernel);
    free(r->scratch);
    free(r->pair);
    free(r->ringData);
    pthread_mutex_destroy(&r->lock);
    free(r);
}

// Pushes the stored control state into the kernel. Called with r->lock held.
static void apply_locked(DLRender *r) {
    const uint32_t n = r->count;
    uint32_t presentCount = 0, last = DL_NO_SPEAKER;
    float az[DL_MAX_SPEAKERS], dist[DL_MAX_SPEAKERS], delayMs[DL_MAX_SPEAKERS], distGain[DL_MAX_SPEAKERS];
    for (uint32_t i = 0; i < n; i++) {
        if (atomic_load_explicit(&r->present[i], memory_order_relaxed)) { presentCount++; last = i; }
        az[i] = r->speakers[i].azimuth;
        dist[i] = r->speakers[i].distance;
    }
    const uint32_t mono = (n >= 2 && presentCount == 1) ? last : DL_NO_SPEAKER;
    domine_surround_distance_comp(n, dist, delayMs, distGain);

    float gain[DL_MAX_SPEAKERS], delay[DL_MAX_SPEAKERS];
    for (uint32_t i = 0; i < n; i++) {
        gain[i] = clamp01(r->speakers[i].trim) * distGain[i] * r->master;
        float d = delayMs[i] + r->manualDelayMs[i];
        if (!(d > 0.0f)) d = 0.0f;
        if (d > DOMINE_MAX_DELAY_MS) d = DOMINE_MAX_DELAY_MS;
        delay[i] = d;
        atomic_store_explicit(&r->gainBits[i], f2u(gain[i]), memory_order_relaxed);
        atomic_store_explicit(&r->delayFrames[i], (uint32_t)llround(d / 1000.0 * r->rate), memory_order_relaxed);
    }

    // Kernel slot k plays speaker map[k].
    uint32_t slots = n, map[DL_MAX_SPEAKERS];
    for (uint32_t i = 0; i < n; i++) map[i] = i;
    if (mono != DL_NO_SPEAKER) { slots = 1; map[0] = mono; }
    float slotAz[DL_MAX_SPEAKERS];
    for (uint32_t k = 0; k < slots; k++) slotAz[k] = az[map[k]];
    domine_surround_set_speakers(r->kernel, slots, slotAz);
    const DomineEQParams eqOff = domine_eq_default_params();
    const DomineBassParams bassOff = { 0, 0.0f, 120.0f };
    const DomineCompressorParams compOff = { 0, -18.0f, 3.0f, 10.0f, 100.0f, 0.0f, -1.0f };
    const int remapped = mono != r->appliedMono;
    for (uint32_t k = 0; k < slots; k++) {
        const uint32_t s = map[k];
        domine_surround_set_gain(r->kernel, k, gain[s]);
        domine_surround_set_delay_ms(r->kernel, k, delay[s]);
        if (r->hasEq[s] || remapped) domine_surround_set_eq(r->kernel, k, r->hasEq[s] ? &r->eq[s] : &eqOff);
        if (r->hasBass[s] || remapped) domine_surround_set_bass(r->kernel, k, r->hasBass[s] ? &r->bass[s] : &bassOff);
        if (r->hasComp[s] || remapped) domine_surround_set_compressor(r->kernel, k, r->hasComp[s] ? &r->comp[s] : &compOff);
    }
    r->appliedMono = mono;
    atomic_store_explicit(&r->mono, mono, memory_order_release);
}

void dl_render_configure(DLRender *r, const DLSpeaker *speakers, uint32_t count, float master) {
    if (r == NULL || speakers == NULL) return;
    pthread_mutex_lock(&r->lock);
    for (uint32_t i = 0; i < r->count && i < count; i++) r->speakers[i] = speakers[i];
    r->master = clamp01(master);
    apply_locked(r);
    pthread_mutex_unlock(&r->lock);
}

void dl_render_set_master(DLRender *r, float master) {
    if (r == NULL) return;
    pthread_mutex_lock(&r->lock);
    r->master = clamp01(master);
    apply_locked(r);
    pthread_mutex_unlock(&r->lock);
}

void dl_render_set_manual_delay(DLRender *r, uint32_t speaker, float ms) {
    if (r == NULL || speaker >= r->count) return;
    if (!isfinite(ms) || ms < 0.0f) ms = 0.0f;
    if (ms > DOMINE_MAX_DELAY_MS) ms = DOMINE_MAX_DELAY_MS;
    pthread_mutex_lock(&r->lock);
    r->manualDelayMs[speaker] = ms;
    apply_locked(r);
    pthread_mutex_unlock(&r->lock);
}

#define SET_EFFECT(field, flag)                                   \
    if (r == NULL || speaker >= r->count || p == NULL) return;   \
    pthread_mutex_lock(&r->lock);                                 \
    r->field[speaker] = *p;                                       \
    r->flag[speaker] = 1;                                         \
    apply_locked(r);                                              \
    pthread_mutex_unlock(&r->lock);

void dl_render_set_eq(DLRender *r, uint32_t speaker, const DomineEQParams *p) { SET_EFFECT(eq, hasEq) }
void dl_render_set_bass(DLRender *r, uint32_t speaker, const DomineBassParams *p) { SET_EFFECT(bass, hasBass) }
void dl_render_set_compressor(DLRender *r, uint32_t speaker, const DomineCompressorParams *p) { SET_EFFECT(comp, hasComp) }

void dl_render_set_present(DLRender *r, uint32_t speaker, int present) {
    if (r == NULL || speaker >= r->count) return;
    pthread_mutex_lock(&r->lock);
    atomic_store_explicit(&r->present[speaker], present ? 1u : 0u, memory_order_release);
    apply_locked(r);
    pthread_mutex_unlock(&r->lock);
}

void dl_render_set_test_tone(DLRender *r, int speaker) {
    if (r == NULL) return;
    if (speaker < 0 || (uint32_t)speaker >= r->count) speaker = -1;
    atomic_store_explicit(&r->toneReq, speaker, memory_order_relaxed);
}

void dl_render_set_click_test(DLRender *r, int on) {
    if (r == NULL) return;
    atomic_store_explicit(&r->clickReq, on == 1 ? 1u : 0u, memory_order_relaxed);
}

float dl_render_peak(DLRender *r, uint32_t speaker) {
    if (r == NULL || speaker >= r->count) return 0.0f;
    return u2f(atomic_load_explicit(&r->peakBits[speaker], memory_order_relaxed));
}

// Click test and test tone over one chunk of kernel output (capture thread).
static void post_process(DLRender *r, uint32_t frames, const uint32_t *present) {
    const uint32_t n = r->count, stride = 2 * n, L = r->fadeLen;
    const int32_t treq = atomic_load_explicit(&r->toneReq, memory_order_relaxed);
    const uint32_t creq = atomic_load_explicit(&r->clickReq, memory_order_relaxed);
    if (r->toneP == 0 && treq < 0 && r->toneCur < 0 && r->clickC == 0 && !creq) return;
    float gain[DL_MAX_SPEAKERS];
    uint32_t delay[DL_MAX_SPEAKERS];
    for (uint32_t s = 0; s < n; s++) {
        gain[s] = u2f(atomic_load_explicit(&r->gainBits[s], memory_order_relaxed));
        delay[s] = atomic_load_explicit(&r->delayFrames[s], memory_order_relaxed) % r->clickPeriod;
    }
    const double period = DOMINE_CHIME_PERIOD_S;
    for (uint32_t f = 0; f < frames; f++) {
        float *frame = r->scratch + (size_t)stride * f;
        // Click test.
        if (r->clickC > 0 || creq) {
            const float e = (float)r->clickC / (float)L;
            const int emit = creq && r->clickC == L;
            for (uint32_t s = 0; s < n; s++) {
                if (!present[s]) continue;
                float c = 0.0f;
                if (emit) {
                    const uint32_t m = (r->clickN + r->clickPeriod - delay[s]) % r->clickPeriod;
                    c = dl_click_sample(m, r->rate) * gain[s];
                }
                frame[2 * s] = frame[2 * s] * (1.0f - e) + c;
                frame[2 * s + 1] = frame[2 * s + 1] * (1.0f - e) + c;
            }
            if (emit) r->clickN = (r->clickN + 1) % r->clickPeriod;
            if (creq) { if (r->clickC < L) r->clickC++; }
            else { r->clickN = 0; if (r->clickC > 0) r->clickC--; }
        } else {
            r->clickN = 0;
        }
        // Test tone.
        if (r->toneP == 0 && r->toneCur != treq) { r->toneCur = treq; r->toneT = 0; }
        if (r->toneP > 0 || r->toneCur >= 0) {
            const float e = (float)r->toneP / (float)L;
            float tone = 0.0f;
            if (r->toneCur >= 0) tone = (float)domine_chime_sample(fmod((double)r->toneT / r->rate, period));
            for (uint32_t s = 0; s < n; s++) {
                const float t = (int32_t)s == r->toneCur ? tone * e : 0.0f;
                frame[2 * s] = frame[2 * s] * (1.0f - e) + t;
                frame[2 * s + 1] = frame[2 * s + 1] * (1.0f - e) + t;
            }
            const uint32_t goal = (r->toneCur >= 0 && r->toneCur == treq) ? L : 0;
            if (r->toneP < goal) r->toneP++;
            else if (r->toneP > goal) r->toneP--;
            if (r->toneCur >= 0) r->toneT++;
        }
    }
}

void dl_render_capture(DLRender *r, const float *in, uint32_t frames) {
    const uint32_t n = r->count;
    uint32_t offsets[DL_MAX_SPEAKERS];
    uint32_t present[DL_MAX_SPEAKERS];
    float peak[DL_MAX_SPEAKERS];
    const uint32_t mono = atomic_load_explicit(&r->mono, memory_order_acquire);
    for (uint32_t i = 0; i < DL_MAX_SPEAKERS; i++) offsets[i] = DOMINE_NO_DEVICE;
    for (uint32_t i = 0; i < n; i++) {
        present[i] = atomic_load_explicit(&r->present[i], memory_order_acquire);
        peak[i] = 0.0f;
        if (mono == DL_NO_SPEAKER && present[i]) offsets[i] = 2 * i;
    }
    if (mono != DL_NO_SPEAKER && mono < n) offsets[0] = 2 * mono;
    uint32_t done = 0;
    while (done < frames) {
        const uint32_t chunk = frames - done < r->maxFrames ? frames - done : r->maxFrames;
        AudioBufferList inList;
        inList.mNumberBuffers = 1;
        inList.mBuffers[0].mNumberChannels = 2;
        inList.mBuffers[0].mDataByteSize = (UInt32)(sizeof(float) * 2 * chunk);
        inList.mBuffers[0].mData = (void *)(in != NULL ? in + 2 * (size_t)done : NULL);
        AudioBufferList outList;
        outList.mNumberBuffers = 1;
        outList.mBuffers[0].mNumberChannels = 2 * n;
        outList.mBuffers[0].mDataByteSize = (UInt32)(sizeof(float) * 2 * n * chunk);
        outList.mBuffers[0].mData = r->scratch;
        domine_surround_process(r->kernel, in != NULL ? &inList : NULL, &outList, chunk, offsets);
        post_process(r, chunk, present);
        const uint32_t stride = 2 * n;
        for (uint32_t i = 0; i < n; i++) {
            if (!present[i]) continue;
            const float *src = r->scratch + 2 * i;
            float pk = peak[i];
            for (uint32_t f = 0; f < chunk; f++) {
                const float a = src[(size_t)stride * f], b = src[(size_t)stride * f + 1];
                r->pair[2 * f] = a;
                r->pair[2 * f + 1] = b;
                const float m = fabsf(a) > fabsf(b) ? fabsf(a) : fabsf(b);
                if (m > pk) pk = m;
            }
            peak[i] = pk;
            const uint32_t wrote = dl_ring_write(&r->rings[i], r->pair, chunk);
            if (wrote < chunk) {
                atomic_fetch_add_explicit(&r->overflows[i], chunk - wrote, memory_order_relaxed);
            }
        }
        done += chunk;
    }
    for (uint32_t i = 0; i < n; i++) {
        atomic_store_explicit(&r->peakBits[i], f2u(peak[i]), memory_order_relaxed);
    }
}

void dl_render_pull(DLRender *r, uint32_t speaker, float *dst, uint32_t frames) {
    if (speaker >= r->count) {
        memset(dst, 0, sizeof(float) * 2 * (size_t)frames);
        return;
    }
    DLRing *ring = &r->rings[speaker];
    const uint32_t fill = dl_ring_fill(ring);
    if (!r->primed[speaker]) {
        if (fill < r->target || fill == 0) {
            memset(dst, 0, sizeof(float) * 2 * (size_t)frames);
            return;
        }
        r->primed[speaker] = 1;
    }
    if (fill > r->high) {
        dl_ring_read(ring, NULL, fill - r->target);
        atomic_fetch_add_explicit(&r->drops[speaker], 1, memory_order_relaxed);
    }
    const uint32_t got = dl_ring_read(ring, dst, frames);
    if (got < frames) {
        memset(dst + 2 * (size_t)got, 0, sizeof(float) * 2 * (size_t)(frames - got));
        atomic_fetch_add_explicit(&r->underruns[speaker], 1, memory_order_relaxed);
        r->primed[speaker] = 0;
    }
}
