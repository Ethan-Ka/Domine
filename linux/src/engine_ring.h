// Domine for Linux: lock-free single-producer single-consumer ring of
// interleaved stereo float frames (private to the engine). One writer thread
// and one reader thread; positions are free-running 32-bit counters that
// cross threads through C11 atomics. Storage is supplied by the caller and
// never reallocated, so both ends are real-time safe.
#ifndef DOMINE_LINUX_ENGINE_RING_H
#define DOMINE_LINUX_ENGINE_RING_H

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    float *data;               // 2 * capacity floats
    uint32_t capacity;         // frames, power of two
    uint32_t mask;
    _Atomic uint32_t head;     // frames written (producer owns)
    _Atomic uint32_t tail;     // frames read (consumer owns)
} DLRing;

/// capacity must be a power of two; data must hold 2 * capacity floats.
static inline void dl_ring_init(DLRing *r, float *data, uint32_t capacity) {
    r->data = data;
    r->capacity = capacity;
    r->mask = capacity - 1;
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
}

/// Frames available to read. Either side may call it.
static inline uint32_t dl_ring_fill(DLRing *r) {
    const uint32_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    const uint32_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    return h - t;
}

/// Producer: writes up to `frames` frames from interleaved stereo `src`.
/// Returns the number written (less when the ring is full).
static inline uint32_t dl_ring_write(DLRing *r, const float *src, uint32_t frames) {
    const uint32_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
    const uint32_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
    const uint32_t space = r->capacity - (h - t);
    if (frames > space) frames = space;
    const uint32_t start = h & r->mask;
    const uint32_t first = frames < r->capacity - start ? frames : r->capacity - start;
    memcpy(r->data + 2 * (size_t)start, src, sizeof(float) * 2 * first);
    if (frames > first) memcpy(r->data, src + 2 * (size_t)first, sizeof(float) * 2 * (frames - first));
    atomic_store_explicit(&r->head, h + frames, memory_order_release);
    return frames;
}

/// Consumer: reads up to `frames` frames into interleaved stereo `dst`
/// (dst may be NULL to discard). Returns the number read.
static inline uint32_t dl_ring_read(DLRing *r, float *dst, uint32_t frames) {
    const uint32_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
    const uint32_t h = atomic_load_explicit(&r->head, memory_order_acquire);
    const uint32_t avail = h - t;
    if (frames > avail) frames = avail;
    if (dst != NULL) {
        const uint32_t start = t & r->mask;
        const uint32_t first = frames < r->capacity - start ? frames : r->capacity - start;
        memcpy(dst, r->data + 2 * (size_t)start, sizeof(float) * 2 * first);
        if (frames > first) memcpy(dst + 2 * (size_t)first, r->data, sizeof(float) * 2 * (frames - first));
    }
    atomic_store_explicit(&r->tail, t + frames, memory_order_release);
    return frames;
}

#endif
