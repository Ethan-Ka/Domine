// Domine real-time render kernel. See include/DomineDSP.h for the contract.
//
// Everything reachable from domine_kernel_process is real-time safe: no
// allocation, no locks, no logging, no I/O. Parameters arrive through C11
// atomics written by other threads; the render thread snapshots them once at
// the start of each call.

#include "DomineDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RING_MIN_RATE 96000.0

struct DomineKernel {
    double sampleRate;
    uint32_t maxFrames;

    // Parameters: written by any thread, read by the render thread.
    _Atomic uint32_t gainABits;
    _Atomic uint32_t gainBBits;
    _Atomic int32_t delaySamples; // > 0 delays B, < 0 delays A
    _Atomic int monoPerSpeaker;
    _Atomic int swapSides;
    _Atomic int monoFallback;
    _Atomic int toneSide;
    _Atomic int muted;
    _Atomic int clickTest; // click test mode: 0 off, 1 clicks
    _Atomic uint32_t layoutInFirstBuffer;
    _Atomic uint32_t layoutOutA;
    _Atomic uint32_t layoutOutB;

    // Meters: written by the render thread, read by any thread.
    _Atomic uint32_t peakABits;
    _Atomic uint32_t peakBBits;

    // Render thread state only.
    float *ringA;
    float *ringB;
    uint32_t ringMask;
    uint32_t ringWrite;
    int32_t maxDelaySamples;
    uint32_t fadeLength;   // samples in a full fade
    uint32_t fadePosition; // 0 = silent, fadeLength = full gain
    int playingToneSide;   // side the tone envelope belongs to, 0 = none
    uint32_t toneFadeLength;
    uint32_t toneLevel;    // 0 = program only, toneFadeLength = tone only
    double tonePhase;      // cycles, in [0, 1)
    double tonePhaseStep;  // cycles per sample

    // Click test, render thread state only (see domine_kernel_set_click_test).
    uint32_t clickLevel;   // 0 = program only, toneFadeLength = clicks only
    uint32_t clickCounter; // samples since the current click started
    uint32_t clickLength;  // samples in one click
    uint32_t clickPeriod;  // samples from one click to the next
};

// A resolved output channel: base pointer, stride in floats, usable frames.
typedef struct {
    float *data;
    uint32_t stride;
    uint32_t frames;
} OutChannel;

// A resolved input channel. data NULL means silence.
typedef struct {
    const float *data;
    uint32_t stride;
    uint32_t frames;
} InChannel;

static inline uint32_t float_bits(float f) {
    uint32_t u;
    memcpy(&u, &f, sizeof u);
    return u;
}

static inline float bits_float(uint32_t u) {
    float f;
    memcpy(&f, &u, sizeof f);
    return f;
}

static inline float sanitize_gain(float g) {
    return (isfinite(g) && g > 0.0f) ? g : 0.0f;
}

static uint32_t next_pow2(uint32_t v) {
    uint32_t p = 1;
    while (p < v) p <<= 1;
    return p;
}

// Maps a flat channel index across all buffers of abl to a channel pointer.
// Returns 0 if the index is out of range or the buffer has no data.
static int map_out_channel(AudioBufferList *abl, uint32_t flat, OutChannel *out) {
    if (abl == NULL || flat == DOMINE_NO_DEVICE) return 0;
    uint32_t base = 0;
    for (uint32_t b = 0; b < abl->mNumberBuffers; b++) {
        AudioBuffer *buf = &abl->mBuffers[b];
        uint32_t n = buf->mNumberChannels;
        if (flat < base + n) {
            if (buf->mData == NULL) return 0;
            out->data = (float *)buf->mData + (flat - base);
            out->stride = n;
            out->frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * n);
            return 1;
        }
        base += n;
    }
    return 0;
}

static InChannel in_channel(const AudioBuffer *buf, uint32_t channel) {
    InChannel c = { NULL, 1, 0 };
    if (buf->mData == NULL || buf->mNumberChannels == 0 || channel >= buf->mNumberChannels) return c;
    c.data = (const float *)buf->mData + channel;
    c.stride = buf->mNumberChannels;
    c.frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
    return c;
}

