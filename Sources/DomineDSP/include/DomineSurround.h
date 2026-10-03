#ifndef DOMINE_SURROUND_H
#define DOMINE_SURROUND_H

// N-speaker surround render kernel (SPEC section 13). Replaces the quad
// kernel: 1 to DOMINE_SURROUND_MAX_SPEAKERS speakers at any azimuth, fed by
// 2D pairwise vector base amplitude panning (VBAP) of a small set of virtual
// sources derived from the stereo tap:
//
//   source 0: L at azimuth -width   (direct, front left)
//   source 1: R at azimuth +width   (direct, front right)
//   source 2: ambience RL at -DOMINE_SURROUND_REAR_AZ, times surround level
//   source 3: ambience RR at +DOMINE_SURROUND_REAR_AZ, times surround level
//   source 4..: demo voices (DomineDemo.h) while the demo plays
//
// Ambience comes from the spatial upmixer (DomineSpatial.h). Sources 2 and 3
// are only used with 3 or more PRESENT speakers (absent ones, with a
// DOMINE_NO_DEVICE offset, do not count), so 2 speakers at -width and +width
// play L and R bit for bit, and 1 speaker plays (L + R) / 2 bit for bit
// (computed as 0.5 * L + 0.5 * R, which equals 0.5 * (L + R) exactly).
// Every source azimuth is offset by rotation (static) plus the orbit phase.
// Demo voices are not rotated, so roll-call kicks sit on the speakers.
//
// Headroom: the pan gains G[source][speaker] of the program sources (0 to 3)
// are VBAP gains (each source has unit power), times the surround level for
// sources 2 and 3. Each speaker's program column is then scaled by
// 1 / max(1, sum over program sources of |G|), so a speaker never exceeds
// full scale for program inputs within +-1 (before effects). The matrix is
// recomputed at the start of every process call (orbit phase at the end of
// the call) and ramps linearly from the previous one across the call.
//
// Azimuth convention: degrees, 0 is straight ahead of the listener, positive
// is clockwise seen from above (to the right), range (-180, 180]. Any finite
// value is accepted and wrapped.
//
// Threading: setters, peak and demo status use C11 atomics only (speaker
// layout through a seqlock). process and ioproc run on the real-time thread
// and never allocate, lock, log, or do I/O. create and destroy allocate and
// free; call them while no IOProc uses the kernel.

#include <stdint.h>
#include <CoreAudio/CoreAudioTypes.h>
#include "DomineDSP.h"
#include "DomineSpatial.h"
#include "DomineDemo.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

typedef struct DomineSurround DomineSurround;

#define DOMINE_SURROUND_MAX_SPEAKERS 16
/// Azimuth of the two ambience sources (ITU surround position).
#define DOMINE_SURROUND_REAR_AZ 110.0f
/// Default and limits of the stage width (azimuth of the L and R sources).
#define DOMINE_SURROUND_WIDTH_DEFAULT 30.0f
#define DOMINE_SURROUND_WIDTH_MIN 10.0f
#define DOMINE_SURROUND_WIDTH_MAX 90.0f
/// Speed of sound used by domine_surround_distance_comp, m/s.
#define DOMINE_SPEED_OF_SOUND 343.0f
/// Speakers closer than this (degrees) count as one position and share
/// the pan gain equally by power.
#define DOMINE_SURROUND_COINCIDENT_DEG 0.5f

/// Delay rings hold DOMINE_MAX_DELAY_MS at 96 kHz (or at sampleRate if higher).
DomineSurround *_Nullable domine_surround_create(double sampleRate, uint32_t maxFrames);
void domine_surround_destroy(DomineSurround *_Nullable s);

/// Speaker layout: count speakers (clamped to 0...MAX), azimuth of each in
/// degrees. Index i is speaker i everywhere else in this API. Pan gains are
/// recomputed on the render thread at the next process call and ramp from the
/// old values over that call (no zipper, no click). The first process call
/// snaps. NULL azimuths with count > 0 are ignored.
void domine_surround_set_speakers(DomineSurround *s, uint32_t count, const float *_Nullable azimuthDeg);

/// Azimuth of the L and R sources, clamped to WIDTH_MIN...WIDTH_MAX. Default 30.
void domine_surround_set_width(DomineSurround *s, float degrees);
/// Static rotation of the whole sound field in degrees (wrapped). Default 0.
void domine_surround_set_rotation(DomineSurround *s, float degrees);
/// Continuous rotation ("orbit") in degrees per second, clamped to +-720.
/// 0 (default) stops it where it is; domine_surround_reset_orbit returns the
/// phase to 0 at the next process call.
void domine_surround_set_orbit_rate(DomineSurround *s, float degreesPerSecond);
void domine_surround_reset_orbit(DomineSurround *s);
/// Level of the ambience sources, 0...1, default 0.7.
void domine_surround_set_surround_level(DomineSurround *s, float level);
/// Ambience parameters (forwarded to the spatial upmixer). Default amount 0.6.
void domine_surround_set_spatial(DomineSurround *s, const DomineSpatialParams *params);

/// Per-speaker trim gain 0...1 (ramped over 30 ms after the first process
/// call) and delay in ms 0...DOMINE_MAX_DELAY_MS, like the quad kernel.
void domine_surround_set_gain(DomineSurround *s, uint32_t speaker, float gain);
void domine_surround_set_delay_ms(DomineSurround *s, uint32_t speaker, float ms);
/// Per-speaker effects, in order EQ, bass, compressor, then gain, then delay.
void domine_surround_set_eq(DomineSurround *s, uint32_t speaker, const DomineEQParams *params);
void domine_surround_set_bass(DomineSurround *s, uint32_t speaker, const DomineBassParams *params);
void domine_surround_set_compressor(DomineSurround *s, uint32_t speaker, const DomineCompressorParams *params);

