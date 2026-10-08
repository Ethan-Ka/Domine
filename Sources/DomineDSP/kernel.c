// Domine real-time render kernel. See include/DomineDSP.h for the contract.
//
// Transparency: at unity gain, zero delay, no swap, no tone, no click, and no
// mute, every program sample is copied, never multiplied or blended. Every
// fade (mute, tone, click) steps an integer counter that lands exactly on its
// end value, at which point its multiply or blend is skipped altogether. The
// only intended mixing is the mono fallback, (L + R) * 0.5. Nothing adds gain
// above 1, and every crossfade is a convex blend, so no path can exceed the
// larger of the program peak and the test signal's own amplitude.
//
// Everything reachable from domine_kernel_process and domine_kernel_ioproc is
// real-time safe: no allocation, no locks, no logging, no I/O. Parameters
// arrive through C11 atomics written by other threads; the render thread
// snapshots them once at the start of each call. Stats leave the render
// thread through a seqlock over atomic words, so the writer never waits.

#include "DomineDSP.h"
#include "TapMix.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RING_MIN_RATE 96000.0
#define STATS_WORDS ((sizeof(DomineKernelStats) + sizeof(uint64_t) - 1) / sizeof(uint64_t))

_Static_assert(sizeof(DomineKernelStats) % sizeof(uint64_t) == 0, "stats must pack into whole words");

#define KEEP_ALIVE_THRESHOLD 1.0e-4f // -80 dBFS
#define KEEP_ALIVE_AMPLITUDE 1.0e-3  // -60 dBFS
#define KEEP_ALIVE_HZ 15.0
#define KEEP_ALIVE_HOLD_S 2.0
#define KEEP_ALIVE_FADE_IN_S 0.05
#define KEEP_ALIVE_FADE_OUT_S 0.01

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
    _Atomic int keepAlive;
    _Atomic int clickTest; // click test mode: 0 off, 1 clicks
    _Atomic uint32_t layoutInFirstBuffer;
    _Atomic uint32_t layoutOutA;
    _Atomic uint32_t layoutOutB;
    _Atomic uint32_t inputChannels; // 0 = unknown
    _Atomic int inputNonInterleaved;
    TapMixer taps;
    _Atomic uint32_t statsResetRequests;

    // Meters: written by the render thread, read by any thread.
    _Atomic uint32_t peakABits;
    _Atomic uint32_t peakBBits;

    // Stats: published by the render thread under a seqlock (odd = writing).
    _Atomic uint32_t statsSeq;
    _Atomic uint64_t statsWords[STATS_WORDS];

    // EFFECTS BLOCK (SPEC 5a): per-position effect instances, index 0 = A,
    // 1 = B. Allocated in create, freed in destroy. Other modules add here.
    DomineEQ *eq[2];
    DomineBass *bass[2];
    DomineCompressor *comp[2];

    // Render thread state only.
    float *ringA;
    float *ringB;
    uint32_t ringMask;
    uint32_t ringWrite;
    int32_t maxDelaySamples;
    uint32_t fadeLength;   // samples in a full fade
    uint32_t fadePosition; // 0 = silent, fadeLength = full gain
    // Trim gain smoothing: the applied gain ramps linearly to each new target.
    uint32_t gainRampLength; // samples in a gain ramp (30 ms)
    int gainPrimed;          // 0 until the first process call, which snaps
    float gainCurA, gainCurB;
    float gainTargetA, gainTargetB;
    float gainStepA, gainStepB;
    uint32_t gainLeftA, gainLeftB; // ramp samples remaining
    int playingToneSide;   // side the tone envelope belongs to, 0 = none
    uint32_t toneFadeLength;
    uint32_t toneLevel;    // 0 = program only, toneFadeLength = tone only
    double tonePhase;      // seconds into the chime pattern, in [0, period)
    double tonePhaseStep;  // seconds per sample

    // Input FIFO between the tap and the output.
    float *fifoL;
    float *fifoR;
    uint32_t fifoMask;
    uint32_t fifoRead;  // free-running counters; fill = fifoWrite - fifoRead
    uint32_t fifoWrite;

    // Render thread stats, published after each IOProc cycle.
    DomineKernelStats stats;
    uint32_t statsResetsSeen;
    uint64_t prevNowHostTime; // 0 = none yet
    int prevOutputSampleValid;
    double prevOutputSampleTime;
    uint32_t prevFrames;

    // Click test, render thread state only (see domine_kernel_set_click_test).
    uint32_t clickLevel;   // 0 = program only, toneFadeLength = clicks only
    uint32_t clickCounter; // samples since the current click started
    uint32_t clickLength;  // samples in one click
    uint32_t clickPeriod;  // samples from one click to the next
    uint32_t chirpLevel;   // calibration chirp crossfade, 0..toneFadeLength
    uint32_t chirpCounter; // samples since the current chirp started
    uint32_t chirpLength;  // samples in one chirp

    // Keep-alive, render thread state only (see domine_kernel_set_keep_alive).
    uint32_t kaSilent;     // consecutive frames below the threshold
    float kaLevel;         // fade 0..1
    double kaPhase;        // cycles, 0..1
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