// Detects interleaved vs deinterleaved stereo input in `count` buffers.
static void resolve_input(const AudioBuffer *buffers, uint32_t count, InChannel *left, InChannel *right) {
    InChannel none = { NULL, 1, 0 };
    *left = none;
    *right = none;
    if (buffers == NULL || count == 0) return;
    const AudioBuffer *b0 = &buffers[0];
    if (b0->mNumberChannels >= 2) {
        *left = in_channel(b0, 0);
        *right = in_channel(b0, 1);
    } else if (count >= 2) {
        *left = in_channel(b0, 0);
        *right = in_channel(&buffers[1], 0);
    } else {
        *left = in_channel(b0, 0);
        *right = *left;
    }
}

static inline float read_in(const InChannel *c, uint32_t frame) {
    return (c->data != NULL && frame < c->frames) ? c->data[(size_t)frame * c->stride] : 0.0f;
}

static inline void write_out(const OutChannel *c, int present, uint32_t frame, float v) {
    if (present && frame < c->frames) c->data[(size_t)frame * c->stride] = v;
}

DomineKernel *domine_kernel_create(double sampleRate, uint32_t maxFrames) {
    if (!(sampleRate > 0.0) || !isfinite(sampleRate)) return NULL;
    DomineKernel *k = calloc(1, sizeof *k);
    if (k == NULL) return NULL;

    k->sampleRate = sampleRate;
    k->maxFrames = maxFrames;

    double ringRate = sampleRate > RING_MIN_RATE ? sampleRate : RING_MIN_RATE;
    uint32_t maxDelay = (uint32_t)ceil(ringRate * DOMINE_MAX_DELAY_MS / 1000.0);
    uint32_t ringSize = next_pow2(maxDelay + 1);
    k->ringA = calloc(ringSize, sizeof(float));
    k->ringB = calloc(ringSize, sizeof(float));
    if (k->ringA == NULL || k->ringB == NULL) {
        domine_kernel_destroy(k);
        return NULL;
    }
    k->ringMask = ringSize - 1;
    k->maxDelaySamples = (int32_t)(ringSize - 1);

    uint32_t fade = (uint32_t)lround(sampleRate * DOMINE_FADE_MS / 1000.0);
    k->fadeLength = fade > 0 ? fade : 1;
    k->fadePosition = k->fadeLength;
    k->tonePhaseStep = DOMINE_TONE_HZ / sampleRate;
    uint32_t toneFade = (uint32_t)lround(sampleRate * DOMINE_TONE_FADE_MS / 1000.0);
    k->toneFadeLength = toneFade > 0 ? toneFade : 1;
    uint32_t clickLength = (uint32_t)lround(sampleRate * DOMINE_CLICK_MS / 1000.0);
    k->clickLength = clickLength > 0 ? clickLength : 1;
    uint32_t clickPeriod = (uint32_t)lround(sampleRate * DOMINE_CLICK_PERIOD_MS / 1000.0);
    k->clickPeriod = clickPeriod > k->clickLength ? clickPeriod : k->clickLength + 1;

    atomic_init(&k->gainABits, float_bits(1.0f));
    atomic_init(&k->gainBBits, float_bits(1.0f));
    atomic_init(&k->delaySamples, 0);
    atomic_init(&k->monoPerSpeaker, 1);
    atomic_init(&k->swapSides, 0);
    atomic_init(&k->monoFallback, 0);
    atomic_init(&k->toneSide, 0);
    atomic_init(&k->muted, 0);
    atomic_init(&k->clickTest, 0);
    atomic_init(&k->layoutInFirstBuffer, 0);
    atomic_init(&k->layoutOutA, 0);
    atomic_init(&k->layoutOutB, 2);
    atomic_init(&k->peakABits, float_bits(0.0f));
    atomic_init(&k->peakBBits, float_bits(0.0f));
    return k;
}

