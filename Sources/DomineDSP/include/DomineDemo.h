#ifndef DOMINE_DEMO_H
#define DOMINE_DEMO_H

// Showcase demo generator (SPEC section 14). A 30 to 34 s piece of synthesized
// bass and percussion, generated live for the current speaker set, that moves
// around the speakers so a listener hears and feels where each speaker is, the
// left/right split, and a full orbit. It is one continuous track at 120 BPM
// (beat 0.5 s, bar 2 s): every section starts on a downbeat, a pad bed and
// off-beat hats carry across section changes, and noise risers lead into the
// next section.
//
// It produces voices, not speaker signals: each voice is a mono sample with an
// azimuth and an omni amount. The kernel pans each voice with
// domine_surround_vbap and blends toward equal power on every speaker by omni:
//   g_k = (1 - omni) * vbap_k + omni / sqrt(N)
//
// Roll-call order: speakers sorted clockwise starting from the one nearest
// hard left, by key fmod(az + 90 + 360, 360) ascending (ties keep input order).
//
// Timeline (seconds; R is the roll-call length, see below; length R + 26):
//   0-R      Roll call. Exactly one hit per speaker per round, in roll-call
//            order, each kick exactly on its speaker's azimuth:
//              N <= 2: a double hit per speaker ("da-dum", second hit
//                      0.25 s after the first and louder), one speaker every
//                      2 beats, 4 slots (two rounds for 2 speakers).
//              3 <= N <= 8: one hit per beat, two rounds (2N beats).
//              N > 8: one hit per half beat, one round (N / 2 beats).
//            R is the hits' length rounded up to whole bars, at least 2 bars
//            (4 s): 4 s for N <= 4 and N > 8, 6 s for N = 5 and 6, 8 s for
//            N = 7 and 8. The pad bed fades in over the first bar, off-beat
//            hats start at 2 s (mirrored to the opposite side of the latest
//            kick), and a noise riser over the last 2 beats sweeps toward -90.
//   R+0-6    Ping-pong ("Left and right"): kicks alternate -90 and +90, first
//            on the left: quarter notes for a bar, eighths for a bar, then
//            sixteenths for 3 beats (getting louder). The last beat is a
//            riser that travels from +90 around the back to 0.
//   R+6-18   Orbit: a growling bass enters on the downbeat (polyBLEP saws at
//            55 and 110.5 Hz plus a 55 Hz sine, through a resonant low-pass
//            (Q 2.2) wobbling 300-900 Hz at 4 Hz, then tanh saturation) and
//            circles clockwise from 0 degrees. Speed rises linearly from 0.2
//            to 0.8 turns per second. A kick on every beat on the bass's
//            current azimuth; hats travel the mirror path (-bass azimuth),
//            with sixteenth shaker ticks added for the second half.
//   R+18-22  Swell: the bass keeps orbiting at 0.8 turns per second; omni
//            rises 0 to 1 (bass, kicks, hats, riser), pitch glides 55 to
//            82.5 Hz (the bed follows), the filter opens to 2 kHz, level
//            rises. Build-up kicks: quarters, eighths, sixteenths. A noise
//            riser climbs the whole time.
//            Break at R+21.5: everything cuts (30 ms fade); a reverse swell
//            of noise rises into the drop. Section stays SWELL.
//   R+22-26  Drop: one long kick on every speaker (omni 1), a wide noise
//            burst whose low-pass falls from 9 kHz to 250 Hz, and the pad
//            chord back on the root (with its 55 Hz sub) decaying to 0 at
//            R+26. Then the demo ends; status reports finished.
//
// Sounds: kick = saturated sine (tanh) with pitch falling 240 to 80 Hz (tau
// 30 ms), amplitude exp(-t / 90 ms), 1 ms attack, 20 ms cosine fade to 0 at
// 220 ms, plus a beater layer (3.2 kHz sine, tau 6 ms, 0.22, and a noise
// tick, tau 2.5 ms, 0.12) so it reads clearly on small speakers. Drop kick:
// 220 to 60 Hz (tau 70 ms), amplitude exp(-t / 450 ms), 300 ms cosine fade to
// 0 at 1.5 s. Every kick ducks the bed and the bass (sidechain, recovers with
// tau 160 ms). Pad bed: sines at 55, 110, 164.8, 220 Hz, omni 1. Hats:
// high-passed noise. The weight on small speakers (Grips roll off below about
// 70 Hz) comes from 80 to 300 Hz harmonics; the 55 Hz parts are for larger
// speakers.
//
// Voices: 0 and 1 kicks (alternating so a tail is never cut), 2 bass, 3 pad
// bed, 4 hats, 5 noise effects. Peak output of any one voice stays within
// 0.8; the sum of the absolute values of all voices within 1.0 (a safety
// limiter on the voice sum enforces it).
//
// Deterministic: same speaker set and sample rate give the same samples.
// Real-time safe in tick (no allocation, locks, logging, I/O). Not thread
// safe: the kernel owns it on the render thread.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DOMINE_DEMO_VOICES 6
/// Longest possible demo (7 or 8 speakers); domine_demo_length gives the
/// length for the current speaker set.
#define DOMINE_DEMO_LENGTH_S 34.0

