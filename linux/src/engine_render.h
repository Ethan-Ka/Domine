// Domine for Linux: the PipeWire-independent render path (private to the
// engine). One capture callback feeds the DomineSurround kernel; each
// speaker's stereo pair goes into its own SPSC ring; each playback callback
// drains its ring. dl_render_capture and dl_render_pull are real-time safe
// (no allocation, no locks, no logging, no I/O). The other functions run on
// control threads (GTK main thread or the PipeWire main loop thread) and are
// serialized by a mutex that the real-time side never takes.
//
// Clock drift between the capture clock and each speaker's clock is handled
// with watermarks, not resampling: a playback side waits until its ring holds
// `target` frames before it starts (priming), zero-fills and primes again on
// an underrun, and when the ring holds more than `high` frames it discards
// the oldest frames down to `target`. Each correction is an audible glitch,
// rare with typical drift (at 50 ppm, 2.4 frames per second at 48 kHz,
// one correction every few minutes with the default watermarks). Adaptive resampling per speaker is the follow-up.
//
// Post-kernel stages on the capture thread, in order:
//   click test: a click on every present speaker, delayed by that speaker's
//     delay (distance compensation plus manual offset) and scaled by its gain,
//     crossfaded with program audio exactly like the macOS kernel's click test
//     (DomineDSP.h, domine_kernel_set_click_test mode 1).
//   test tone: the shared chime (DomineChime.h) on one speaker, the others
//     silent, crossfaded over DOMINE_TONE_FADE_MS like the macOS kernel. The
//     tone ignores gain and delay.
//
// Mono fallback: when a layout of 2 or more speakers has exactly one present,
// the kernel is reconfigured as a 1-speaker layout on that speaker, so it
// plays (L + R) / 2 (DomineSurround.h), the same as the macOS mono fallback.
// With 2 or more present, absent speakers are DOMINE_NO_DEVICE and VBAP
// re-pans their share to their neighbours.
#ifndef DOMINE_LINUX_ENGINE_RENDER_H
#define DOMINE_LINUX_ENGINE_RENDER_H

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include "engine.h"
#include "engine_ring.h"
#include "DomineSurround.h"
#include "DomineEQ.h"
#include "DomineBass.h"
#include "DomineCompressor.h"

#define DL_NO_SPEAKER UINT32_MAX

typedef struct {
    DomineSurround *kernel;
    double rate;
    uint32_t count;            // speakers, fixed for the render's lifetime
    uint32_t maxFrames;        // kernel chunk size
    uint32_t target, high;     // ring watermarks in frames
    float *scratch;            // 2 * count * maxFrames, kernel output (one interleaved buffer)
    float *pair;               // 2 * maxFrames, one speaker's pair before the ring
    float *ringData;           // backing store of all rings
    DLRing rings[DL_MAX_SPEAKERS];

    // Control side, guarded by lock.
    pthread_mutex_t lock;
    DLSpeaker speakers[DL_MAX_SPEAKERS];
    float manualDelayMs[DL_MAX_SPEAKERS];
    float master;
    uint8_t hasEq[DL_MAX_SPEAKERS], hasBass[DL_MAX_SPEAKERS], hasComp[DL_MAX_SPEAKERS];
    DomineEQParams eq[DL_MAX_SPEAKERS];
    DomineBassParams bass[DL_MAX_SPEAKERS];
    DomineCompressorParams comp[DL_MAX_SPEAKERS];
    uint32_t appliedMono;      // speaker the kernel is configured for in mono mode, or DL_NO_SPEAKER

    // Crossing threads (atomics).
    _Atomic uint32_t present[DL_MAX_SPEAKERS];
    _Atomic uint32_t mono;                       // DL_NO_SPEAKER or the single present speaker
    _Atomic uint32_t gainBits[DL_MAX_SPEAKERS];  // effective gain, for the click
    _Atomic uint32_t delayFrames[DL_MAX_SPEAKERS];
    _Atomic uint32_t peakBits[DL_MAX_SPEAKERS];
    _Atomic int32_t toneReq;                     // speaker or -1
    _Atomic uint32_t clickReq;
    _Atomic uint32_t underruns[DL_MAX_SPEAKERS];
    _Atomic uint32_t drops[DL_MAX_SPEAKERS];     // high-watermark corrections
    _Atomic uint32_t overflows[DL_MAX_SPEAKERS]; // frames lost because a ring was full

    // Capture thread only.
    uint32_t fadeLen;          // DOMINE_TONE_FADE_MS in frames
    uint32_t toneP, clickC;
    int32_t toneCur;
    uint64_t toneT;
    uint32_t clickN, clickPeriod, clickLen;
    // Playback threads only (one entry each).
    uint8_t primed[DL_MAX_SPEAKERS];
} DLRender;

/// ringFrames is rounded up to a power of two. Speakers start absent.
/// Returns NULL on allocation failure or a count outside 1...DL_MAX_SPEAKERS.
DLRender *dl_render_create(double sampleRate, uint32_t count, uint32_t maxFrames,
                           uint32_t ringFrames, uint32_t target, uint32_t high);
void dl_render_destroy(DLRender *r);

/// Speaker layout, trims and distances (first r->count entries) and master
/// volume. Gain of speaker i is trim * distance gain * master; its delay is
/// distance compensation plus its manual delay, clamped to DOMINE_MAX_DELAY_MS.
void dl_render_configure(DLRender *r, const DLSpeaker *speakers, uint32_t count, float master);
void dl_render_set_master(DLRender *r, float master);
void dl_render_set_manual_delay(DLRender *r, uint32_t speaker, float ms);
void dl_render_set_eq(DLRender *r, uint32_t speaker, const DomineEQParams *p);
void dl_render_set_bass(DLRender *r, uint32_t speaker, const DomineBassParams *p);
void dl_render_set_compressor(DLRender *r, uint32_t speaker, const DomineCompressorParams *p);

/// Marks a speaker present (it plays) or absent. Re-pans, and switches to or
/// from mono fallback when exactly one speaker is left.
void dl_render_set_present(DLRender *r, uint32_t speaker, int present);
/// Test tone on one speaker (-1 off) and click test (0 off, 1 on).
void dl_render_set_test_tone(DLRender *r, int speaker);
void dl_render_set_click_test(DLRender *r, int on);
/// Peak absolute value written for a speaker in the last capture cycle.
float dl_render_peak(DLRender *r, uint32_t speaker);

/// Capture thread: renders `frames` frames of interleaved stereo input
/// (NULL is silence) and pushes each present speaker's pair into its ring.
void dl_render_capture(DLRender *r, const float *in, uint32_t frames);

/// Playback thread of speaker i: writes `frames` interleaved stereo frames
/// to dst, zero-filling what the ring cannot supply.
void dl_render_pull(DLRender *r, uint32_t speaker, float *dst, uint32_t frames);

/// The click test sample n frames after a click starts (0 past its end), as
/// in DomineDSP.h. Exposed for the self-test.
float dl_click_sample(uint32_t n, double sampleRate);

#endif
