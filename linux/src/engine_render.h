// Domine for Linux: the PipeWire-independent render path (private to the
// engine). One capture callback feeds the DomineSurround kernel; each
// speaker's stereo pair goes into its own SPSC ring; each playback callback
// drains its ring. Everything here except create, destroy and configure is
// real-time safe (no allocation, no locks, no logging, no I/O).
//
// Clock drift between the capture clock and each speaker's clock is handled
// with watermarks, not resampling: a playback side waits until its ring holds
// `target` frames before it starts (priming), zero-fills and primes again on
// an underrun, and when the ring holds more than `high` frames it discards
// the oldest frames down to `target`. Each correction is an audible glitch,
// rare with a few ppm of drift (about one every few minutes at 50 ppm with
// the default watermarks). Adaptive resampling per speaker is the follow-up.
#ifndef DOMINE_LINUX_ENGINE_RENDER_H
#define DOMINE_LINUX_ENGINE_RENDER_H

#include <stdatomic.h>
#include <stdint.h>
#include "engine.h"
#include "engine_ring.h"
#include "DomineSurround.h"

typedef struct {
    DomineSurround *kernel;
    uint32_t count;            // speakers, fixed for the render's lifetime
    uint32_t maxFrames;        // kernel chunk size
    uint32_t target, high;     // ring watermarks in frames
    float *scratch;            // 2 * count * maxFrames, kernel output (one interleaved buffer)
    float *pair;               // 2 * maxFrames, one speaker's pair before the ring
    float *ringData;           // backing store of all rings
    DLRing rings[DL_MAX_SPEAKERS];
    _Atomic uint32_t present[DL_MAX_SPEAKERS];   // control side writes, both RT sides read
    _Atomic uint32_t underruns[DL_MAX_SPEAKERS];
    _Atomic uint32_t drops[DL_MAX_SPEAKERS];     // high-watermark corrections
    _Atomic uint32_t overflows[DL_MAX_SPEAKERS]; // frames lost because a ring was full
    uint8_t primed[DL_MAX_SPEAKERS];             // consumer side only
} DLRender;

/// ringFrames is rounded up to a power of two. Speakers start absent.
/// Returns NULL on allocation failure.
DLRender *dl_render_create(double sampleRate, uint32_t count, uint32_t maxFrames,
                           uint32_t ringFrames, uint32_t target, uint32_t high);
void dl_render_destroy(DLRender *r);

/// Control thread: speaker layout, trims, distance compensation and master
/// volume, all applied as kernel parameters. Gain of speaker i is
/// trim * distance gain * master. Uses the first r->count entries.
void dl_render_configure(DLRender *r, const DLSpeaker *speakers, uint32_t count, float master);

/// Control thread: marks a speaker present (it plays) or absent (VBAP
/// re-pans its share to the others and its ring is no longer fed).
void dl_render_set_present(DLRender *r, uint32_t speaker, int present);

/// Capture thread: renders `frames` frames of interleaved stereo input
/// (NULL is silence) and pushes each present speaker's pair into its ring.
void dl_render_capture(DLRender *r, const float *in, uint32_t frames);

/// Playback thread of speaker i: writes `frames` interleaved stereo frames
/// to dst, zero-filling what the ring cannot supply.
void dl_render_pull(DLRender *r, uint32_t speaker, float *dst, uint32_t frames);

#endif