void domine_kernel_destroy(DomineKernel *k) {
    if (k == NULL) return;
    free(k->ringA);
    free(k->ringB);
    free(k);
}

void domine_kernel_set_gains(DomineKernel *k, float leftGain, float rightGain) {
    if (k == NULL) return;
    atomic_store_explicit(&k->gainABits, float_bits(sanitize_gain(leftGain)), memory_order_relaxed);
    atomic_store_explicit(&k->gainBBits, float_bits(sanitize_gain(rightGain)), memory_order_relaxed);
}

void domine_kernel_set_delay_ms(DomineKernel *k, float signedDelayMs) {
    if (k == NULL) return;
    double ms = isfinite(signedDelayMs) ? (double)signedDelayMs : 0.0;
    if (ms > DOMINE_MAX_DELAY_MS) ms = DOMINE_MAX_DELAY_MS;
    if (ms < -DOMINE_MAX_DELAY_MS) ms = -DOMINE_MAX_DELAY_MS;
    long samples = lround(fabs(ms) * k->sampleRate / 1000.0);
    if (samples > k->maxDelaySamples) samples = k->maxDelaySamples;
    int32_t signedSamples = (int32_t)(ms < 0.0 ? -samples : samples);
    atomic_store_explicit(&k->delaySamples, signedSamples, memory_order_relaxed);
}

void domine_kernel_set_mode(DomineKernel *k, int monoPerSpeaker, int swapSides, int monoFallback) {
    if (k == NULL) return;
    atomic_store_explicit(&k->monoPerSpeaker, monoPerSpeaker != 0, memory_order_relaxed);
    atomic_store_explicit(&k->swapSides, swapSides != 0, memory_order_relaxed);
    atomic_store_explicit(&k->monoFallback, monoFallback != 0, memory_order_relaxed);
}

void domine_kernel_set_test_tone(DomineKernel *k, int side) {
    if (k == NULL) return;
    atomic_store_explicit(&k->toneSide, (side == 1 || side == 2) ? side : 0, memory_order_relaxed);
}

void domine_kernel_set_click_test(DomineKernel *k, int mode) {
    if (k == NULL) return;
    atomic_store_explicit(&k->clickTest, mode == 1 ? 1 : 0, memory_order_relaxed);
}

void domine_kernel_set_muted(DomineKernel *k, int muted) {
    if (k == NULL) return;
    atomic_store_explicit(&k->muted, muted != 0, memory_order_relaxed);
}

float domine_kernel_peak(DomineKernel *k, int position) {
    if (k == NULL) return 0.0f;
    if (position == 0) return bits_float(atomic_load_explicit(&k->peakABits, memory_order_relaxed));
    if (position == 1) return bits_float(atomic_load_explicit(&k->peakBBits, memory_order_relaxed));
    return 0.0f;
}

void domine_kernel_set_layout(DomineKernel *k,
                              uint32_t inFirstBuffer,
                              uint32_t outAChannelOffset,
                              uint32_t outBChannelOffset) {
    if (k == NULL) return;
    atomic_store_explicit(&k->layoutInFirstBuffer, inFirstBuffer, memory_order_relaxed);
    atomic_store_explicit(&k->layoutOutA, outAChannelOffset, memory_order_relaxed);
    atomic_store_explicit(&k->layoutOutB, outBChannelOffset, memory_order_relaxed);
}

// Click test, one frame. Mixes the click into both positions' sources (which
// then feed the delay line) and steps the click level. Call once per frame.
static inline void click_mix(DomineKernel *k, int on, float *srcA, float *srcB) {
    const uint32_t full = k->toneFadeLength;
    float click = 0.0f;
    if (on && k->clickLevel == full) {
        const uint32_t n = k->clickCounter;
        if (n < k->clickLength) {
            const double window = 0.5 - 0.5 * cos(2.0 * M_PI * (double)n / (double)k->clickLength);
            click = (float)(DOMINE_CLICK_AMPLITUDE * window
                            * sin(2.0 * M_PI * DOMINE_CLICK_HZ * (double)n / k->sampleRate));
        }
        k->clickCounter = n + 1 < k->clickPeriod ? n + 1 : 0;
    } else {
        k->clickCounter = 0;
    }
    if (k->clickLevel == full) {
        *srcA = click;
        *srcB = click;
    } else {
        const float keep = 1.0f - (float)k->clickLevel / (float)full;
        *srcA = *srcA * keep + click;
        *srcB = *srcB * keep + click;
    }
    const uint32_t target = on ? full : 0;
    if (k->clickLevel < target) k->clickLevel++;
    else if (k->clickLevel > target) k->clickLevel--;
}

