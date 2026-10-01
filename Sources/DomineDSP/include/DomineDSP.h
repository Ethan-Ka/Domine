#ifndef DOMINE_DSP_H
#define DOMINE_DSP_H

// Domine real-time render kernel (SPEC section 5).
//
// Threading: the setters and domine_kernel_peak may be called from any thread.
// They only touch C11 atomics. domine_kernel_process and domine_kernel_ioproc
// run on the real-time audio thread and never allocate, lock, log, or do I/O.
// domine_kernel_create and domine_kernel_destroy allocate and free, so call
// them only while no IOProc is using the kernel.
//
// Terms:
//   Side: the source channel of the tapped stereo input, L or R.
//   Position: the output speaker slot. Position A is the left speaker
//   (Device A), position B is the right speaker (Device B). Swapping sides
//   changes which side feeds which position; positions never move.

#include <stdint.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <CoreAudio/AudioHardwareBase.h> // AudioObjectID only; no Core Audio calls

#ifdef __cplusplus
extern "C" {
#endif

// Pointers are nonnull unless marked _Nullable, matching Core Audio's headers
// so domine_kernel_ioproc has exactly the AudioDeviceIOProc type in Swift.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-extension"
#pragma clang assume_nonnull begin

typedef struct DomineKernel DomineKernel;

/// Largest delay magnitude accepted by domine_kernel_set_delay_ms.
#define DOMINE_MAX_DELAY_MS 300.0f

/// Test tone frequency and amplitude (-14 dBFS).
#define DOMINE_TONE_HZ 440.0
#define DOMINE_TONE_AMPLITUDE 0.2
/// Length of the test tone's linear fade in and fade out.
#define DOMINE_TONE_FADE_MS 40.0

/// Length of the mute and unmute fade.
#define DOMINE_FADE_MS 50.0

/// Pass as outBChannelOffset when Device B is absent (one speaker only).
#define DOMINE_NO_DEVICE UINT32_MAX

/// Smallest input FIFO capacity, in frames.
#define DOMINE_INPUT_FIFO_MIN_FRAMES 1024u

/// Creates a kernel. Delay ring buffers are sized for 300 ms at 96 kHz (or at
/// sampleRate if higher) and start zeroed. maxFrames is the IOProc buffer size
/// the caller expects; process handles any frame count safely regardless.
/// The input FIFO holds next_pow2(max(2 * maxFrames, 1024)) frames.
/// Returns NULL if sampleRate is not positive or allocation fails.
DomineKernel *_Nullable domine_kernel_create(double sampleRate, uint32_t maxFrames);

/// Frees the kernel. Safe to call with NULL.
void domine_kernel_destroy(DomineKernel *_Nullable k);

/// Per-position trim gains, linear. leftGain scales position A, rightGain
/// scales position B, after any swap. Default 1.0 each. Non-finite or
/// negative values are stored as 0.
void domine_kernel_set_gains(DomineKernel *k, float leftGain, float rightGain);

/// Signed delay offset in milliseconds, clamped to +-300 ms.
///   signedDelayMs > 0: position B (right speaker) is delayed. Use this when
///                      the right speaker plays early.
///   signedDelayMs < 0: position A (left speaker) is delayed by |ms|. Use this
///                      when the left speaker plays early.
/// Only one position is ever delayed. Delay in samples is
/// round(|ms| * sampleRate / 1000). Default 0.
void domine_kernel_set_delay_ms(DomineKernel *k, float signedDelayMs);

/// Channel mapping flags (each 0 or nonzero).
///   monoPerSpeaker (default 1): each speaker gets its side on both of its
///       channels. Required for mono speakers like the JBL Grip. When 0, each
///       speaker gets its side on its first channel only and silence on its
///       second channel.
///   swapSides (default 0): L feeds position B and R feeds position A.
///   monoFallback (default 0): every present speaker gets (L + R) / 2 on both
///       of its channels, ignoring monoPerSpeaker and swapSides. Used when one
///       speaker is missing (SPEC section 7).
void domine_kernel_set_mode(DomineKernel *k, int monoPerSpeaker, int swapSides, int monoFallback);

/// Test tone: 0 off, 1 position A (left speaker), 2 position B (right
/// speaker). Positions are not affected by swapSides. While the tone is on,
/// the chosen position plays a 440 Hz sine at -14 dBFS (amplitude 0.2) in
/// place of program audio, on the same channels program audio would use, and
/// the other position is silent. The tone ignores trim gain and delay but
/// follows the mute fade. Its phase starts at 0 when the tone turns on (or
/// changes position) and stays continuous across process calls.
/// Other values are treated as 0.
///
/// The tone crossfades with program audio over L = round(0.04 * sampleRate)
/// samples. Each sample uses level e = p / L, then p steps by one toward its
/// target (L while the tone is requested, 0 otherwise), so the fade in reads
/// 0, 1/L, 2/L, ... and the fade out L/L, (L-1)/L, ... 1/L. The playing
/// position gets tone * e + program * (1 - e) and the other position gets
/// program * (1 - e). Turning the tone off, or moving it to the other
/// position, first fades the current tone out; once p reaches 0 the new
/// request takes over (program alone, or the new position from phase 0).
void domine_kernel_set_test_tone(DomineKernel *k, int side);

/// Muted (nonzero) or unmuted (0). The output gain ramps linearly toward the
/// target over 50 ms of samples (round(0.05 * sampleRate)). A new kernel
/// starts unmuted at full gain with no ramp.
void domine_kernel_set_muted(DomineKernel *k, int muted);

/// Renders one IOProc cycle. Real-time safe.
///
/// in: float32 stereo from the tap, either interleaved (one buffer with 2 or
///     more channels; the first two are used) or deinterleaved (two or more
///     buffers; the first channel of the first two buffers is used). A single
///     mono buffer feeds both sides. NULL or empty input is silence.
/// out: float32 output of the aggregate, any number of buffers, each
///     interleaved with any channel count. Channel offsets are flat indexes
///     across all output channels in buffer order (buffer 0's channels first,
///     then buffer 1's, and so on). Device A uses outAChannelOffset and
///     outAChannelOffset + 1; Device B uses outBChannelOffset and
///     outBChannelOffset + 1. Pass DOMINE_NO_DEVICE for an absent device.
///     Channels that do not exist in out are skipped. Every output channel the
///     kernel does not write is zeroed.
/// frames: frames to render. Buffers shorter than this (by mDataByteSize) are
///     read as silence past their end and never written past their end.
///     Exactly `frames` input frames pass through the same input FIFO the
///     IOProc uses, so with an empty FIFO the output lines up with the input.
///     Does not record stats.
void domine_kernel_process(DomineKernel *k,
                           const AudioBufferList *_Nullable in,
                           AudioBufferList *_Nullable out,
                           uint32_t frames,
                           uint32_t outAChannelOffset,
                           uint32_t outBChannelOffset);

/// Peak absolute sample value written to a position during the most recent
/// process call (SPEC section 3a). position 0 = A (left), 1 = B (right).
/// Returns 0 for other values.
float domine_kernel_peak(DomineKernel *k, int position);

/// Format of the tap's streams as the aggregate delivers them to the IOProc
/// (read from the aggregate's input stream format at start). Stored in
/// atomics. channelsPerFrame 0 means unknown: the layout is then detected from
/// the buffer list alone. nonInterleaved nonzero means one channel per
/// buffer. Samples are always float32.
///
/// How the IOProc reads the tap (the buffer list always wins over the format,
/// since it describes the memory; a disagreement is counted in
/// formatMismatchCycles):
///   first tap buffer has 2 or more channels: interleaved, the first two
///       channels are L and R.
///   first tap buffer has 1 channel and a second tap buffer exists, and the
///       format is not known to be mono: deinterleaved, the first channel of
///       the first two buffers are L and R.
///   otherwise: mono, the one channel feeds both L and R.
void domine_kernel_set_input_format(DomineKernel *k, uint32_t channelsPerFrame, int nonInterleaved);

/// Aggregate layout used by domine_kernel_ioproc. Stored in atomics; set it
/// before the device starts. Defaults: inFirstBuffer 0, A offset 0, B offset 2.
///   inFirstBuffer: index of the tap's first buffer in the aggregate's input
///       buffer list (sub-device input buffers come before it).
///   outAChannelOffset, outBChannelOffset: as in domine_kernel_process.
void domine_kernel_set_layout(DomineKernel *k,
                              uint32_t inFirstBuffer,
                              uint32_t outAChannelOffset,
                              uint32_t outBChannelOffset);

// The AudioDeviceIOProc for the aggregate device (SPEC section 5). Pass it to
// AudioDeviceCreateIOProcID with the DomineKernel as client data. Real-time
// safe. It reads the layout atomics and views the input list from
// inFirstBuffer on. Input and output frame counts are independent:
//   input frames: what the tap buffers hold (mDataByteSize / (4 * channels),
//       the smaller of L and R when deinterleaved; 0 when the tap buffer is
//       missing or its data is NULL). Every input frame is consumed exactly
//       once, in order, through the input FIFO (see domine_kernel_create).
//   output frames: the largest output buffer (mDataByteSize / (4 *
//       mNumberChannels)).
// Frame f of the cycle first pushes input frame f (if f < input frames), then
// pops one frame for output frame f (if f < output frames). So equal counts
// add no latency and reproduce the input exactly; extra input waits in the
// FIFO for the next cycle; missing input plays silence (counted as underrun
// frames). When the FIFO is full the oldest frame is dropped (overflow).
// It also records the cycle in the stats (domine_kernel_stats).
// NULL client data or output does nothing. Always returns 0.
OSStatus domine_kernel_ioproc(AudioObjectID inDevice,
                              const AudioTimeStamp *inNow,
                              const AudioBufferList *inInputData,
                              const AudioTimeStamp *inInputTime,
                              AudioBufferList *outOutputData,
                              const AudioTimeStamp *inOutputTime,
                              void *_Nullable inClientData);

/// Bits of DomineKernelStats.timeFlags: which time stamp fields of the most
/// recent cycle were valid (kAudioTimeStampHostTimeValid or
/// kAudioTimeStampSampleTimeValid set by the HAL).
#define DOMINE_STATS_NOW_HOST_VALID      0x01
#define DOMINE_STATS_INPUT_HOST_VALID    0x02
#define DOMINE_STATS_INPUT_SAMPLE_VALID  0x04
#define DOMINE_STATS_OUTPUT_HOST_VALID   0x08
#define DOMINE_STATS_OUTPUT_SAMPLE_VALID 0x10

/// Diagnostics recorded by domine_kernel_ioproc once per cycle (not by
/// domine_kernel_process). Totals count since the kernel was created; "last"
/// fields describe the most recent cycle; "max" fields count since the last
/// domine_kernel_stats_reset_maxima.
typedef struct DomineKernelStats {
    uint64_t cycles;
    /// Output frames rendered, summed.
    uint64_t frames;
    /// Tap input frames the buffer list held, summed.
    uint64_t inputFrames;
    /// Cycles with no tap input: NULL input list, no buffer at
    /// inFirstBuffer, or NULL data.
    uint64_t inputMissingCycles;
    /// Cycles where the tap held fewer frames than the output.
    uint64_t inputShortCycles;
    /// Cycles where the tap held more frames than the output.
    uint64_t inputLongCycles;
    /// Cycles with tap input whose every sample read was exactly 0.
    uint64_t inputSilentCycles;
    /// Cycles whose output buffers disagree on frame count.
    uint64_t outputMismatchCycles;
    /// Cycles where the buffer list disagreed with the input format.
    uint64_t formatMismatchCycles;
    /// Output frames played as silence because the input FIFO was empty.
    uint64_t underrunFrames;
    /// Input frames dropped because the input FIFO was full.
    uint64_t overflowFrames;
    /// Cycles whose output sample time was not the previous cycle's output
    /// sample time plus its output frames (both valid).
    uint64_t sampleTimeJumps;
    /// inNow->mHostTime, inInputTime->mHostTime, inOutputTime->mHostTime of
    /// the last cycle (0 when not valid, see timeFlags).
    uint64_t nowHostTime;
    uint64_t inputHostTime;
    uint64_t outputHostTime;
    /// Largest step of nowHostTime between consecutive cycles, host ticks.
    uint64_t maxCycleInterval;
    /// inInputTime->mSampleTime and inOutputTime->mSampleTime of the last
    /// cycle (0 when not valid).
    double inputSampleTime;
    double outputSampleTime;
    /// The kernel's sample rate (filled by domine_kernel_stats).
    double sampleRate;
    uint32_t timeFlags;
    uint32_t lastFrames;
    uint32_t lastInputFrames;
    /// Tap buffers in the input list view (from inFirstBuffer on).
    uint32_t lastInputBuffers;
    /// Channels of the first tap buffer.
    uint32_t lastInputChannels;
    uint32_t lastOutputBuffers;
    /// Smallest output buffer of the last cycle, in frames.
    uint32_t lastOutputFramesMin;
    /// Frames waiting in the input FIFO after the last cycle.
    uint32_t fifoFill;
    /// Largest absolute tap sample (L or R) read in the last cycle.
    float lastInputPeak;
    /// Largest absolute tap sample since the last maxima reset.
    float maxInputPeak;
    /// Maxima resets the render thread has applied.
    uint32_t maximaResets;
    /// Filled by domine_kernel_stats from the parameters, not the render thread.
    uint32_t layoutInFirstBuffer;
    uint32_t layoutOutA;
    uint32_t layoutOutB;
    uint32_t inputChannelsPerFrame;
    uint32_t inputNonInterleaved;
    uint32_t fifoCapacity;
    uint32_t maxFrames;
} DomineKernelStats;

/// Copies a consistent snapshot of the stats into *out. Any thread; never
/// blocks the render thread (seqlock: the reader retries, the writer never
/// waits). Returns 1 for a consistent snapshot, 0 if the render thread kept
/// writing for every retry (the copy may then mix two cycles).
int domine_kernel_stats(DomineKernel *k, DomineKernelStats *out);

/// Asks the render thread to zero maxCycleInterval and maxInputPeak at the
/// start of its next cycle. Any thread.
void domine_kernel_stats_reset_maxima(DomineKernel *k);

#pragma clang assume_nonnull end
#pragma clang diagnostic pop

#ifdef __cplusplus
}
#endif

#endif
