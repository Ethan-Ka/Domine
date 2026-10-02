#ifndef DOMINE_DEMO_H
#define DOMINE_DEMO_H

// Showcase demo generator (SPEC section 14). An original piece in the spirit
// of a giant-screen theatre sound-system preshow (no narrator): a dark, quiet
// room, precise sounds that place each speaker, sounds that travel and
// accelerate, a huge slowly building chord, a moment of silence, and one
// massive clean impact with a long tail. Precision and scale. Generated live
// for the current speaker set; 47 s for 2 speakers (45 to 51 s in general).
//
// It produces voices, not speaker signals: each voice is a mono sample with an
// azimuth and an omni amount. The kernel pans each voice with
// domine_surround_vbap and blends toward equal power on every speaker by omni:
//   g_k = (1 - omni) * vbap_k + omni / sqrt(N)
//
// Grid: 120 BPM (beat 0.5 s, bar 2 s). Every section starts on a downbeat.
// Roll-call order: speakers sorted clockwise starting from the one nearest
// hard left, by key fmod(az + 90 + 360, 360) ascending (ties keep input order).
//
// Timeline (seconds; R is the Calibration length; total R + 41):
//   0-R       Calibration (section ROLL_CALL). Soft 3.5 kHz ticks on every
//             beat, centred, and a dark drone fading in. From 2 s, the roll
//             call: exactly one hit per speaker per round, in roll-call order,
//             each kick exactly on its speaker's azimuth:
//               N <= 2: a double hit per speaker ("da-dum", second hit 0.25 s
//                       after the first and louder), one speaker every 2
//                       beats, 4 slots (two rounds for 2 speakers).
//               3 <= N <= 8: one hit per beat, two rounds (2N beats).
//               N > 8: one hit per half beat, one round (N / 2 beats).
//             R = 2 + the hits' length rounded up to whole bars: 6 s for
//             N <= 4 and N > 8, 8 s for N = 5 and 6, 10 s for N = 7 and 8.
//   R+0-6     Left and right (PING_PONG): kicks alternate -90 and +90, first
//             on the left: quarter notes for a bar, eighths for a bar, then
//             sixteenths for 3 beats (getting louder), over a sub pulse on
//             every beat (omni). The sweep tone fades in at -90 on the last
//             beat.
//   R+6-12    Sweep: a tone (220 Hz rising a whole tone per pass) plus
//             band-passed noise flies across the room 6 times, clockwise
//             from -90 (front, then back, ...), each pass faster: 2, 1.5, 1,
//             0.75, 0.5, 0.25 s. Doppler-like bend in each pass: pitch above
//             the base while approaching, falling through it as it passes the
//             middle, below it while receding (sin(2 pi u), depth grows with
//             speed). It ends at +90 and decays there.
//   R+12-22   Orbit: a smooth bass (polyBLEP saws at 55 and 110.5 Hz plus a
//             55 Hz sine, resonant low-pass wobbling 250-700 Hz at 1 Hz,
//             tanh) fades in at +90 where the sweep ended and circles
//             clockwise; speed rises 0.25 to 0.6 turns per second. A kick
//             every 2 beats on the bass's azimuth; off-beat hats on the
//             mirror path (-bass azimuth) from R+14.
//   R+22-32   Swell: the drone becomes a wide chord of 12 detuned partials
//             (A, E, C#, B across 110 to 660 Hz) split between two voices
//             that spread from the centre to -90 and +90 and toward every
//             speaker (omni to 0.7), rising a fifth in pitch, getting
//             brighter and louder, with a deep sub (55 Hz and harmonics)
//             growing under it. The bass fades out over the first 4 s.
//             Bright pings (1.7 to 4.4 kHz) sweep back and forth across the
//             top from R+24. Everything cuts with a 30 ms fade at R+32.
//   R+32-33   Silence: every voice exactly 0.
//   R+33-41   Impact (DROP): a clean kick (200 to 65 Hz) and a sub boom (50
//             to 41 Hz, saturated) on every speaker, a wide noise burst whose
//             low-pass falls from 10 kHz to 200 Hz, and the chord back on its
//             root, all decaying to exactly 0 by R+41. Then FINISHED.
//
// Kick: saturated sine (tanh) with pitch falling 240 to 80 Hz (tau 30 ms),
// amplitude exp(-t / 90 ms), 1 ms attack, 20 ms cosine fade to 0 at 220 ms,
// plus a beater layer (3.2 kHz sine, tau 6 ms, 0.22, and a noise tick, tau
// 2.5 ms, 0.12) so it reads clearly on small speakers. Kicks duck the drone
// and the bass (sidechain, recovers with tau 160 ms). On small speakers
// (Grips roll off below about 70 Hz) the weight comes from 80 to 300 Hz
// harmonics; the 41 to 55 Hz parts are for larger speakers.
//
// Voices: 0 and 1 kicks (alternating so a tail is never cut), 2 bass, 3 sub
// (pulses, swell sub, boom), 4 and 5 chord (drone, swell, impact), 6 ticks,
// hats and pings, 7 noise and sweep. Peak output of any one voice stays
// within 0.8; the sum of the absolute values of all voices within 1.0 (a
// safety limiter on the voice sum enforces it).
//
// Deterministic: same speaker set and sample rate give the same samples.
// Real-time safe in tick (no allocation, locks, logging, I/O). Not thread
// safe: the kernel owns it on the render thread.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DOMINE_DEMO_VOICES 8
/// Longest possible demo (7 or 8 speakers); domine_demo_length gives the
/// length for the current speaker set.
#define DOMINE_DEMO_LENGTH_S 51.0

