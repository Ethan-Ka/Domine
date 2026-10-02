// Showcase demo generator (DomineDemo.h). Real-time safe in tick: no
// allocation, locks, logging, or I/O. Deterministic: all state is in the
// struct and every value derives from the frame counter and the reset inputs.

#include "include/DomineDemo.h"

#include <math.h>
#include <string.h>

#define MAX_SPEAKERS 16

// Section boundaries, seconds.
#define T_PING 8.0
#define T_ORBIT 14.0
#define T_SWELL 26.0
#define T_BREAK 29.5
#define T_DROP 30.0

// Kick.
#define KICK_F_HI 150.0
#define KICK_F_LO 45.0
#define KICK_PITCH_TAU 0.030
#define KICK_ATTACK 0.001
#define KICK_TAU 0.090
#define KICK_LEN 0.220
#define KICK_FADE 0.020
#define CLICK_HZ 1800.0
#define CLICK_TAU 0.004
#define CLICK_LEVEL 0.25
#define DROP_TAU 0.450
#define DROP_LEN 1.500
#define DROP_FADE 0.300
// |kick| <= gain * (1 + CLICK_LEVEL), so these gains give peaks of 0.8 and 0.5625.
#define KICK_GAIN 0.64f
#define ORBIT_KICK_GAIN 0.45f

// Ping-pong gaps.
#define GAP_START 0.5
#define GAP_END 0.15
#define ORBIT_HIT_GAP 0.5

// Bass. |bass| <= level because the output goes through tanh.
#define BASS_HZ 55.0
#define BASS_GLIDE 1.5          // 55 to 82.5 Hz over the swell
#define ORBIT_SPEED_START 0.2   // turns per second
#define ORBIT_SPEED_END 0.8
#define LFO_HZ 4.0
#define CUT_LO 300.0
#define CUT_HI 900.0
#define CUT_OPEN 2000.0
#define BASS_Q 2.2
#define BASS_DRIVE 1.6
#define BASS_SAW_MIX 0.6
#define BASS_SUB_MIX 0.5
#define BASS_LEVEL 0.42f        // orbit; with an orbit kick the sum stays under 0.99
#define BASS_LEVEL_SWELL 0.75f  // end of the swell (no kicks then)
#define BASS_ATTACK 0.010
#define BASS_RELEASE 0.030

static uint64_t at(const DomineDemo *d, double seconds) {
    return (uint64_t)llround(seconds * d->sampleRate);
}

static float wrap180(double a) {
    a = fmod(a, 360.0);
    if (a <= -180.0) a += 360.0;
    if (a > 180.0) a -= 360.0;
    return (float)a;
}

static double rollcall_key(float az) {
    double k = fmod((double)az + 90.0, 360.0);
    if (k < 0.0) k += 360.0;
    return k;
}

static int section_at(const DomineDemo *d, uint64_t f) {
    if (f < at(d, T_PING)) return DOMINE_DEMO_SECTION_ROLL_CALL;
    if (f < at(d, T_ORBIT)) return DOMINE_DEMO_SECTION_PING_PONG;
    if (f < at(d, T_SWELL)) return DOMINE_DEMO_SECTION_ORBIT;
    if (f < at(d, T_DROP)) return DOMINE_DEMO_SECTION_SWELL; // includes the break
    if (f < at(d, DOMINE_DEMO_LENGTH_S)) return DOMINE_DEMO_SECTION_DROP;
    return DOMINE_DEMO_SECTION_FINISHED;
}

void domine_demo_reset(DomineDemo *d, double sampleRate, uint32_t count, const float *azimuthDeg) {
    memset(d, 0, sizeof *d);
    d->sampleRate = (sampleRate > 0.0 && isfinite(sampleRate)) ? sampleRate : 48000.0;
    if (azimuthDeg == NULL) count = 0;
    if (count > MAX_SPEAKERS) count = MAX_SPEAKERS;
    if (count == 0) {
        d->speakerCount = 1;
        d->order[0] = 0.0f;
    } else {
        d->speakerCount = count;
        // Stable insertion sort by clockwise distance from hard left.
        for (uint32_t i = 0; i < count; i++) {
            float az = isfinite(azimuthDeg[i]) ? azimuthDeg[i] : 0.0f;
            double key = rollcall_key(az);
            uint32_t j = i;
            while (j > 0 && rollcall_key(d->order[j - 1]) > key) {
                d->order[j] = d->order[j - 1];
                j--;
            }
            d->order[j] = az;
        }
    }
    d->rollCallHits = d->speakerCount * (d->speakerCount <= 8 ? 2u : 1u);
    d->section = DOMINE_DEMO_SECTION_ROLL_CALL;
    d->kickAz[0] = d->kickAz[1] = d->order[0];
    d->lastKick = 0;
    d->nextKick = 0;
    d->nextHit = 0;
}