// What one render call did with its input, for the stats.
typedef struct {
    float inputPeak;
    uint32_t underrunFrames;
    uint32_t overflowFrames;
} RenderResult;

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

// Trim gains only ever attenuate: Domine never adds gain (SPEC section 4,
// Signal quality), so anything above 1 is stored as exactly 1.
static inline float sanitize_gain(float g) {
    if (!isfinite(g) || !(g > 0.0f)) return 0.0f;
    return g < 1.0f ? g : 1.0f;
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

// Resolves L and R in `count` tap buffers (see domine_kernel_set_input_format).
// formatChannels 0 means unknown. Returns 1 when the buffers disagree with a
// known format.
static int resolve_input(const AudioBuffer *buffers, uint32_t count,
                         uint32_t formatChannels, int formatNonInterleaved,
                         InChannel *left, InChannel *right) {
    InChannel none = { NULL, 1, 0 };
    *left = none;
    *right = none;
    if (buffers == NULL || count == 0) return 0;
    const AudioBuffer *b0 = &buffers[0];
    if (b0->mNumberChannels >= 2) {
        *left = in_channel(b0, 0);
        *right = in_channel(b0, 1);
    } else if (count >= 2 && formatChannels != 1) {
        *left = in_channel(b0, 0);
        *right = in_channel(&buffers[1], 0);
    } else {
        *left = in_channel(b0, 0);
        *right = *left;
    }
    if (formatChannels == 0) return 0;
    if (formatNonInterleaved) return b0->mNumberChannels != 1 || count < formatChannels;
    return b0->mNumberChannels != formatChannels;
}

// Frames held by a resolved input pair: 0 without data, else the shorter side.
static uint32_t input_frames(const InChannel *l, const InChannel *r) {
    if (l->data == NULL) return 0;
    if (r->data == NULL) return l->frames;
    return l->frames < r->frames ? l->frames : r->frames;
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
    uint32_t fifoWanted = maxFrames > (1u << 20) ? (1u << 21) : 2 * maxFrames;
    if (fifoWanted < DOMINE_INPUT_FIFO_MIN_FRAMES) fifoWanted = DOMINE_INPUT_FIFO_MIN_FRAMES;
    uint32_t fifoSize = next_pow2(fifoWanted);
    k->fifoL = calloc(fifoSize, sizeof(float));
    k->fifoR = calloc(fifoSize, sizeof(float));
    if (k->ringA == NULL || k->ringB == NULL || k->fifoL == NULL || k->fifoR == NULL) {
        domine_kernel_destroy(k);
        return NULL;
    }
    // EFFECTS BLOCK (SPEC 5a): create.
    for (int i = 0; i < 2; i++) {
        k->eq[i] = domine_eq_create(sampleRate);
        k->bass[i] = domine_bass_create(sampleRate);
        k->comp[i] = domine_compressor_create(sampleRate);
        if (k->eq[i] == NULL || k->bass[i] == NULL || k->comp[i] == NULL) {
            domine_kernel_destroy(k);
            return NULL;
        }
    }
    // END EFFECTS BLOCK
    k->ringMask = ringSize - 1;
    k->maxDelaySamples = (int32_t)(ringSize - 1);
    k->fifoMask = fifoSize - 1;

    uint32_t fade = (uint32_t)lround(sampleRate * DOMINE_FADE_MS / 1000.0);
    k->fadeLength = fade > 0 ? fade : 1;
    k->fadePosition = k->fadeLength;
    {
        const uint32_t ramp = (uint32_t)llround(0.03 * sampleRate);
        k->gainRampLength = ramp > 0 ? ramp : 1;
        k->gainCurA = k->gainCurB = k->gainTargetA = k->gainTargetB = 1.0f;
    }
    k->tonePhaseStep = 1.0 / sampleRate;
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
    k->chirpLength = (uint32_t)lround(sampleRate * DOMINE_CHIRP_MS / 1000.0);
    if (k->chirpLength < 2) k->chirpLength = 2;
    if (k->clickPeriod <= k->chirpLength) k->clickPeriod = k->chirpLength + 1;
    atomic_init(&k->keepAlive, 0);
    atomic_init(&k->clickTest, 0);
    atomic_init(&k->layoutInFirstBuffer, 0);
    atomic_init(&k->layoutOutA, 0);
    atomic_init(&k->layoutOutB, 2);
    atomic_init(&k->inputChannels, 0);
    atomic_init(&k->inputNonInterleaved, 0);
    tapmix_init(&k->taps, sampleRate);
    atomic_init(&k->statsResetRequests, 0);
    atomic_init(&k->peakABits, float_bits(0.0f));
    atomic_init(&k->peakBBits, float_bits(0.0f));
    atomic_init(&k->statsSeq, 0);
    for (size_t i = 0; i < STATS_WORDS; i++) atomic_init(&k->statsWords[i], 0);
    return k;
}

void domine_kernel_destroy(DomineKernel *k) {
    if (k == NULL) return;
    // EFFECTS BLOCK (SPEC 5a): destroy.
    for (int i = 0; i < 2; i++) {
        domine_eq_destroy(k->eq[i]);
        if (k->bass[i] != NULL) domine_bass_destroy(k->bass[i]);
        domine_compressor_destroy(k->comp[i]);
    }
    // END EFFECTS BLOCK
    free(k->ringA);
    free(k->ringB);
    free(k->fifoL);
    free(k->fifoR);
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
    atomic_store_explicit(&k->clickTest, (mode == 1 || mode == 2) ? mode : 0, memory_order_relaxed);
}

// EFFECTS BLOCK (SPEC 5a): setters.
void domine_kernel_set_eq(DomineKernel *k, int position, const DomineEQParams *params) {
    if ((position != 0 && position != 1) || params == NULL) return;
    domine_eq_set_params(k->eq[position], params);
}

void domine_kernel_set_bass(DomineKernel *k, int position, const DomineBassParams *params) {
    if (k == NULL || (position != 0 && position != 1) || params == NULL) return;
    domine_bass_set_params(k->bass[position], params);
}

void domine_kernel_set_compressor(DomineKernel *k, int position, const DomineCompressorParams *params) {
    if (k == NULL || (position != 0 && position != 1) || params == NULL) return;
    domine_compressor_set_params(k->comp[position], params);
}
// END EFFECTS BLOCK

void domine_kernel_set_keep_alive(DomineKernel *k, int on) {
    if (k == NULL) return;
    atomic_store_explicit(&k->keepAlive, on != 0, memory_order_relaxed);
}

void domine_kernel_set_muted(DomineKernel *k, int muted) {
    if (k == NULL) return;
    atomic_store_explicit(&k->muted, muted != 0, memory_order_relaxed);
}

void domine_kernel_start_faded_out(DomineKernel *k) {
    if (k == NULL) return;
    k->fadePosition = 0;
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

// One calibration chirp sample, n samples after its start (0 outside the chirp).
// Exponential sweep, Tukey envelope (raised-cosine taper on DOMINE_CHIRP_TAPER of
// the length, split between both ends), and an exponential tail over the last
// DOMINE_CHIRP_TAIL_MS.
static double chirp_sample(uint32_t n, uint32_t length, double sampleRate, int rising) {
    if (n >= length) return 0.0;
    const double duration = (double)length / sampleRate;
    const double f0 = rising ? DOMINE_CHIRP_F0_HZ : DOMINE_CHIRP_F1_HZ;
    const double f1 = rising ? DOMINE_CHIRP_F1_HZ : DOMINE_CHIRP_F0_HZ;
    const double ratio = f1 / f0;
    const double t = (double)n / sampleRate;
    const double phase = 2.0 * M_PI * f0 * duration / log(ratio) * (pow(ratio, t / duration) - 1.0);
    const double x = (double)n / (double)length;
    const double half = DOMINE_CHIRP_TAPER / 2.0;
    double envelope = 1.0;
    if (x < half) envelope = 0.5 - 0.5 * cos(M_PI * x / half);
    else if (x > 1.0 - half) envelope = 0.5 - 0.5 * cos(M_PI * (1.0 - x) / half);
    const double tail = lround(sampleRate * DOMINE_CHIRP_TAIL_MS / 1000.0);
    const double intoTail = (double)n - ((double)length - tail);
    if (tail > 0.0 && intoTail > 0.0) envelope *= exp(-DOMINE_CHIRP_TAIL_DECAY * intoTail / tail);
    return DOMINE_CHIRP_AMPLITUDE * envelope * sin(phase);
}

float domine_calibration_chirp_sample(uint32_t n, double sampleRate, int rising) {
    if (!(sampleRate > 0.0)) return 0.0f;
    uint32_t length = (uint32_t)lround(sampleRate * DOMINE_CHIRP_MS / 1000.0);
    if (length < 2) length = 2;
    return (float)chirp_sample(n, length, sampleRate, rising);
}

void domine_calibration_chirp(float *out, uint32_t frames, double sampleRate, int rising) {
    if (out == NULL || sampleRate <= 0.0) return;
    uint32_t length = (uint32_t)lround(sampleRate * DOMINE_CHIRP_MS / 1000.0);
    if (length < 2) length = 2;
    for (uint32_t n = 0; n < frames; n++) out[n] = (float)chirp_sample(n, length, sampleRate, rising);
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

void domine_kernel_set_tap_layout(DomineKernel *k, uint32_t tapCount, const uint32_t *firstBuffer,
                                  const uint32_t *channels, const uint32_t *interleaved) {
    if (k == NULL) return;
    tapmix_set_layout(&k->taps, tapCount, firstBuffer, channels, interleaved);
}

void domine_kernel_set_tap_gain(DomineKernel *k, uint32_t tap, float gain) {
    if (k == NULL) return;
    tapmix_set_gain(&k->taps, tap, gain);
}

void domine_kernel_set_input_format(DomineKernel *k, uint32_t channelsPerFrame, int nonInterleaved) {
    if (k == NULL) return;
    atomic_store_explicit(&k->inputChannels, channelsPerFrame, memory_order_relaxed);
    atomic_store_explicit(&k->inputNonInterleaved, nonInterleaved != 0, memory_order_relaxed);
}

void domine_kernel_stats_reset_maxima(DomineKernel *k) {
    if (k == NULL) return;
    atomic_fetch_add_explicit(&k->statsResetRequests, 1, memory_order_relaxed);
}

int domine_kernel_stats(DomineKernel *k, DomineKernelStats *out) {
    if (k == NULL || out == NULL) return 0;
    uint64_t words[STATS_WORDS];
    int consistent = 0;
    for (int attempt = 0; attempt < 1000 && !consistent; attempt++) {
        const uint32_t before = atomic_load_explicit(&k->statsSeq, memory_order_acquire);
        for (size_t i = 0; i < STATS_WORDS; i++) {
            words[i] = atomic_load_explicit(&k->statsWords[i], memory_order_relaxed);
        }
        atomic_thread_fence(memory_order_acquire);
        const uint32_t after = atomic_load_explicit(&k->statsSeq, memory_order_relaxed);
        consistent = (before & 1u) == 0 && before == after;
    }
    memcpy(out, words, sizeof *out);
    out->sampleRate = k->sampleRate;
    out->layoutInFirstBuffer = atomic_load_explicit(&k->layoutInFirstBuffer, memory_order_relaxed);
    out->layoutOutA = atomic_load_explicit(&k->layoutOutA, memory_order_relaxed);
    out->layoutOutB = atomic_load_explicit(&k->layoutOutB, memory_order_relaxed);
    out->inputChannelsPerFrame = atomic_load_explicit(&k->inputChannels, memory_order_relaxed);
    out->inputNonInterleaved = (uint32_t)atomic_load_explicit(&k->inputNonInterleaved, memory_order_relaxed);
    out->fifoCapacity = k->fifoMask + 1;
    out->maxFrames = k->maxFrames;
    return consistent;
}

// Writer side of the seqlock. Render thread only.
static void publish_stats(DomineKernel *k) {
    uint64_t words[STATS_WORDS];
    memcpy(words, &k->stats, sizeof k->stats);
    const uint32_t seq = atomic_load_explicit(&k->statsSeq, memory_order_relaxed);
    atomic_store_explicit(&k->statsSeq, seq + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    for (size_t i = 0; i < STATS_WORDS; i++) {
        atomic_store_explicit(&k->statsWords[i], words[i], memory_order_relaxed);
    }
    atomic_store_explicit(&k->statsSeq, seq + 2, memory_order_release);
}

// Shared renderer. Step f first pushes input frame f into the FIFO (while
// f < inFrames), then pops one frame for output frame f (while f < frames),
// so equal counts pass straight through with no added latency and unequal
// counts never drop or stretch input.
static RenderResult render(DomineKernel *k,
                           const InChannel *inL,
                           const InChannel *inR,
                           const TapSet *tapSet,
                           uint32_t inFrames,
                           AudioBufferList *out,
                           uint32_t frames,
                           uint32_t outAChannelOffset,
                           uint32_t outBChannelOffset) {
    RenderResult result = { 0.0f, 0, 0 };

    // Zero every output channel first; the kernel then writes only its own.
    for (uint32_t b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *buf = &out->mBuffers[b];
        if (buf->mData != NULL) memset(buf->mData, 0, buf->mDataByteSize);
    }

    // Snapshot parameters once per cycle.
    const float gainA = bits_float(atomic_load_explicit(&k->gainABits, memory_order_relaxed));
    const float gainB = bits_float(atomic_load_explicit(&k->gainBBits, memory_order_relaxed));
    // The first call snaps to the target; later changes ramp over 30 ms.
    if (!k->gainPrimed) {
        k->gainPrimed = 1;
        k->gainCurA = k->gainTargetA = gainA;
        k->gainCurB = k->gainTargetB = gainB;
    }
    if (gainA != k->gainTargetA) {
        k->gainTargetA = gainA;
        k->gainLeftA = k->gainRampLength;
        k->gainStepA = (gainA - k->gainCurA) / (float)k->gainRampLength;
    }
    if (gainB != k->gainTargetB) {
        k->gainTargetB = gainB;
        k->gainLeftB = k->gainRampLength;
        k->gainStepB = (gainB - k->gainCurB) / (float)k->gainRampLength;
    }
    const int32_t delay = atomic_load_explicit(&k->delaySamples, memory_order_relaxed);
    const int monoPerSpeaker = atomic_load_explicit(&k->monoPerSpeaker, memory_order_relaxed);
    const int swap = atomic_load_explicit(&k->swapSides, memory_order_relaxed);
    const int monoFallback = atomic_load_explicit(&k->monoFallback, memory_order_relaxed);
    const int toneSide = atomic_load_explicit(&k->toneSide, memory_order_relaxed);
    const int muted = atomic_load_explicit(&k->muted, memory_order_relaxed);
    const int clickTest = atomic_load_explicit(&k->clickTest, memory_order_relaxed);
    const int keepAlive = atomic_load_explicit(&k->keepAlive, memory_order_relaxed);

    const uint32_t delayA = delay < 0 ? (uint32_t)(-delay) : 0;
    const uint32_t delayB = delay > 0 ? (uint32_t)delay : 0;
    const int bothChannels = monoPerSpeaker || monoFallback;

    OutChannel a0 = {0}, a1 = {0}, b0 = {0}, b1 = {0};
    const int hasA0 = map_out_channel(out, outAChannelOffset, &a0);
    const int hasB0 = map_out_channel(out, outBChannelOffset, &b0);
    const int hasA1 = bothChannels && outAChannelOffset != DOMINE_NO_DEVICE
        && map_out_channel(out, outAChannelOffset + 1, &a1);
    const int hasB1 = bothChannels && outBChannelOffset != DOMINE_NO_DEVICE
        && map_out_channel(out, outBChannelOffset + 1, &b1);

    const uint32_t mask = k->ringMask;
    const uint32_t fifoMask = k->fifoMask;
    const uint32_t fifoCapacity = fifoMask + 1;
    const uint32_t fadeTarget = muted ? 0 : k->fadeLength;
    float peakA = 0.0f, peakB = 0.0f;

    const uint32_t steps = inFrames > frames ? inFrames : frames;
    for (uint32_t f = 0; f < steps; f++) {
        if (f < inFrames) {
            float inLeft, inRight;
            if (tapSet != NULL) {
                tapmix_read(&k->taps, tapSet, f, &inLeft, &inRight);
            } else {
                inLeft = read_in(inL, f);
                inRight = read_in(inR, f);
            }
            if (fabsf(inLeft) > result.inputPeak) result.inputPeak = fabsf(inLeft);
            if (fabsf(inRight) > result.inputPeak) result.inputPeak = fabsf(inRight);
            if (k->fifoWrite - k->fifoRead == fifoCapacity) {
                k->fifoRead++;
                result.overflowFrames++;
            }
            k->fifoL[k->fifoWrite & fifoMask] = inLeft;
            k->fifoR[k->fifoWrite & fifoMask] = inRight;
            k->fifoWrite++;
        }
        if (f >= frames) continue;

        float l = 0.0f, r = 0.0f;
        if (k->fifoWrite != k->fifoRead) {
            l = k->fifoL[k->fifoRead & fifoMask];
            r = k->fifoR[k->fifoRead & fifoMask];
            k->fifoRead++;
        } else {
            result.underrunFrames++;
        }

        if (keepAlive) {
            const float lvl = fabsf(l) > fabsf(r) ? fabsf(l) : fabsf(r);
            if (lvl > KEEP_ALIVE_THRESHOLD) k->kaSilent = 0;
            else if (k->kaSilent < UINT32_MAX) k->kaSilent++;
        } else {
            k->kaSilent = 0;
        }

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

        // EFFECTS BLOCK (SPEC 5a): per position chain on the program source,
        // after mapping and before the click source, delay line and trim gain.
        // Order: EQ, bass enhancer, compressor/limiter. An idle stage is skipped.
        if (!domine_eq_is_idle(k->eq[0])) domine_eq_process(k->eq[0], &srcA, 1);
        if (!domine_eq_is_idle(k->eq[1])) domine_eq_process(k->eq[1], &srcB, 1);
        if (!domine_bass_is_idle(k->bass[0])) domine_bass_process(k->bass[0], &srcA, 1);
        if (!domine_bass_is_idle(k->bass[1])) domine_bass_process(k->bass[1], &srcB, 1);
        if (!domine_compressor_is_idle(k->comp[0])) domine_compressor_process(k->comp[0], &srcA, 1);
        if (!domine_compressor_is_idle(k->comp[1])) domine_compressor_process(k->comp[1], &srcB, 1);
        // END EFFECTS BLOCK

        // Click test: replaces the source before the delay line.
        if (clickTest == 1 || k->clickLevel != 0) click_mix(k, clickTest == 1, &srcA, &srcB);

        const uint32_t w = k->ringWrite;
        k->ringA[w] = srcA;
        k->ringB[w] = srcB;
        k->ringWrite = (w + 1) & mask;

        // Unity gain skips the multiply, so program audio passes bit for bit
        // even where the CPU flushes subnormals to zero.
        float outA = k->ringA[(w - delayA) & mask];
        float outB = k->ringB[(w - delayB) & mask];
        if (k->gainLeftA) {
            k->gainCurA = --k->gainLeftA ? k->gainCurA + k->gainStepA : k->gainTargetA;
        }
        if (k->gainLeftB) {
            k->gainCurB = --k->gainLeftB ? k->gainCurB + k->gainStepB : k->gainTargetB;
        }
        const float gainNowA = k->gainCurA, gainNowB = k->gainCurB;
        if (gainNowA != 1.0f) outA *= gainNowA;
        if (gainNowB != 1.0f) outB *= gainNowB;

        // Calibration chirps (click test mode 2): replace both positions after
        // the gains, bypassing the delay line. Rising on A, falling on B, both
        // starting on the same sample.
        if (clickTest == 2 || k->chirpLevel != 0) {
            const uint32_t full = k->toneFadeLength;
            float chirpA = 0.0f, chirpB = 0.0f;
            if (clickTest == 2 && k->chirpLevel == full) {
                const uint32_t n = k->chirpCounter;
                chirpA = (float)chirp_sample(n, k->chirpLength, k->sampleRate, 1);
                chirpB = (float)chirp_sample(n, k->chirpLength, k->sampleRate, 0);
                k->chirpCounter = n + 1 < k->clickPeriod ? n + 1 : 0;
            } else {
                k->chirpCounter = 0;
            }
            if (gainNowA != 1.0f) chirpA *= gainNowA;
            if (gainNowB != 1.0f) chirpB *= gainNowB;
            if (k->chirpLevel == full) {
                outA = chirpA;
                outB = chirpB;
            } else {
                const float keep = 1.0f - (float)k->chirpLevel / (float)full;
                outA = outA * keep + chirpA;
                outB = outB * keep + chirpB;
            }
            const uint32_t chirpTarget = clickTest == 2 ? full : 0;
            if (k->chirpLevel < chirpTarget) k->chirpLevel++;
            else if (k->chirpLevel > chirpTarget) k->chirpLevel--;
        }

        // A new request takes over only once the current tone has faded out.
        if (k->toneLevel == 0 && k->playingToneSide != toneSide) {
            k->playingToneSide = toneSide;
            k->tonePhase = 0.0;
        }
        if (k->playingToneSide != 0) {
            const float tone = (float)domine_chime_sample(k->tonePhase);
            k->tonePhase += k->tonePhaseStep;
            if (k->tonePhase >= DOMINE_CHIME_PERIOD_S) k->tonePhase -= DOMINE_CHIME_PERIOD_S;
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

        // Keep-alive: a 15 Hz sine at -60 dBFS after 2 s of silence, so
        // speakers do not power off. Fades in over 50 ms, out over 10 ms.
        // Absent while muted or while a tone, click or chirp is playing.
        if (keepAlive || k->kaLevel > 0.0f) {
            const int quiet = keepAlive && !muted && toneSide == 0 && k->playingToneSide == 0
                && clickTest == 0 && k->clickLevel == 0 && k->chirpLevel == 0;
            const uint32_t hold = (uint32_t)lround(k->sampleRate * KEEP_ALIVE_HOLD_S);
            if (quiet && k->kaSilent >= hold) {
                k->kaLevel += (float)(1.0 / (k->sampleRate * KEEP_ALIVE_FADE_IN_S));
                if (k->kaLevel > 1.0f) k->kaLevel = 1.0f;
            } else {
                k->kaLevel -= (float)(1.0 / (k->sampleRate * KEEP_ALIVE_FADE_OUT_S));
                if (k->kaLevel < 0.0f) k->kaLevel = 0.0f;
            }
            if (k->kaLevel > 0.0f) {
                const float ka = (float)(KEEP_ALIVE_AMPLITUDE * sin(2.0 * M_PI * k->kaPhase)) * k->kaLevel;
                outA += ka;
                outB += ka;
            }
            k->kaPhase += KEEP_ALIVE_HZ / k->sampleRate;
            if (k->kaPhase >= 1.0) k->kaPhase -= 1.0;
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
    return result;
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
    InChannel inL, inR;
    TapSet tapSet;
    const int useTaps = tapmix_begin(&k->taps);
    uint32_t inFrames = frames;
    if (useTaps) {
        inFrames = tapmix_resolve(&k->taps, in, &tapSet, NULL);
    } else {
        (void)resolve_input(inBuffers, inCount,
                            atomic_load_explicit(&k->inputChannels, memory_order_relaxed),
                            atomic_load_explicit(&k->inputNonInterleaved, memory_order_relaxed),
                            &inL, &inR);
    }
    (void)render(k, &inL, &inR, useTaps ? &tapSet : NULL, inFrames, out, frames, outAChannelOffset, outBChannelOffset);
}

OSStatus domine_kernel_ioproc(AudioObjectID inDevice,
                              const AudioTimeStamp *inNow,
                              const AudioBufferList *inInputData,
                              const AudioTimeStamp *inInputTime,
                              AudioBufferList *outOutputData,
                              const AudioTimeStamp *inOutputTime,
                              void *inClientData) {
    (void)inDevice;
    DomineKernel *k = (DomineKernel *)inClientData;
    if (k == NULL || outOutputData == NULL) return 0;

    const uint32_t first = atomic_load_explicit(&k->layoutInFirstBuffer, memory_order_relaxed);
    const uint32_t outA = atomic_load_explicit(&k->layoutOutA, memory_order_relaxed);
    const uint32_t outB = atomic_load_explicit(&k->layoutOutB, memory_order_relaxed);
    const uint32_t formatChannels = atomic_load_explicit(&k->inputChannels, memory_order_relaxed);
    const int formatNonInterleaved = atomic_load_explicit(&k->inputNonInterleaved, memory_order_relaxed);

    uint32_t frames = 0;
    uint32_t outputMin = UINT32_MAX;
    for (uint32_t b = 0; b < outOutputData->mNumberBuffers; b++) {
        const AudioBuffer *buf = &outOutputData->mBuffers[b];
        if (buf->mNumberChannels == 0) continue;
        const uint32_t n = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
        if (n > frames) frames = n;
        if (n < outputMin) outputMin = n;
    }
    if (outputMin == UINT32_MAX) outputMin = 0;

    const AudioBuffer *inBuffers = NULL;
    uint32_t inCount = 0;
    if (inInputData != NULL && first < inInputData->mNumberBuffers) {
        inBuffers = inInputData->mBuffers + first;
        inCount = inInputData->mNumberBuffers - first;
    }
    InChannel inL, inR;
    TapSet tapSet;
    const int useTaps = tapmix_begin(&k->taps);
    int formatMismatch = 0;
    int missing;
    uint32_t inFrames;
    if (useTaps) {
        inFrames = tapmix_resolve(&k->taps, inInputData, &tapSet, &missing);
    } else {
        formatMismatch = resolve_input(inBuffers, inCount, formatChannels, formatNonInterleaved, &inL, &inR);
        inFrames = input_frames(&inL, &inR);
        missing = inL.data == NULL;
    }

    DomineKernelStats *st = &k->stats;
    const uint32_t resetRequests = atomic_load_explicit(&k->statsResetRequests, memory_order_relaxed);
    if (resetRequests != k->statsResetsSeen) {
        k->statsResetsSeen = resetRequests;
        st->maxCycleInterval = 0;
        st->maxInputPeak = 0.0f;
        st->maximaResets++;
    }

    const RenderResult r = render(k, &inL, &inR, useTaps ? &tapSet : NULL, inFrames, outOutputData, frames, outA, outB);

    st->cycles++;
    st->frames += frames;
    st->inputFrames += inFrames;
    if (missing) st->inputMissingCycles++;
    else if (inFrames < frames) st->inputShortCycles++;
    if (inFrames > frames) st->inputLongCycles++;
    if (!missing && r.inputPeak == 0.0f) st->inputSilentCycles++;
    if (outputMin != frames) st->outputMismatchCycles++;
    if (formatMismatch) st->formatMismatchCycles++;
    st->underrunFrames += r.underrunFrames;
    st->overflowFrames += r.overflowFrames;

    uint32_t flags = 0;
    if (inNow->mFlags & kAudioTimeStampHostTimeValid) flags |= DOMINE_STATS_NOW_HOST_VALID;
    if (inInputTime->mFlags & kAudioTimeStampHostTimeValid) flags |= DOMINE_STATS_INPUT_HOST_VALID;
    if (inInputTime->mFlags & kAudioTimeStampSampleTimeValid) flags |= DOMINE_STATS_INPUT_SAMPLE_VALID;
    if (inOutputTime->mFlags & kAudioTimeStampHostTimeValid) flags |= DOMINE_STATS_OUTPUT_HOST_VALID;
    if (inOutputTime->mFlags & kAudioTimeStampSampleTimeValid) flags |= DOMINE_STATS_OUTPUT_SAMPLE_VALID;
    const int nowHostValid = (flags & DOMINE_STATS_NOW_HOST_VALID) != 0;
    const int outputSampleValid = (flags & DOMINE_STATS_OUTPUT_SAMPLE_VALID) != 0;
    st->timeFlags = flags;
    st->nowHostTime = nowHostValid ? inNow->mHostTime : 0;
    st->inputHostTime = (flags & DOMINE_STATS_INPUT_HOST_VALID) ? inInputTime->mHostTime : 0;
    st->outputHostTime = (flags & DOMINE_STATS_OUTPUT_HOST_VALID) ? inOutputTime->mHostTime : 0;
    st->inputSampleTime = (flags & DOMINE_STATS_INPUT_SAMPLE_VALID) ? inInputTime->mSampleTime : 0.0;
    st->outputSampleTime = outputSampleValid ? inOutputTime->mSampleTime : 0.0;

    if (nowHostValid) {
        if (k->prevNowHostTime != 0 && inNow->mHostTime > k->prevNowHostTime) {
            const uint64_t interval = inNow->mHostTime - k->prevNowHostTime;
            if (interval > st->maxCycleInterval) st->maxCycleInterval = interval;
        }
        k->prevNowHostTime = inNow->mHostTime;
    }
    if (outputSampleValid) {
        if (k->prevOutputSampleValid
            && inOutputTime->mSampleTime != k->prevOutputSampleTime + (double)k->prevFrames) {
            st->sampleTimeJumps++;
        }
        k->prevOutputSampleTime = inOutputTime->mSampleTime;
    }
    k->prevOutputSampleValid = outputSampleValid;
    k->prevFrames = frames;

    st->lastFrames = frames;
    st->lastInputFrames = inFrames;
    st->lastInputBuffers = inCount;
    st->lastInputChannels = inCount > 0 ? inBuffers[0].mNumberChannels : 0;
    st->lastOutputBuffers = outOutputData->mNumberBuffers;
    st->lastOutputFramesMin = outputMin;
    st->fifoFill = k->fifoWrite - k->fifoRead;
    st->lastInputPeak = r.inputPeak;
    if (r.inputPeak > st->maxInputPeak) st->maxInputPeak = r.inputPeak;

    publish_stats(k);
    return 0;
}
