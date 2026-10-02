#ifndef DOMINE_DEMO_H
#define DOMINE_DEMO_H

// Showcase demo generator (SPEC section 14). A fixed 32 s piece of synthesized
// bass and percussion that moves around the speakers so a listener hears and
// feels where each speaker is, the left/right split, and a full orbit.
// It produces voices, not speaker signals: each voice is a mono sample with an
// azimuth and an omni amount. The kernel pans each voice with
// domine_surround_vbap and blends toward equal power on every speaker by omni:
//   g_k = (1 - omni) * vbap_k + omni / sqrt(N)
//
// Timeline (seconds):
//   0-8   Roll call: one kick per speaker, clockwise starting from the
//         speaker nearest hard left (-90). Two rounds when N <= 8, one when
//         N > 8, hits evenly spaced (8 / hits seconds). Each kick sits
//         exactly on its speaker's azimuth.
//   8-14  Ping-pong: kicks alternate -90 and +90, first one on the left. The
//         gap between hits shrinks linearly from 0.5 s to 0.15 s.
//   14-26 Orbit: a growling bass (saw plus sub sine, 55 Hz, wobbling low-pass
//         300-900 Hz at 4 Hz) circles clockwise from 0 degrees. Speed rises
//         linearly from 0.2 to 0.8 turns per second. A kick every 0.5 s on
//         the bass's current azimuth.
//   26-29.5 Swell: the bass keeps orbiting; omni rises 0 to 1, pitch glides
//         55 to 82.5 Hz, the filter opens to 2 kHz, level rises.
//   29.5-30 Break: silence (bass fades out over 30 ms).
//   30-32 Drop: one long kick (1.5 s decay) on every speaker (omni 1), then
//         the demo ends; status reports finished.
//
// Sounds: kick = sine with pitch falling 150 to 45 Hz (tau 30 ms), amplitude
// exp(-t / 90 ms) with a 1 ms attack and a 20 ms cosine fade to 0 at 220 ms,
// plus a 1.8 kHz click (tau 4 ms, 0.25) so its position is easy to place.
// Kicks alternate between two voices so a tail is never cut. Peak output of
// any one voice stays within 0.8; the sum of all voices within 1.0.
//
// Deterministic: same speaker set and sample rate give the same samples.
// Real-time safe in tick (no allocation, locks, logging, I/O). Not thread
// safe: the kernel owns it on the render thread.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DOMINE_DEMO_VOICES 3
#define DOMINE_DEMO_LENGTH_S 32.0

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
    uint32_t hitIndex;
    // Bass voice.
    double bassPhase, subPhase, orbitPhase, lfoPhase;
    float lp1, lp2;
    float bassAz;
    // Added for demo.c.
    uint32_t rollCallHits;
    float kickGain[2];
    float kickLen[2];
    int lastKick;
} DomineDemo;

/// Resets to 0 s for the given speakers (azimuths in degrees, count clamped
/// to 16; count 0 is treated as one speaker at 0).
void domine_demo_reset(DomineDemo *d, double sampleRate, uint32_t count, const float *azimuthDeg);
/// Renders one frame into voices[DOMINE_DEMO_VOICES] (silent voices have
/// sample 0). Returns the current DOMINE_DEMO_SECTION_*; FINISHED after 32 s
/// (voices silent from then on).
int domine_demo_tick(DomineDemo *d, DomineDemoVoice *voices);
/// Seconds since reset.
double domine_demo_seconds(const DomineDemo *d);
/// Azimuth of the voice the UI should follow (latest kick or the bass).
float domine_demo_focus_azimuth(const DomineDemo *d);

#ifdef __cplusplus
}
#endif

#endif
