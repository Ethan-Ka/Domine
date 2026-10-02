// Domine for Linux: render path between the capture stream, the surround
// kernel and the per-speaker rings. See engine_render.h.
#include "engine_render.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

static uint32_t next_pow2(uint32_t v) {
    uint32_t p = 1;
    while (p < v && p < (1u << 30)) p <<= 1;
    return p;
}

DLRender *dl_render_create(double sampleRate, uint32_t count, uint32_t maxFrames,
                           uint32_t ringFrames, uint32_t target, uint32_t high) {
    if (count == 0 || count > DL_MAX_SPEAKERS || maxFrames == 0) return NULL;
    DLRender *r = calloc(1, sizeof *r);
    if (r == NULL) return NULL;
    r->count = count;
    r->maxFrames = maxFrames;
    const uint32_t cap = next_pow2(ringFrames < 2 * maxFrames ? 2 * maxFrames : ringFrames);
    if (high >= cap) high = cap - 1;
    if (target > high) target = high;
    r->target = target;
    r->high = high;
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
        atomic_init(&r->underruns[i], 0);
        atomic_init(&r->drops[i], 0);
        atomic_init(&r->overflows[i], 0);
    }
    return r;
}

void dl_render_destroy(DLRender *r) {
    if (r == NULL) return;
    domine_surround_destroy(r->kernel);
    free(r->scratch);
    free(r->pair);
    free(r->ringData);
    free(r);
}

void dl_render_configure(DLRender *r, const DLSpeaker *speakers, uint32_t count, float master) {
    if (r == NULL || speakers == NULL) return;
    if (count > r->count) count = r->count;
    if (!isfinite(master) || master < 0.0f) master = 0.0f;
    if (master > 1.0f) master = 1.0f;
    float az[DL_MAX_SPEAKERS], dist[DL_MAX_SPEAKERS];
    float delayMs[DL_MAX_SPEAKERS], distGain[DL_MAX_SPEAKERS];
    for (uint32_t i = 0; i < r->count; i++) {
        az[i] = i < count ? speakers[i].azimuth : 0.0f;
        dist[i] = i < count ? speakers[i].distance : 1.0f;
    }
    domine_surround_set_speakers(r->kernel, r->count, az);
    domine_surround_distance_comp(r->count, dist, delayMs, distGain);
    for (uint32_t i = 0; i < r->count; i++) {
        float trim = i < count ? speakers[i].trim : 0.0f;
        if (!isfinite(trim) || trim < 0.0f) trim = 0.0f;
        if (trim > 1.0f) trim = 1.0f;
        domine_surround_set_gain(r->kernel, i, trim * distGain[i] * master);
        domine_surround_set_delay_ms(r->kernel, i, delayMs[i]);
    }
}

void dl_render_set_present(DLRender *r, uint32_t speaker, int present) {
    if (r == NULL || speaker >= r->count) return;
    atomic_store_explicit(&r->present[speaker], present ? 1u : 0u, memory_order_release);
}

void dl_render_capture(DLRender *r, const float *in, uint32_t frames) {
    const uint32_t n = r->count;
    uint32_t offsets[DL_MAX_SPEAKERS];
    uint32_t present[DL_MAX_SPEAKERS];
    for (uint32_t i = 0; i < n; i++) {
        present[i] = atomic_load_explicit(&r->present[i], memory_order_acquire);
        offsets[i] = present[i] ? 2 * i : DOMINE_NO_DEVICE;
    }
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
        const uint32_t stride = 2 * n;
        for (uint32_t i = 0; i < n; i++) {
            if (!present[i]) continue;
            const float *src = r->scratch + 2 * i;
            for (uint32_t f = 0; f < chunk; f++) {
                r->pair[2 * f] = src[(size_t)stride * f];
                r->pair[2 * f + 1] = src[(size_t)stride * f + 1];
            }
            const uint32_t wrote = dl_ring_write(&r->rings[i], r->pair, chunk);
            if (wrote < chunk) {
                atomic_fetch_add_explicit(&r->overflows[i], chunk - wrote, memory_order_relaxed);
            }
        }
        done += chunk;
    }
}

void dl_render_pull(DLRender *r, uint32_t speaker, float *dst, uint32_t frames) {
    if (speaker >= r->count) {
        memset(dst, 0, sizeof(float) * 2 * (size_t)frames);
        return;
    }
    DLRing *ring = &r->rings[speaker];
    uint32_t fill = dl_ring_fill(ring);
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