// Shared renderer. The input is `inCount` buffers starting at `inBuffers`, so
// the IOProc can pass a view into the aggregate's input list without copying.
static void render(DomineKernel *k,
                   const AudioBuffer *inBuffers,
                   uint32_t inCount,
                   AudioBufferList *out,
                   uint32_t frames,
                   uint32_t outAChannelOffset,
                   uint32_t outBChannelOffset) {

    // Zero every output channel first; the kernel then writes only its own.
    for (uint32_t b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *buf = &out->mBuffers[b];
        if (buf->mData != NULL) memset(buf->mData, 0, buf->mDataByteSize);
    }

    // Snapshot parameters once per cycle.
    const float gainA = bits_float(atomic_load_explicit(&k->gainABits, memory_order_relaxed));
    const float gainB = bits_float(atomic_load_explicit(&k->gainBBits, memory_order_relaxed));
    const int32_t delay = atomic_load_explicit(&k->delaySamples, memory_order_relaxed);
    const int monoPerSpeaker = atomic_load_explicit(&k->monoPerSpeaker, memory_order_relaxed);
    const int swap = atomic_load_explicit(&k->swapSides, memory_order_relaxed);
    const int monoFallback = atomic_load_explicit(&k->monoFallback, memory_order_relaxed);
    const int toneSide = atomic_load_explicit(&k->toneSide, memory_order_relaxed);
    const int muted = atomic_load_explicit(&k->muted, memory_order_relaxed);
    const int clickTest = atomic_load_explicit(&k->clickTest, memory_order_relaxed);

    const uint32_t delayA = delay < 0 ? (uint32_t)(-delay) : 0;
    const uint32_t delayB = delay > 0 ? (uint32_t)delay : 0;
    const int bothChannels = monoPerSpeaker || monoFallback;

    InChannel inL, inR;
    resolve_input(inBuffers, inCount, &inL, &inR);

    OutChannel a0 = {0}, a1 = {0}, b0 = {0}, b1 = {0};
    const int hasA0 = map_out_channel(out, outAChannelOffset, &a0);
    const int hasB0 = map_out_channel(out, outBChannelOffset, &b0);
    const int hasA1 = bothChannels && outAChannelOffset != DOMINE_NO_DEVICE
        && map_out_channel(out, outAChannelOffset + 1, &a1);
    const int hasB1 = bothChannels && outBChannelOffset != DOMINE_NO_DEVICE
        && map_out_channel(out, outBChannelOffset + 1, &b1);

    const uint32_t mask = k->ringMask;
    const uint32_t fadeTarget = muted ? 0 : k->fadeLength;
    float peakA = 0.0f, peakB = 0.0f;

    for (uint32_t f = 0; f < frames; f++) {
        const float l = read_in(&inL, f);
        const float r = read_in(&inR, f);

        float srcA, srcB;
        if (monoFallback) {
            srcA = srcB = (l + r) * 0.5f;
        } else if (swap) {
            srcA = r;
            srcB = l;
        } else {
            srcA = l;
            srcB = r;
        }

        // Click test: replaces the source before the delay line.
        if (clickTest || k->clickLevel != 0) click_mix(k, clickTest, &srcA, &srcB);

        const uint32_t w = k->ringWrite;
        k->ringA[w] = srcA;
        k->ringB[w] = srcB;
        k->ringWrite = (w + 1) & mask;

        float outA = k->ringA[(w - delayA) & mask] * gainA;
        float outB = k->ringB[(w - delayB) & mask] * gainB;

        // A new request takes over only once the current tone has faded out.
        if (k->toneLevel == 0 && k->playingToneSide != toneSide) {
            k->playingToneSide = toneSide;
            k->tonePhase = 0.0;
        }
        if (k->playingToneSide != 0) {
            const float tone = (float)(DOMINE_TONE_AMPLITUDE * sin(2.0 * M_PI * k->tonePhase));
            k->tonePhase += k->tonePhaseStep;
            if (k->tonePhase >= 1.0) k->tonePhase -= 1.0;
            const uint32_t toneTarget = toneSide == k->playingToneSide ? k->toneFadeLength : 0;
            if (k->toneLevel == k->toneFadeLength && toneTarget == k->toneFadeLength) {
                outA = k->playingToneSide == 1 ? tone : 0.0f;
                outB = k->playingToneSide == 2 ? tone : 0.0f;
            } else {
                const float e = (float)k->toneLevel / (float)k->toneFadeLength;
                const float keep = 1.0f - e;
                outA = k->playingToneSide == 1 ? tone * e + outA * keep : outA * keep;
                outB = k->playingToneSide == 2 ? tone * e + outB * keep : outB * keep;
            }
            if (k->toneLevel < toneTarget) k->toneLevel++;
            else if (k->toneLevel > toneTarget) k->toneLevel--;
        }

        if (k->fadePosition < fadeTarget) k->fadePosition++;
        else if (k->fadePosition > fadeTarget) k->fadePosition--;
        if (k->fadePosition != k->fadeLength) {
            const float fade = (float)k->fadePosition / (float)k->fadeLength;
            outA *= fade;
            outB *= fade;
        }

        write_out(&a0, hasA0, f, outA);
        write_out(&a1, hasA1, f, outA);
        write_out(&b0, hasB0, f, outB);
        write_out(&b1, hasB1, f, outB);

        if ((hasA0 || hasA1) && fabsf(outA) > peakA) peakA = fabsf(outA);
        if ((hasB0 || hasB1) && fabsf(outB) > peakB) peakB = fabsf(outB);
    }

    atomic_store_explicit(&k->peakABits, float_bits(peakA), memory_order_relaxed);
    atomic_store_explicit(&k->peakBBits, float_bits(peakB), memory_order_relaxed);
}

