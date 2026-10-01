// Audio capture probe. See include/DomineProbe.h for the contract.

#include "DomineProbe.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct DomineProbe {
    atomic_int heard;
};

DomineProbe *domine_probe_create(void) {
    DomineProbe *p = malloc(sizeof(DomineProbe));
    if (p == NULL) return NULL;
    atomic_init(&p->heard, 0);
    return p;
}

void domine_probe_destroy(DomineProbe *p) {
    free(p);
}

void domine_probe_reset(DomineProbe *p) {
    atomic_store_explicit(&p->heard, 0, memory_order_relaxed);
}

int domine_probe_heard(DomineProbe *p) {
    return atomic_load_explicit(&p->heard, memory_order_relaxed);
}

static int any_nonzero(const AudioBufferList *list) {
    for (UInt32 b = 0; b < list->mNumberBuffers; b++) {
        const AudioBuffer *buf = &list->mBuffers[b];
        if (buf->mData == NULL) continue;
        const float *samples = (const float *)buf->mData;
        const UInt32 count = buf->mDataByteSize / (UInt32)sizeof(float);
        for (UInt32 i = 0; i < count; i++) {
            if (samples[i] != 0.0f) return 1;
        }
    }
    return 0;
}

OSStatus domine_probe_ioproc(AudioObjectID inDevice,
                             const AudioTimeStamp *inNow,
                             const AudioBufferList *inInputData,
                             const AudioTimeStamp *inInputTime,
                             AudioBufferList *outOutputData,
                             const AudioTimeStamp *inOutputTime,
                             void *inClientData) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)inOutputTime;
    AudioBufferList *out = outOutputData;
    if (out != NULL) {
        for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
            if (out->mBuffers[b].mData != NULL) {
                memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
            }
        }
    }
    DomineProbe *p = (DomineProbe *)inClientData;
    const AudioBufferList *in = inInputData;
    if (p == NULL || in == NULL) return 0;
    if (atomic_load_explicit(&p->heard, memory_order_relaxed)) return 0;
    if (any_nonzero(in)) atomic_store_explicit(&p->heard, 1, memory_order_relaxed);
    return 0;
}
