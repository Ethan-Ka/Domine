#ifndef DOMINE_TONE_H
#define DOMINE_TONE_H

// Identification tone for one output device. Used by the Choose Speaker
// sheet's "Play tone" button: an IOProc on that device alone writes a short
// 440 Hz sine to every channel, so the user hears which physical speaker it is
// without the engine running.
//
// Threading: domine_tone_ioproc runs on the real-time audio thread. It reads
// and writes only the tone struct and the output buffers; the remaining frame
// count is a C11 atomic so domine_tone_finished can be read from any thread.
// domine_tone_create and domine_tone_destroy allocate and free, so call them
// only while no IOProc is using the tone.

#include <CoreAudio/CoreAudioTypes.h>
#include <CoreAudio/AudioHardwareBase.h> // AudioObjectID only; no Core Audio calls

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

#define DOMINE_IDENT_TONE_HZ 440.0
#define DOMINE_IDENT_TONE_AMPLITUDE 0.2
/// Linear fade at each end, so the tone starts and stops without a click.
#define DOMINE_IDENT_TONE_FADE_MS 40.0

typedef struct DomineTone DomineTone;

/// A tone of `seconds` at `sampleRate`. Returns NULL if allocation fails or
/// the arguments are not positive.
DomineTone *_Nullable domine_tone_create(double sampleRate, double seconds);

/// Frees the tone. Safe to call with NULL.
void domine_tone_destroy(DomineTone *_Nullable t);

/// 1 once every frame of the tone has been written, else 0.
int domine_tone_finished(DomineTone *t);

/// The AudioDeviceIOProc. Pass it to AudioDeviceCreateIOProcID with the
/// DomineTone as client data. Treats every output buffer as interleaved
/// float32 with mNumberChannels channels and writes the same sample to every
/// channel of every buffer for each frame. Frames after the tone ends are
/// zero. NULL client data zeroes the output. Ignores input. Returns 0.
OSStatus domine_tone_ioproc(AudioObjectID inDevice,
                            const AudioTimeStamp *inNow,
                            const AudioBufferList *inInputData,
                            const AudioTimeStamp *inInputTime,
                            AudioBufferList *outOutputData,
                            const AudioTimeStamp *inOutputTime,
                            void *_Nullable inClientData);

#pragma clang assume_nonnull end
#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