/// Mute with the 50 ms fade (DOMINE_FADE_MS), same contract as the quad kernel.
void domine_surround_set_muted(DomineSurround *s, int muted);
void domine_surround_start_faded_out(DomineSurround *s);

/// Test tone: speaker index plays the shared chime (DomineChime.h) in place of
/// program audio and the other speakers are silent; -1 (or any value out of
/// range) is off. Same contract as domine_kernel_set_test_tone: 40 ms
/// (DOMINE_TONE_FADE_MS) crossfade against program audio, a new request takes
/// over once the current tone has faded out, the tone ignores pan, trim gain
/// and delay, and follows the mute fade. Default -1.
void domine_surround_set_test_tone(DomineSurround *s, int speaker);
/// Click test (nonzero on): the stereo kernel's mode 1 click (Hann-windowed
/// 2 kHz, 2 ms, 0.5 peak, every 1000 ms; DOMINE_CLICK_*) fed to every speaker
/// on the same sample in place of program audio, after the effects and
/// before the trim gain and delay line, so each speaker's gain and delay
/// apply to it exactly as to program audio (that is what lines the speakers
/// up by ear). Crossfades with program audio over 40 ms like the stereo
/// kernel. Default off.
void domine_surround_set_click_test(DomineSurround *s, int on);

/// Demo (DomineDemo.h). on nonzero starts it from 0 s (restarts if playing);
/// 0 stops it. Program audio crossfades out over 50 ms while the demo plays
/// and back in when it stops or finishes. The demo runs through the same
/// per-speaker effects, gain, delay and mute as program audio.
void domine_surround_set_demo(DomineSurround *s, int on);
/// Demo status for the UI, safe from any thread. Returns nonzero while the
/// demo plays. Out pointers may be NULL. azimuth is the main moving voice in
/// degrees (field rotation not applied); section is a DOMINE_DEMO_SECTION_*.
int domine_surround_demo_status(DomineSurround *s, float *_Nullable seconds,
                                float *_Nullable azimuth, int *_Nullable section);

/// Renders `frames` frames. `in` is the tap (same rules as the quad kernel:
/// interleaved stereo, deinterleaved stereo, or mono; NULL is silence).
/// out_offsets has one flat output channel index per speaker in the current
/// layout (count from set_speakers), DOMINE_NO_DEVICE for one that is absent.
/// A present speaker writes its signal on offset and offset + 1 (mono Grips
/// need both). Unwritten output channels are zeroed. An absent speaker is
/// left out of panning for this call (its share goes to its neighbours).
void domine_surround_process(DomineSurround *s,
                             const AudioBufferList *_Nullable in,
                             AudioBufferList *_Nullable out,
                             uint32_t frames,
                             const uint32_t *out_offsets);

/// Multi-tap input, same contract as domine_quad_set_tap_layout / _tap_gain.
void domine_surround_set_tap_layout(DomineSurround *s, uint32_t tapCount, const uint32_t *_Nullable firstBuffer,
                                    const uint32_t *_Nullable channels, const uint32_t *_Nullable interleaved);
void domine_surround_set_tap_gain(DomineSurround *s, uint32_t tap, float gain);

/// IOProc layout (set before the device starts): first tap input buffer and
/// `count` output offsets (count is clamped to MAX; speakers beyond count are
/// absent). Tap format: channels per frame (0 unknown).
void domine_surround_set_layout(DomineSurround *s, uint32_t inFirstBuffer, uint32_t count, const uint32_t *out_offsets);
void domine_surround_set_input_format(DomineSurround *s, uint32_t channelsPerFrame, int nonInterleaved);

/// AudioDeviceIOProc; client data is the DomineSurround. Always returns 0.
OSStatus domine_surround_ioproc(AudioObjectID inDevice,
                                const AudioTimeStamp *inNow,
                                const AudioBufferList *inInputData,
                                const AudioTimeStamp *inInputTime,
                                AudioBufferList *outOutputData,
                                const AudioTimeStamp *inOutputTime,
                                void *_Nullable inClientData);

/// Peak absolute value written to a speaker in the last process call.
float domine_surround_peak(DomineSurround *s, uint32_t speaker);

// Pure helpers (any thread, no state). Exposed for the UI and tests.

/// VBAP gains for one source at sourceAz over `count` speakers. Writes
/// count gains to gainsOut, sum of squares 1 (count >= 1). present may be
/// NULL (all present); a zero entry leaves that speaker out (gain 0).
/// Rules: one speaker gets 1. The source pans between the two adjacent
/// speakers that enclose it. If that arc is under 180 degrees the gains solve
/// the 2D VBAP equation, normalised to unit power. If the arc is 180 degrees
/// or wider (a gap, such as behind a front-only pair) the gains are
/// constant-power by angle fraction across the arc: cos(f * pi/2), sin(f *
/// pi/2). Coincident speakers (within COINCIDENT_DEG) share by power equally.
/// A source exactly on a speaker gives that speaker 1 (or its coincident
/// group 1/sqrt(k) each).
void domine_surround_vbap(uint32_t count, const float *azimuthDeg, const uint8_t *_Nullable present,
                          float sourceAz, float *gainsOut);

/// Distance compensation from listener distances in metres (non-positive or
/// non-finite treated as 1 m). The farthest speaker gets delay 0 and gain 1;
/// speaker i gets delay (dmax - d_i) / DOMINE_SPEED_OF_SOUND seconds (in ms)
/// and gain d_i / dmax (inverse distance law), so all arrive together at the
/// same level. Either output may be NULL.
void domine_surround_distance_comp(uint32_t count, const float *distanceM,
                                   float *_Nullable delayMsOut, float *_Nullable gainOut);

#pragma clang assume_nonnull end
#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
