#ifndef DOMINE_RECORDER_H
#define DOMINE_RECORDER_H

// Microphone recorder for auto-calibration. domine_recorder_ioproc appends the
// first input channel (float32, interleaved or not) to a preallocated buffer
// until it is full. Real-time safe: no allocation, locks, or I/O in the IOProc.
// The frames-written count is a C11 atomic readable from any thread. create and
// destroy allocate and free, so call them only while no IOProc uses the recorder.
// domine_recorder_reset must be called while the IOProc is not running.

#include <CoreAudio/CoreAudioTypes.h>
#include <CoreAudio/AudioHardwareBase.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DomineRecorder DomineRecorder;

DomineRecorder *domine_recorder_create(uint32_t capacityFrames);
void domine_recorder_destroy(DomineRecorder *r);

/// Pass the recorder as the IOProc client data.
OSStatus domine_recorder_ioproc(AudioObjectID inDevice,
                                const AudioTimeStamp *inNow,
                                const AudioBufferList *inInputData,
                                const AudioTimeStamp *inInputTime,
                                AudioBufferList *outOutputData,
                                const AudioTimeStamp *inOutputTime,
                                void *inClientData);

/// Frames recorded so far (never above the capacity).
uint32_t domine_recorder_frames_written(const DomineRecorder *r);
/// Copies up to maxFrames recorded frames into out; returns the count copied.
uint32_t domine_recorder_copy(const DomineRecorder *r, float *out, uint32_t maxFrames);
/// Discards the recording.
void domine_recorder_reset(DomineRecorder *r);

#ifdef __cplusplus
}
#endif

#endif