// Values are stable; the newer sections are appended. UI titles in brackets.
#define DOMINE_DEMO_SECTION_IDLE 0
#define DOMINE_DEMO_SECTION_ROLL_CALL 1  // "Calibration"
#define DOMINE_DEMO_SECTION_PING_PONG 2  // "Left and right"
#define DOMINE_DEMO_SECTION_ORBIT 3      // "Orbit"
#define DOMINE_DEMO_SECTION_SWELL 4      // "Swell"
#define DOMINE_DEMO_SECTION_DROP 5       // "Impact"
#define DOMINE_DEMO_SECTION_FINISHED 6
#define DOMINE_DEMO_SECTION_SWEEP 7      // "Sweep"
#define DOMINE_DEMO_SECTION_SILENCE 8    // "Silence"
#define DOMINE_DEMO_SECTION_CALIBRATION DOMINE_DEMO_SECTION_ROLL_CALL
#define DOMINE_DEMO_SECTION_IMPACT DOMINE_DEMO_SECTION_DROP

#define DOMINE_DEMO_CHORD_PARTIALS 12

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
    double rollEnd;         // R, seconds
    uint32_t rollCallHits;
    // Kick voices.
    double kickPhase[2];
    uint64_t kickStart[2];
    float kickAz[2];
    float kickOmni[2];
    float kickGain[2];
    int kickActive[2];
    int kickImpact[2];
    int nextKick;
    int lastKick;
    uint64_t nextHit;
    uint32_t hitIndex;      // global hit counter
    // Sidechain duck and voice-sum limiter.
    uint64_t duckStart;
    float duckDepth, duck, limGain;
    uint32_t noise;
    // Bass.
    double bassPhase, bassPhase2, subPhase, orbitPhase, lfoPhase;
    float lp1, lp2;
    float bassAz;
    // Sub.
    double lowPhase, boomPhase;
    uint64_t pulseStart;
    float pulseGain;
    int pulseActive;
    // Chord.
    double chordPhase[DOMINE_DEMO_CHORD_PARTIALS];
    // Sweep.
    double sweepPhase;
    float sweepAz;
    // Ticks, hats and pings (sixteenth clock).
    uint32_t step16;
    uint64_t pingStart;
    float pingAmp, pingTau, pingHz, pingAz, pingLp;
    int pingNoise, pingActive;
    // Noise.
    float fxLp1, fxLp2;
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
/// Total length in seconds for the current speaker set (R + 41).
double domine_demo_length(const DomineDemo *d);
/// Azimuth of the voice the UI should follow (latest kick, the sweep, the
/// bass, or 0 from the Swell on).
float domine_demo_focus_azimuth(const DomineDemo *d);

#ifdef __cplusplus
}
#endif

#endif
