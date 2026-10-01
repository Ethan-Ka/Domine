#ifndef DOMINE_PROBE_H
#define DOMINE_PROBE_H

// Audio capture probe. A short-lived IOProc on a tap-only aggregate that
// records whether any non-zero input sample arrived. macOS shows the audio
// capture permission prompt when a process tap is first read, and a tap
// without permission delivers silence, so "heard" means capture works.
//
// Threading: domine_probe_ioproc runs on the real-time audio thread and only
// reads the input and stores one C11 atomic flag. domine_probe_reset and
// domine_probe_heard may be called from any thread. domine_probe_create and
// domine_probe_destroy allocate and free, so call them only while no IOProc
// is using the probe.

#include <CoreAudio/CoreAudioTypes.h>
#include <CoreAudio/AudioHardwareBase.h> // AudioObjectID only; no Core Audio calls

#ifdef __cplusplus
extern "C" {
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

typedef struct DomineProbe DomineProbe;

/// Creates a probe with the flag cleared. Returns NULL if allocation fails.
DomineProbe *_Nullable domine_probe_create(void);

/// Frees the probe. Safe to call with NULL.
void domine_probe_destroy(DomineProbe *_Nullable p);

/// Clears the flag.
void domine_probe_reset(DomineProbe *p);

/// 1 if any non-zero input sample has arrived since create or reset, else 0.
int domine_probe_heard(DomineProbe *p);

// The AudioDeviceIOProc for the probe aggregate. Pass it to
// AudioDeviceCreateIOProcID with the DomineProbe as client data. Real-time
// safe. Scans every float32 input buffer (mDataByteSize / 4 samples) and sets
// the flag on the first non-zero sample; stops scanning once the flag is set.
// Zeroes every output buffer. NULL client data or input only zeroes output.
// Always returns 0.
OSStatus domine_probe_ioproc(AudioObjectID inDevice,
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
