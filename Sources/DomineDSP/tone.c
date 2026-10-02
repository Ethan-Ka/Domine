// Identification tone. domine_tone_ioproc runs on the real-time thread: no
// allocation, no locks, no logging, no I/O.

#include "include/DomineTone.h"
#include "include/DomineChime.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct DomineTone {
    double secondsPerFrame;
    uint32_t totalFrames;
    uint32_t fadeFrames;
    _Atomic uint32_t written;
};

DomineTone *domine_tone_create(double sampleRate, double seconds) {
    if (!(sampleRate > 0.0) || !(seconds > 0.0)) return NULL;
    DomineTone *t = calloc(1, sizeof *t);
    if (t == NULL) return NULL;
    t->secondsPerFrame = 1.0 / sampleRate;
    t->totalFrames = (uint32_t)lround(seconds * sampleRate);
    t->fadeFrames = (uint32_t)lround(DOMINE_IDENT_TONE_FADE_MS * sampleRate / 1000.0);
    if (t->fadeFrames * 2 > t->totalFrames) t->fadeFrames = t->totalFrames / 2;
    atomic_init(&t->written, 0);
    return t;
}

void domine_tone_destroy(DomineTone *t) {
    free(t);
}

int domine_tone_finished(DomineTone *t) {
    return atomic_load_explicit(&t->written, memory_order_relaxed) >= t->totalFrames;
}

static float envelope(const DomineTone *t, uint32_t frame) {
    if (t->fadeFrames == 0) return 1.0f;
    if (frame < t->fadeFrames) return (float)frame / (float)t->fadeFrames;
    uint32_t left = t->totalFrames - frame;
    if (left <= t->fadeFrames) return (float)(left - 1) / (float)t->fadeFrames;
    return 1.0f;
}

OSStatus domine_tone_ioproc(AudioObjectID inDevice,
                            const AudioTimeStamp *inNow,
                            const AudioBufferList *inInputData,
                            const AudioTimeStamp *inInputTime,
                            AudioBufferList *outOutputData,
                            const AudioTimeStamp *inOutputTime,
                            void *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputData; (void)inInputTime; (void)inOutputTime;
    if (outOutputData == NULL) return 0;
    DomineTone *t = inClientData;

    for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
        AudioBuffer *buf = &outOutputData->mBuffers[b];
        if (buf->mData != NULL) memset(buf->mData, 0, buf->mDataByteSize);
    }
    if (t == NULL || outOutputData->mNumberBuffers == 0) return 0;

    const AudioBuffer *first = &outOutputData->mBuffers[0];
    if (first->mNumberChannels == 0) return 0;
    const uint32_t frames = first->mDataByteSize / (uint32_t)(sizeof(float) * first->mNumberChannels);

    uint32_t written = atomic_load_explicit(&t->written, memory_order_relaxed);
    for (uint32_t i = 0; i < frames && written < t->totalFrames; i++, written++) {
        const float s = (float)domine_chime_sample((double)written * t->secondsPerFrame) * envelope(t, written);
        for (UInt32 b = 0; b < outOutputData->mNumberBuffers; b++) {
            AudioBuffer *buf = &outOutputData->mBuffers[b];
            if (buf->mData == NULL || buf->mNumberChannels == 0) continue;
            const uint32_t bufFrames = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
            if (i >= bufFrames) continue;
            float *out = (float *)buf->mData + (size_t)i * buf->mNumberChannels;
            for (UInt32 c = 0; c < buf->mNumberChannels; c++) out[c] = s;
        }
    }
    atomic_store_explicit(&t->written, written, memory_order_relaxed);
    return 0;
}
