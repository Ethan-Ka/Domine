#ifndef DOMINE_QUAD_H
#define DOMINE_QUAD_H

// Four-position render kernel (SPEC section 11.2). Additive: the stereo
// DomineKernel API is unchanged. Positions: 0 FL, 1 FR, 2 RL, 3 RR.
//
// Threading: setters and peak use C11 atomics only (effects setters follow the
// stereo kernel: the effect modules take parameters atomically). process runs
// on the real-time thread and never allocates, locks, logs, or does I/O.
// create and destroy allocate and free; call them while no IOProc uses it.

#include <stdint.h>
#include <CoreAudio/CoreAudioTypes.h>
#include "DomineDSP.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

typedef struct DomineQuad DomineQuad;

#define DOMINE_QUAD_POSITIONS 4
/// Rear derivation modes. Direct needs multichannel input (11.5, not yet
/// implemented) and behaves as mirror for stereo input.
#define DOMINE_REAR_MIRROR 0
#define DOMINE_REAR_MATRIX 1
#define DOMINE_REAR_DIRECT 2
/// Matrix scale: rearL = k(L - 0.5R), rearR = k(R - 0.5L), k = 1 / 1.5.
#define DOMINE_REAR_MATRIX_K (1.0f / 1.5f)

/// Delay rings hold 300 ms at 96 kHz (or at sampleRate if higher).
DomineQuad *_Nullable domine_quad_create(double sampleRate, uint32_t maxFrames);
void domine_quad_destroy(DomineQuad *_Nullable q);

/// Trim gain for position pos (0..3), clamped to 0..1 (never adds gain). At
/// exactly 1.0 samples are copied. Changes after the first process call ramp
/// linearly over round(0.03 * sampleRate) samples. Default 1.
void domine_quad_set_gain(DomineQuad *q, int pos, float gain);
/// Delay in ms for position pos, clamped to 0..DOMINE_MAX_DELAY_MS (never
/// negative), in samples round(ms * sampleRate / 1000). Default 0.
void domine_quad_set_delay_ms(DomineQuad *q, int pos, float ms);
/// Rear mode (DOMINE_REAR_*, other values are mirror) and rear trim (0..1,
/// default 1) applied to RL and RR after derivation.
void domine_quad_set_rear_mode(DomineQuad *q, int mode);
void domine_quad_set_rear_trim(DomineQuad *q, float gain);
/// Effects per position, run in order EQ, bass, compressor, then gain, then delay.
void domine_quad_set_eq(DomineQuad *q, int pos, const DomineEQParams *params);
void domine_quad_set_bass(DomineQuad *q, int pos, const DomineBassParams *params);
void domine_quad_set_compressor(DomineQuad *q, int pos, const DomineCompressorParams *params);

/// Renders `frames` frames. out_offsets points to 4 values. `in` is the tap (interleaved stereo, deinterleaved
/// stereo, or mono; NULL is silence). out_offsets[pos] is the flat output
/// channel index of position pos, or DOMINE_NO_DEVICE if absent. A present
/// position writes its signal on offset and offset + 1. Unwritten output
/// channels are zeroed. Fronts: both present, FL = L, FR = R. One front
/// present: it plays (L + R) / 2. Rears derive from the rear mode; one rear
/// present: it plays the rear mono sum (RL + RR) / 2. Only one speaker present
/// overall: it plays (L + R) / 2. Missing fronts with both rears present leave
/// the rears as derived.
void domine_quad_process(DomineQuad *q,
                         const AudioBufferList *_Nullable in,
                         AudioBufferList *_Nullable out,
                         uint32_t frames,
                         const uint32_t *out_offsets);

/// IOProc layout (set before the device starts): index of the tap's first
/// input buffer, the 4 output offsets (DOMINE_NO_DEVICE if absent), and the tap
/// format (channels per frame, 0 unknown).
void domine_quad_set_layout(DomineQuad *q, uint32_t inFirstBuffer, const uint32_t *out_offsets);
void domine_quad_set_input_format(DomineQuad *q, uint32_t channelsPerFrame, int nonInterleaved);

/// AudioDeviceIOProc for the quad kernel; client data is the DomineQuad. Same
/// input-buffer handling as domine_kernel_ioproc. Always returns 0.
OSStatus domine_quad_ioproc(AudioObjectID inDevice,
                            const AudioTimeStamp *inNow,
                            const AudioBufferList *inInputData,
                            const AudioTimeStamp *inInputTime,
                            AudioBufferList *outOutputData,
                            const AudioTimeStamp *inOutputTime,
                            void *_Nullable inClientData);

/// Peak absolute value written to a position in the last process call.
float domine_quad_peak(DomineQuad *q, int pos);

#pragma clang assume_nonnull end
#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