double domine_demo_seconds(const DomineDemo *d) {
    return (double)d->frame / d->sampleRate;
}

float domine_demo_focus_azimuth(const DomineDemo *d) {
    if (d->section == DOMINE_DEMO_SECTION_ORBIT || d->section == DOMINE_DEMO_SECTION_SWELL) return d->bassAz;
    return d->kickAz[d->lastKick];
}

static void start_kick(DomineDemo *d, float az, float omni, float gain, int drop) {
    int k = d->nextKick;
    d->kickPhase[k] = 0.0;
    d->kickStart[k] = d->frame;
    d->kickAz[k] = az;
    d->kickOmni[k] = omni;
    d->kickGain[k] = gain;
    d->kickDecay[k] = (float)(drop ? DROP_TAU : KICK_TAU);
    d->kickLen[k] = (float)(drop ? DROP_LEN : KICK_LEN);
    d->kickActive[k] = 1;
    d->lastKick = k;
    d->nextKick = k ^ 1;
}

// Fires the hit due at the current frame and schedules the next one.
static void fire_hit(DomineDemo *d, int section) {
    const double sr = d->sampleRate;
    uint32_t i = d->hitIndex++;
    switch (section) {
    case DOMINE_DEMO_SECTION_ROLL_CALL: {
        uint32_t n = d->rollCallHits;
        start_kick(d, d->order[i % d->speakerCount], 0.0f, KICK_GAIN, 0);
        d->nextHit = i + 1 < n ? (uint64_t)llround((double)(i + 1) * T_PING * sr / (double)n) : at(d, T_PING);
        break;
    }
    case DOMINE_DEMO_SECTION_PING_PONG: {
        start_kick(d, (i & 1u) ? 90.0f : -90.0f, 0.0f, KICK_GAIN, 0);
        double t = (double)d->frame / sr;
        double gap = GAP_START - (GAP_START - GAP_END) * (t - T_PING) / (T_ORBIT - T_PING);
        if (gap < GAP_END) gap = GAP_END;
        uint64_t next = d->frame + (uint64_t)llround(gap * sr);
        d->nextHit = next < at(d, T_ORBIT) ? next : at(d, T_ORBIT);
        break;
    }
    case DOMINE_DEMO_SECTION_ORBIT: {
        start_kick(d, d->bassAz, 0.0f, ORBIT_KICK_GAIN, 0);
        uint64_t next = at(d, T_ORBIT + ORBIT_HIT_GAP * (double)(i + 1));
        d->nextHit = next < at(d, T_SWELL) ? next : at(d, T_DROP);
        break;
    }
    case DOMINE_DEMO_SECTION_DROP:
        start_kick(d, 0.0f, 1.0f, KICK_GAIN, 1);
        d->nextHit = UINT64_MAX;
        break;
    default:
        d->nextHit = UINT64_MAX;
        break;
    }
}

static float render_kick(DomineDemo *d, int k) {
    if (!d->kickActive[k]) return 0.0f;
    const double sr = d->sampleRate;
    const double t = (double)(d->frame - d->kickStart[k]) / sr;
    const double len = d->kickLen[k];
    if (t >= len) { d->kickActive[k] = 0; return 0.0f; }
    const double fade = len > 0.5 ? DROP_FADE : KICK_FADE;
    double env = t < KICK_ATTACK ? t / KICK_ATTACK : 1.0;
    if (t > len - fade) env *= 0.5 * (1.0 + cos(M_PI * (t - (len - fade)) / fade));
    const double body = exp(-t / (double)d->kickDecay[k]) * sin(2.0 * M_PI * d->kickPhase[k]);
    const double click = CLICK_LEVEL * exp(-t / CLICK_TAU) * sin(2.0 * M_PI * CLICK_HZ * t);
    const double hz = KICK_F_LO + (KICK_F_HI - KICK_F_LO) * exp(-t / KICK_PITCH_TAU);
    d->kickPhase[k] += hz / sr;
    if (d->kickPhase[k] >= 1.0) d->kickPhase[k] -= 1.0;
    return (float)((double)d->kickGain[k] * env * (body + click));
}

static double polyblep(double p, double dt) {
    if (p < dt) { double x = p / dt; return x + x - x * x - 1.0; }
    if (p > 1.0 - dt) { double x = (p - 1.0) / dt; return x * x + x + x + 1.0; }
    return 0.0;
}