void domine_kernel_process(DomineKernel *k,
                           const AudioBufferList *in,
                           AudioBufferList *out,
                           uint32_t frames,
                           uint32_t outAChannelOffset,
                           uint32_t outBChannelOffset) {
    if (k == NULL || out == NULL) return;
    const AudioBuffer *inBuffers = in != NULL ? in->mBuffers : NULL;
    const uint32_t inCount = in != NULL ? in->mNumberBuffers : 0;
    render(k, inBuffers, inCount, out, frames, outAChannelOffset, outBChannelOffset);
}

OSStatus domine_kernel_ioproc(AudioObjectID inDevice,
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
    DomineKernel *k = (DomineKernel *)inClientData;
    if (k == NULL || outOutputData == NULL) return 0;

    const uint32_t first = atomic_load_explicit(&k->layoutInFirstBuffer, memory_order_relaxed);
    const uint32_t outA = atomic_load_explicit(&k->layoutOutA, memory_order_relaxed);
    const uint32_t outB = atomic_load_explicit(&k->layoutOutB, memory_order_relaxed);

    uint32_t frames = 0;
    for (uint32_t b = 0; b < outOutputData->mNumberBuffers; b++) {
        const AudioBuffer *buf = &outOutputData->mBuffers[b];
        if (buf->mNumberChannels == 0) continue;
        const uint32_t n = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
        if (n > frames) frames = n;
    }

    const AudioBuffer *inBuffers = NULL;
    uint32_t inCount = 0;
    if (inInputData != NULL && first < inInputData->mNumberBuffers) {
        inBuffers = inInputData->mBuffers + first;
        inCount = inInputData->mNumberBuffers - first;
    }
    render(k, inBuffers, inCount, outOutputData, frames, outA, outB);
    return 0;
}