#define DOMINE_DEMO_SECTION_IDLE 0
#define DOMINE_DEMO_SECTION_ROLL_CALL 1
#define DOMINE_DEMO_SECTION_PING_PONG 2
#define DOMINE_DEMO_SECTION_ORBIT 3
#define DOMINE_DEMO_SECTION_SWELL 4
#define DOMINE_DEMO_SECTION_DROP 5
#define DOMINE_DEMO_SECTION_FINISHED 6

typedef struct {
    float sample;   // mono signal
    float azimuth;  // degrees, same convention as DomineSurround.h
    float omni;     // 0 = point source, 1 = equal on every speaker
} DomineDemoVoice;

/// Plain struct so the kernel embeds it without allocating. Fields are
/// private to demo.c.
typedef struct {
    double sampleRate;
    uint64_t frame;
    int section;
    uint32_t speakerCount;
    float order[16];        // speaker azimuths in roll-call order
    // Kick voices.
    double kickPhase[2];
    uint64_t kickStart[2];
    float kickAz[2];
    float kickOmni[2];
    float kickDecay[2];
    int kickActive[2];
    int nextKick;
    uint64_t nextHit;
    uint32_t hitIndex;      // global hit counter
    // Bass voice.
    double bassPhase, subPhase, orbitPhase, lfoPhase;
    float lp1, lp2;
    float bassAz;
    uint32_t rollCallHits;
    float kickGain[2];
    float kickLen[2];
    int lastKick;
    double rollEnd;         // R, seconds
    double bassPhase2;
    float bassOmni;
    // Sidechain duck and voice-sum limiter.
    uint64_t duckStart;
    float duckDepth, duck, limGain;
    uint32_t noise;
    // Pad bed.
    double bedPhase[4];
    // Hats (sixteenth clock).
    uint32_t step16;
    uint64_t hatStart;
    float hatAmp, hatTau, hatAz, hatOmni, hatLp;
    int hatActive;
    // Noise effects.
    float fxLp1, fxLp2, fxAmp, fxMix;
} DomineDemo;

/// Resets to 0 s for the given speakers (azimuths in degrees, count clamped
/// to 16; count 0 is treated as one speaker at 0).
void domine_demo_reset(DomineDemo *d, double sampleRate, uint32_t count, const float *azimuthDeg);
/// Renders one frame into voices[DOMINE_DEMO_VOICES] (silent voices have
/// sample 0). Returns the current DOMINE_DEMO_SECTION_*; FINISHED from
/// domine_demo_length on (voices silent from then on).
int domine_demo_tick(DomineDemo *d, DomineDemoVoice *voices);
/// Seconds since reset (stops at domine_demo_length).
double domine_demo_seconds(const DomineDemo *d);
/// Total length in seconds for the current speaker set (R + 26, 30 to 34).
double domine_demo_length(const DomineDemo *d);
/// Azimuth of the voice the UI should follow (latest kick or the bass).
float domine_demo_focus_azimuth(const DomineDemo *d);

#ifdef __cplusplus
}
#endif

#endif