// Bass for the current frame (orbit, swell, break). Advances its phases.
static float render_bass(DomineDemo *d, double t, float *omniOut) {
    const double sr = d->sampleRate;
    double s = 0.0;       // swell progress 0...1
    double speed = ORBIT_SPEED_END;
    if (t < T_SWELL) {
        speed = ORBIT_SPEED_START + (ORBIT_SPEED_END - ORBIT_SPEED_START) * (t - T_ORBIT) / (T_SWELL - T_ORBIT);
    } else {
        s = (t - T_SWELL) / (T_BREAK - T_SWELL);
        if (s > 1.0) s = 1.0;
    }
    *omniOut = (float)s;
    d->bassAz = wrap180(d->orbitPhase * 360.0);

    double env = 1.0;
    if (t - T_ORBIT < BASS_ATTACK) env = (t - T_ORBIT) / BASS_ATTACK;
    if (t >= T_BREAK) {
        double r = (t - T_BREAK) / BASS_RELEASE;
        env = r >= 1.0 ? 0.0 : 0.5 * (1.0 + cos(M_PI * r));
    }
    const double level = (double)BASS_LEVEL + ((double)BASS_LEVEL_SWELL - (double)BASS_LEVEL) * s;

    const double hz = BASS_HZ * pow(BASS_GLIDE, s);
    const double dt = hz / sr;
    const double saw = 2.0 * d->bassPhase - 1.0 - polyblep(d->bassPhase, dt);
    const double sub = sin(2.0 * M_PI * d->subPhase);

    const double wob = 0.5 - 0.5 * cos(2.0 * M_PI * d->lfoPhase);
    const double lo = CUT_LO * pow(CUT_OPEN / CUT_LO, s);
    const double hi = CUT_HI * pow(CUT_OPEN / CUT_HI, s);
    double fc = lo * pow(hi / lo, wob);
    if (fc > 0.45 * sr) fc = 0.45 * sr;
    // Trapezoidal state variable filter (stable under fast cutoff changes).
    const double g = tan(M_PI * fc / sr), kq = 1.0 / BASS_Q;
    const double a1 = 1.0 / (1.0 + g * (g + kq)), a2 = g * a1, a3 = g * a2;
    const double v3 = saw - (double)d->lp2;
    const double v1 = a1 * (double)d->lp1 + a2 * v3;
    const double v2 = (double)d->lp2 + a2 * (double)d->lp1 + a3 * v3;
    d->lp1 = (float)(2.0 * v1 - (double)d->lp1);
    d->lp2 = (float)(2.0 * v2 - (double)d->lp2);

    const double x = BASS_SAW_MIX * v2 + BASS_SUB_MIX * sub;
    const double out = level * env * tanh(BASS_DRIVE * x);

    d->bassPhase += dt;
    if (d->bassPhase >= 1.0) d->bassPhase -= 1.0;
    d->subPhase += dt;
    if (d->subPhase >= 1.0) d->subPhase -= 1.0;
    d->lfoPhase += LFO_HZ / sr;
    if (d->lfoPhase >= 1.0) d->lfoPhase -= 1.0;
    d->orbitPhase += speed / sr;
    if (d->orbitPhase >= 1.0) d->orbitPhase -= 1.0;
    return (float)out;
}

int domine_demo_tick(DomineDemo *d, DomineDemoVoice *voices) {
    const int section = section_at(d, d->frame);
    if (section != d->section) d->hitIndex = 0; // hitIndex counts hits within a section
    d->section = section;
    for (int v = 0; v < DOMINE_DEMO_VOICES; v++) voices[v].sample = 0.0f;
    voices[2].azimuth = d->bassAz;
    voices[2].omni = 0.0f;
    if (section == DOMINE_DEMO_SECTION_FINISHED) {
        for (int k = 0; k < 2; k++) {
            d->kickActive[k] = 0;
            voices[k].azimuth = d->kickAz[k];
            voices[k].omni = d->kickOmni[k];
        }
        return section;
    }

    const double t = (double)d->frame / d->sampleRate;
    if (section == DOMINE_DEMO_SECTION_ORBIT || section == DOMINE_DEMO_SECTION_SWELL) {
        float omni = 0.0f;
        voices[2].sample = render_bass(d, t, &omni);
        voices[2].azimuth = d->bassAz;
        voices[2].omni = omni;
    }
    if (d->frame == d->nextHit) fire_hit(d, section);
    for (int k = 0; k < 2; k++) {
        voices[k].sample = render_kick(d, k);
        voices[k].azimuth = d->kickAz[k];
        voices[k].omni = d->kickOmni[k];
    }
    d->frame++;
    return section;
}
