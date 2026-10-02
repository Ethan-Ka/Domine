#include "DomineRecorder.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct DomineRecorder {
    float *samples;
    uint32_t capacity;
    _Atomic uint32_t written;
};

DomineRecorder *domine_recorder_create(uint32_t capacityFrames) {
    DomineRecorder *r = calloc(1, sizeof(DomineRecorder));
    if (r == NULL) return NULL;
    r->samples = calloc(capacityFrames > 0 ? capacityFrames : 1, sizeof(float));
    if (r->samples == NULL) {
        free(r);
        return NULL;
    }
    r->capacity = capacityFrames;
    atomic_init(&r->written, 0);
    return r;
}

void domine_recorder_destroy(DomineRecorder *r) {
    if (r == NULL) return;
    free(r->samples);
    free(r);
}

OSStatus domine_recorder_ioproc(AudioObjectID inDevice,
                                const AudioTimeStamp *inNow,
                                const AudioBufferList *inInputData,
                                const AudioTimeStamp *inInputTime,
                                AudioBufferList *outOutputData,
                                const AudioTimeStamp *inOutputTime,
                                void *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)outOutputData; (void)inOutputTime;
    DomineRecorder *r = (DomineRecorder *)inClientData;
    if (r == NULL || inInputData == NULL || inInputData->mNumberBuffers == 0) return 0;
    const AudioBuffer *buf = &inInputData->mBuffers[0];
    if (buf->mData == NULL || buf->mNumberChannels == 0) return 0;
    const uint32_t channels = buf->mNumberChannels;
    const uint32_t frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * channels);
    const uint32_t start = atomic_load_explicit(&r->written, memory_order_relaxed);
    if (start >= r->capacity) return 0;
    uint32_t n = r->capacity - start;
    if (n > frames) n = frames;
    const float *src = (const float *)buf->mData;
    for (uint32_t i = 0; i < n; i++) r->samples[start + i] = src[(size_t)i * channels];
    atomic_store_explicit(&r->written, start + n, memory_order_release);
    return 0;
}

uint32_t domine_recorder_frames_written(const DomineRecorder *r) {
    if (r == NULL) return 0;
    return atomic_load_explicit((_Atomic uint32_t *)&r->written, memory_order_acquire);
}

uint32_t domine_recorder_copy(const DomineRecorder *r, float *out, uint32_t maxFrames) {
    if (r == NULL || out == NULL) return 0;
    uint32_t n = domine_recorder_frames_written(r);
    if (n > maxFrames) n = maxFrames;
    memcpy(out, r->samples, (size_t)n * sizeof(float));
    return n;
}

void domine_recorder_reset(DomineRecorder *r) {
    if (r == NULL) return;
    atomic_store_explicit(&r->written, 0, memory_order_release);
}
