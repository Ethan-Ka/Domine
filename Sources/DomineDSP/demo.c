// Showcase demo generator (DomineDemo.h). Real-time safe in tick: no
// allocation, locks, logging, or I/O. Deterministic: all state is in the
// struct and every value derives from the frame counter and the reset inputs.

#include "include/DomineDemo.h"

#include <math.h>
#include <string.h>

#define MAX_SPEAKERS 16
#define BEAT 0.5
#define BAR 2.0
#define STEP16 0.125

// Calibration: ticks alone for the first bar, then the roll call.
#define CAL_LEAD 2.0
// Section offsets after the Calibration (seconds from R).
#define X_SWEEP 6.0
#define X_ORBIT 12.0
#define X_SWELL 22.0
#define X_SILENCE 32.0
#define X_IMPACT 33.0
#define X_END 41.0

// Kick.
#define KICK_F_HI 240.0
#define KICK_F_LO 80.0
#define KICK_PITCH_TAU 0.030
#define KICK_ATTACK 0.001
#define KICK_TAU 0.090
#define KICK_LEN 0.220
#define KICK_FADE 0.020
#define KICK_DRIVE 1.6
#define BEATER_HZ 3200.0
#define BEATER_TAU 0.006
#define BEATER_LEVEL 0.22
#define TICK_TAU 0.0025
#define TICK_LEVEL 0.12
#define IMPACT_F_HI 200.0
#define IMPACT_F_LO 65.0
#define IMPACT_PITCH_TAU 0.080
#define IMPACT_TAU 0.500
#define IMPACT_LEN 2.000
#define IMPACT_FADE 0.400

// Sidechain.
#define DUCK_TAU 0.160
#define DUCK_SMOOTH 0.002

// Bass. |bass| <= level because the output goes through tanh.
#define BASS_HZ 55.0
#define BASS_DETUNE 2.009
#define ORBIT_START_TURNS 0.25  // +90, where the sweep ends
#define ORBIT_SPEED_START 0.25  // turns per second
#define ORBIT_SPEED_END 0.6
#define LFO_HZ 1.0
#define CUT_LO 250.0
#define CUT_HI 700.0
#define BASS_Q 1.4
#define BASS_DRIVE 1.4
#define BASS_LEVEL 0.38
#define BASS_ATTACK 0.300
#define BASS_RELEASE 6.0        // fade out over the first 6 s of the swell

// Sub.
#define SUB_HZ 55.0
#define PULSE_TAU 0.15
#define PULSE_LEN 0.45
#define SWELL_SUB_LEVEL 0.26
#define BOOM_F_HI 50.0
#define BOOM_F_LO 41.0
#define BOOM_GAIN 0.20
#define BOOM_TAU 1.8

// Chord.
#define DRONE_LEVEL 0.08
#define SWELL_LEVEL 0.40
#define IMPACT_CHORD_LEVEL 0.18
#define CHORD_RISE 1.5          // a fifth over the swell

// Sweep.
#define SWEEP_LEVEL 0.50
#define SWEEP_HZ 220.0

// Pings.
#define HAT_HP_HZ 6000.0

// Break cut before the silence.
#define CUT_FADE 0.030

// Limiter on the voice sum.
#define LIMIT 0.98f
#define LIMIT_RELEASE 0.050

static const double kPassLen[6] = { 2.0, 1.5, 1.0, 0.75, 0.5, 0.25 };

static uint64_t at(const DomineDemo *d, double seconds) {
    return (uint64_t)llround(seconds * d->sampleRate);
}

static double clamp01(double x) { return x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x); }
static double smooth01(double x) { x = clamp01(x); return x * x * (3.0 - 2.0 * x); }
static double advance(double p, double inc) { p += inc; return p >= 1.0 ? p - 1.0 : p; }
static double sat(double x, double drive) { return tanh(drive * x) / tanh(drive); }

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

static float white(DomineDemo *d) {
    d->noise = d->noise * 1664525u + 1013904223u;
    return (float)(d->noise >> 8) * (2.0f / 16777216.0f) - 1.0f;
}

// Decays from 1 at t = 0 to exactly 0 at t = len.
static double decay_to_zero(double t, double tau, double len) {
    if (t < 0.0) return 0.0;
    if (t >= len) return 0.0;
    const double e = exp(-len / tau);
    return (exp(-t / tau) - e) / (1.0 - e);
}

static double attack(double t, double len) { return t <= 0.0 ? 0.0 : (t < len ? t / len : 1.0); }

// 1 until the cut, then a cosine fade to exactly 0 at the silence.
static double cut_gain(double x) {
    const double u = (x - (X_SILENCE - CUT_FADE)) / CUT_FADE;
    if (u <= 0.0) return 1.0;
    return u >= 1.0 ? 0.0 : 0.5 * (1.0 + cos(M_PI * u));
}

static int section_at(const DomineDemo *d, uint64_t f) {
    const double r = d->rollEnd;
    if (f < at(d, r)) return DOMINE_DEMO_SECTION_ROLL_CALL;
    if (f < at(d, r + X_SWEEP)) return DOMINE_DEMO_SECTION_PING_PONG;
    if (f < at(d, r + X_ORBIT)) return DOMINE_DEMO_SECTION_SWEEP;
    if (f < at(d, r + X_SWELL)) return DOMINE_DEMO_SECTION_ORBIT;
    if (f < at(d, r + X_SILENCE)) return DOMINE_DEMO_SECTION_SWELL;
    if (f < at(d, r + X_IMPACT)) return DOMINE_DEMO_SECTION_SILENCE;
    if (f < at(d, r + X_END)) return DOMINE_DEMO_SECTION_DROP;
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
    const uint32_t n = d->speakerCount;
    double hitsLength;
    if (n <= 2) { d->rollCallHits = 8; hitsLength = 4.0; }
    else if (n <= 8) { d->rollCallHits = 2 * n; hitsLength = 2.0 * n * BEAT; }
    else { d->rollCallHits = n; hitsLength = n * BEAT * 0.5; }
    d->rollEnd = CAL_LEAD + ceil(hitsLength / BAR - 1e-9) * BAR;
    d->section = DOMINE_DEMO_SECTION_ROLL_CALL;
    d->kickAz[0] = d->kickAz[1] = d->order[0];
    d->duck = 1.0f;
    d->limGain = 1.0f;
    d->noise = 0x2545F491u;
    d->orbitPhase = ORBIT_START_TURNS;
    d->bassAz = wrap180(ORBIT_START_TURNS * 360.0);
    d->sweepAz = -90.0f;
}

double domine_demo_seconds(const DomineDemo *d) {
    return (double)d->frame / d->sampleRate;
}

double domine_demo_length(const DomineDemo *d) {
    return d->rollEnd + X_END;
}

float domine_demo_focus_azimuth(const DomineDemo *d) {
    switch (d->section) {
    case DOMINE_DEMO_SECTION_ROLL_CALL:
    case DOMINE_DEMO_SECTION_PING_PONG: return d->kickAz[d->lastKick];
    case DOMINE_DEMO_SECTION_SWEEP: return d->sweepAz;
    case DOMINE_DEMO_SECTION_ORBIT: return d->bassAz;
    default: return 0.0f;
    }
}

// MARK: - Hit list

typedef struct { double t; int section; float az, omni, gain; int impact; } HitInfo;

// Global hit g: time (s) and parameters. Returns 0 when there is none.
static int hit_info(const DomineDemo *d, uint32_t g, HitInfo *h) {
    const double r = d->rollEnd;
    const uint32_t n = d->speakerCount;
    h->omni = 0.0f;
    h->impact = 0;
    if (g < d->rollCallHits) {
        h->section = DOMINE_DEMO_SECTION_ROLL_CALL;
        if (n <= 2) {
            const uint32_t slot = g / 2;
            h->t = CAL_LEAD + slot * 2.0 * BEAT + (g & 1u) * BEAT * 0.5;
            h->az = d->order[slot % n];
            h->gain = (g & 1u) ? 0.60f : 0.45f;
        } else {
            h->t = CAL_LEAD + g * (n <= 8 ? BEAT : BEAT * 0.5);
            h->az = d->order[g % n];
            h->gain = 0.60f;
        }
        return 1;
    }
    g -= d->rollCallHits;
    if (g < 24) {
        h->section = DOMINE_DEMO_SECTION_PING_PONG;
        h->az = (g & 1u) ? 90.0f : -90.0f;
        if (g < 4) { h->t = r + g * BEAT; h->gain = 0.56f; }
        else if (g < 12) { h->t = r + BAR + (g - 4) * BEAT * 0.5; h->gain = 0.50f; }
        else { h->t = r + 2.0 * BAR + (g - 12) * STEP16; h->gain = 0.40f + 0.12f * (float)(g - 12) / 11.0f; }
        return 1;
    }
    g -= 24;
    if (g < 10) {
        h->section = DOMINE_DEMO_SECTION_ORBIT;
        h->t = r + X_ORBIT + g * 2.0 * BEAT;
        h->az = 0.0f; // the bass azimuth, filled in when fired
        h->gain = 0.45f;
        return 1;
    }
    g -= 10;
    if (g == 0) {
        h->section = DOMINE_DEMO_SECTION_DROP;
        h->t = r + X_IMPACT;
        h->az = 0.0f;
        h->omni = 1.0f;
        h->gain = 0.42f;
        h->impact = 1;
        return 1;
    }
    return 0;
}

static void schedule(DomineDemo *d) {
    HitInfo h;
    d->nextHit = hit_info(d, d->hitIndex, &h) ? at(d, h.t) : UINT64_MAX;
}

static void start_kick(DomineDemo *d, const HitInfo *h) {
    int k = d->nextKick;
    d->kickPhase[k] = 0.0;
    d->kickStart[k] = d->frame;
    d->kickAz[k] = h->az;
    d->kickOmni[k] = h->omni;
    d->kickGain[k] = h->gain;
    d->kickImpact[k] = h->impact;
    d->kickActive[k] = 1;
    d->lastKick = k;
    d->nextKick = k ^ 1;
    if (!h->impact) {
        d->duckStart = d->frame;
        d->duckDepth = 0.5f;
    }
}

static float render_kick(DomineDemo *d, int k, float tick) {
    if (!d->kickActive[k]) return 0.0f;
    const double sr = d->sampleRate;
    const double t = (double)(d->frame - d->kickStart[k]) / sr;
    const int imp = d->kickImpact[k];
    const double len = imp ? IMPACT_LEN : KICK_LEN;
    if (t >= len) { d->kickActive[k] = 0; return 0.0f; }
    const double fade = imp ? IMPACT_FADE : KICK_FADE;
    double env = t < KICK_ATTACK ? t / KICK_ATTACK : 1.0;
    if (t > len - fade) env *= 0.5 * (1.0 + cos(M_PI * (t - (len - fade)) / fade));
    const double body = sat(sin(2.0 * M_PI * d->kickPhase[k]), KICK_DRIVE) * exp(-t / (imp ? IMPACT_TAU : KICK_TAU));
    const double beater = BEATER_LEVEL * exp(-t / BEATER_TAU) * sin(2.0 * M_PI * BEATER_HZ * t)
                        + TICK_LEVEL * exp(-t / TICK_TAU) * (double)tick;
    const double lo = imp ? IMPACT_F_LO : KICK_F_LO, hi = imp ? IMPACT_F_HI : KICK_F_HI;
    const double hz = lo + (hi - lo) * exp(-t / (imp ? IMPACT_PITCH_TAU : KICK_PITCH_TAU));
    d->kickPhase[k] = advance(d->kickPhase[k], hz / sr);
    return (float)((double)d->kickGain[k] * env * (body + beater));
}

// MARK: - Bass

static double polyblep(double p, double dt) {
    if (p < dt) { double x = p / dt; return x + x - x * x - 1.0; }
    if (p > 1.0 - dt) { double x = (p - 1.0) / dt; return x * x + x + x + 1.0; }
    return 0.0;
}

static float render_bass(DomineDemo *d, double x) {
    const double sr = d->sampleRate;
    const double speed = x < X_SWELL
        ? ORBIT_SPEED_START + (ORBIT_SPEED_END - ORBIT_SPEED_START) * (x - X_ORBIT) / (X_SWELL - X_ORBIT)
        : ORBIT_SPEED_END;
    d->bassAz = wrap180(d->orbitPhase * 360.0);

    double env = smooth01((x - X_ORBIT) / BASS_ATTACK);
    if (x > X_SWELL) env *= 1.0 - smooth01((x - X_SWELL) / BASS_RELEASE);

    const double hz = BASS_HZ;
    const double dt = hz / sr, dt2 = hz * BASS_DETUNE / sr;
    const double saw = 2.0 * d->bassPhase - 1.0 - polyblep(d->bassPhase, dt);
    const double saw2 = 2.0 * d->bassPhase2 - 1.0 - polyblep(d->bassPhase2, dt2);
    const double sub = sin(2.0 * M_PI * d->subPhase);

    const double wob = 0.5 - 0.5 * cos(2.0 * M_PI * d->lfoPhase);
    double fc = CUT_LO * pow(CUT_HI / CUT_LO, wob);
    if (fc > 0.45 * sr) fc = 0.45 * sr;
    // Trapezoidal state variable filter (stable under fast cutoff changes).
    const double g = tan(M_PI * fc / sr), kq = 1.0 / BASS_Q;
    const double a1 = 1.0 / (1.0 + g * (g + kq)), a2 = g * a1, a3 = g * a2;
    const double in = 0.67 * (saw + 0.5 * saw2);
    const double v3 = in - (double)d->lp2;
    const double v1 = a1 * (double)d->lp1 + a2 * v3;
    const double v2 = (double)d->lp2 + a2 * (double)d->lp1 + a3 * v3;
    d->lp1 = (float)(2.0 * v1 - (double)d->lp1);
    d->lp2 = (float)(2.0 * v2 - (double)d->lp2);

    const double out = BASS_LEVEL * env * (double)d->duck * tanh(BASS_DRIVE * (0.6 * v2 + 0.45 * sub));

    d->bassPhase = advance(d->bassPhase, dt);
    d->bassPhase2 = advance(d->bassPhase2, dt2);
    d->subPhase = advance(d->subPhase, dt);
    d->lfoPhase = advance(d->lfoPhase, LFO_HZ / sr);
    d->orbitPhase = advance(d->orbitPhase, speed / sr);
    return (float)out;
}

// MARK: - Sub (pulses, swell sub, boom)

static double swell_progress(double x) { return clamp01((x - X_SWELL) / (X_SILENCE - X_SWELL)); }
static double chord_ratio(double x) {
    if (x >= X_SILENCE) return 1.0; // the impact resolves to the root
    return 1.0 + (CHORD_RISE - 1.0) * smooth01((x - X_SWELL) / (X_SILENCE - X_SWELL));
}

static float render_sub(DomineDemo *d, double x) {
    const double sr = d->sampleRate;
    double out = 0.0;
    if (d->pulseActive) {
        const double t = (double)(d->frame - d->pulseStart) / sr;
        if (t >= PULSE_LEN) d->pulseActive = 0;
        else out += (double)d->pulseGain * attack(t, 0.003) * decay_to_zero(t, PULSE_TAU, PULSE_LEN)
                  * sat(sin(2.0 * M_PI * SUB_HZ * t), 2.5);
    }
    if (x >= X_SWELL && x < X_SILENCE) {
        const double s = swell_progress(x);
        out += SWELL_SUB_LEVEL * s * s * cut_gain(x) * sat(sin(2.0 * M_PI * d->lowPhase), 1.8);
        d->lowPhase = advance(d->lowPhase, SUB_HZ * chord_ratio(x) / sr);
    }
    if (x >= X_IMPACT) {
        const double t = x - X_IMPACT;
        out += BOOM_GAIN * attack(t, 0.005) * decay_to_zero(t, BOOM_TAU, X_END - X_IMPACT)
             * sat(sin(2.0 * M_PI * d->boomPhase), 2.0);
        const double hz = BOOM_F_LO + (BOOM_F_HI - BOOM_F_LO) * exp(-t / 0.4);
        d->boomPhase = advance(d->boomPhase, hz / sr);
    }
    return (float)out;
}

// MARK: - Chord

static const double kChordHz[DOMINE_DEMO_CHORD_PARTIALS] = {
    110.0, 110.33, 164.81, 164.32, 220.0, 220.88, 277.18, 329.63, 330.62, 440.0, 493.88, 659.26,
};
static const double kChordW[DOMINE_DEMO_CHORD_PARTIALS] = {
    1.0, 1.0, 0.8, 0.8, 0.7, 0.7, 0.5, 0.5, 0.5, 0.35, 0.3, 0.25,
};

// Renders both chord voices (side 0 even partials, side 1 odd partials).
static void render_chord(DomineDemo *d, double t, double x, DomineDemoVoice *v) {
    double level, bright, spread, omni;
    if (x < X_SWELL) {
        level = DRONE_LEVEL * smooth01(t / 4.0);
        bright = 0.25; spread = 0.0; omni = 0.25;
    } else if (x < X_SILENCE) {
        const double s = swell_progress(x);
        level = (DRONE_LEVEL + (SWELL_LEVEL - DRONE_LEVEL) * (0.6 * s + 0.4 * s * s)) * cut_gain(x);
        bright = 0.25 + 0.75 * s;
        spread = 90.0 * smooth01(s);
        omni = 0.25 + 0.25 * s;
    } else {
        const double u = x - X_IMPACT;
        level = IMPACT_CHORD_LEVEL * attack(u, 0.02) * decay_to_zero(u, 2.2, X_END - X_IMPACT);
        bright = 0.4 + 0.6 * decay_to_zero(u, 1.5, X_END - X_IMPACT);
        spread = 90.0; omni = 0.5;
    }
    if (x < X_SWELL) level *= (double)d->duck;
    const double ratio = chord_ratio(x);
    double sum[2] = { 0.0, 0.0 }, wsum[2] = { 0.0, 0.0 };
    for (int i = 0; i < DOMINE_DEMO_CHORD_PARTIALS; i++) {
        const double w = kChordW[i] * (i < 6 ? 1.0 : bright);
        const double shimmer = 0.85 + 0.15 * sin(2.0 * M_PI * (0.11 + 0.037 * i) * t);
        sum[i & 1] += w * shimmer * sin(2.0 * M_PI * d->chordPhase[i]);
        wsum[i & 1] += kChordW[i];
        d->chordPhase[i] = advance(d->chordPhase[i], kChordHz[i] * ratio / d->sampleRate);
    }
    for (int s = 0; s < 2; s++) {
        v[s].sample = level > 0.0 ? (float)(level * sum[s] / wsum[s]) : 0.0f;
        v[s].azimuth = (float)(s == 0 ? -spread : spread);
        v[s].omni = (float)omni;
    }
}

// MARK: - Ticks, hats and pings

static void start_ping(DomineDemo *d, float amp, float tau, float hz, float az, int noise) {
    d->pingStart = d->frame;
    d->pingAmp = amp;
    d->pingTau = tau;
    d->pingHz = hz;
    d->pingAz = az;
    d->pingNoise = noise;
    d->pingActive = 1;
}

static void grid_step(DomineDemo *d, uint32_t k) {
    const double t = k * STEP16, x = t - d->rollEnd;
    if (x < 0.0) {
        // Calibration ticks on every beat.
        if (k % 4 == 0) start_ping(d, 0.06f, 0.008f, 3520.0f, 0.0f, 0);
    } else if (x < X_SWEEP) {
        // Sub pulse on every beat.
        if (k % 4 == 0) {
            d->pulseStart = d->frame;
            d->pulseGain = (float)(0.10 + 0.06 * x / X_SWEEP);
            d->pulseActive = 1;
        }
    } else if (x >= X_ORBIT + 2.0 && x < X_SWELL) {
        if (k % 4 == 2) start_ping(d, 0.07f, 0.03f, 0.0f, wrap180(-(double)d->bassAz), 1);
    } else if (x >= X_SWELL + 2.0 && x < X_SILENCE - 0.1) {
        static const float hz[6] = { 1760.0f, 2217.5f, 2637.0f, 3322.4f, 3520.0f, 4434.9f };
        const uint32_t h = (k * 2654435761u) >> 24;
        if (h % 3 == 0) return;
        const uint32_t pos = k % 8;
        const double f = pos / 7.0;
        const double az = ((k / 8) & 1u) ? 90.0 - 180.0 * f : -90.0 + 180.0 * f;
        const double s = swell_progress(x);
        start_ping(d, (float)(0.04 + 0.06 * s), 0.02f, hz[h % 6] * (float)chord_ratio(x), (float)az, 0);
    }
}

static float render_ping(DomineDemo *d, float n) {
    const double sr = d->sampleRate;
    const double c = 1.0 - exp(-2.0 * M_PI * fmin(HAT_HP_HZ, 0.4 * sr) / sr);
    d->pingLp += (float)c * (n - d->pingLp);
    if (!d->pingActive) return 0.0f;
    const double t = (double)(d->frame - d->pingStart) / sr;
    const double len = 5.0 * (double)d->pingTau;
    if (t >= len) { d->pingActive = 0; return 0.0f; }
    const double env = attack(t, 0.0005) * decay_to_zero(t, d->pingTau, len);
    const double src = d->pingNoise ? 0.6 * (double)(n - d->pingLp)
                                     : sin(2.0 * M_PI * fmin((double)d->pingHz, 0.45 * sr) * t);
    return (float)((double)d->pingAmp * env * src);
}

// MARK: - Sweep and noise

// Continuous pass position (0...6) at x, or -1 before the sweep.
static double sweep_pos(double x, double *u, int *pass) {
    double t = x - X_SWEEP;
    if (t < 0.0) { *u = 0.0; *pass = 0; return 0.0; }
    for (int k = 0; k < 6; k++) {
        if (t < kPassLen[k]) { *u = t / kPassLen[k]; *pass = k; return k + *u; }
        t -= kPassLen[k];
    }
    *u = 1.0; *pass = 5;
    return 6.0;
}

static float svf_noise(DomineDemo *d, double fc, double q, float n, int lowpass) {
    const double sr = d->sampleRate;
    if (fc > 0.45 * sr) fc = 0.45 * sr;
    const double kq = 1.0 / q, g = tan(M_PI * fc / sr);
    const double a1 = 1.0 / (1.0 + g * (g + kq)), a2 = g * a1, a3 = g * a2;
    const double v3 = (double)n - (double)d->fxLp2;
    const double v1 = a1 * (double)d->fxLp1 + a2 * v3;
    const double v2 = (double)d->fxLp2 + a2 * (double)d->fxLp1 + a3 * v3;
    d->fxLp1 = (float)(2.0 * v1 - (double)d->fxLp1);
    d->fxLp2 = (float)(2.0 * v2 - (double)d->fxLp2);
    return (float)(lowpass ? v2 : kq * v1);
}

static float render_fx(DomineDemo *d, double x, float n, DomineDemoVoice *v) {
    const double sr = d->sampleRate;
    if (x >= X_SWEEP - BEAT && x < X_ORBIT + 0.6) {
        double u;
        int k;
        const double pos = sweep_pos(x, &u, &k);
        double env, bend = 0.0;
        if (x < X_SWEEP) {
            env = 0.6 * smooth01((x - (X_SWEEP - BEAT)) / BEAT);
        } else if (x < X_ORBIT) {
            env = 0.6 + 0.4 * sin(M_PI * u);
            double depth = 0.05 * 2.0 / kPassLen[k];
            if (depth > 0.2) depth = 0.2;
            bend = depth * sin(2.0 * M_PI * u);
        } else {
            env = 0.6 * decay_to_zero(x - X_ORBIT, 0.15, 0.6);
        }
        const double hz = SWEEP_HZ * pow(2.0, pos / 6.0) * (1.0 + bend);
        const double ph = 2.0 * M_PI * d->sweepPhase;
        const double tone = (sin(ph) + 0.3 * sin(2.0 * ph) + 0.15 * sin(3.0 * ph)) / 1.45;
        d->sweepPhase = advance(d->sweepPhase, hz / sr);
        const double noise = svf_noise(d, 1500.0 * pow(2.0, pos / 4.0) * (1.0 + 2.0 * bend), 2.0, n, 0);
        d->sweepAz = wrap180(-90.0 + 180.0 * pos);
        v->azimuth = d->sweepAz;
        v->omni = 0.0f;
        return (float)(SWEEP_LEVEL * env * (0.65 * tone + 0.35 * noise));
    }
    if (x >= X_IMPACT) {
        const double t = x - X_IMPACT;
        const double fc = 10000.0 * pow(200.0 / 10000.0, clamp01(t / 3.0));
        const double y = svf_noise(d, fc, 0.8, n, 1);
        v->azimuth = 0.0f;
        v->omni = 1.0f;
        return (float)(0.12 * attack(t, 0.002) * decay_to_zero(t, 0.7, 4.0) * y);
    }
    return 0.0f;
}

// MARK: - Tick

int domine_demo_tick(DomineDemo *d, DomineDemoVoice *voices) {
    const int section = section_at(d, d->frame);
    d->section = section;
    for (int v = 0; v < DOMINE_DEMO_VOICES; v++) {
        voices[v].sample = 0.0f;
        voices[v].azimuth = 0.0f;
        voices[v].omni = 0.0f;
    }
    for (int k = 0; k < 2; k++) {
        voices[k].azimuth = d->kickAz[k];
        voices[k].omni = d->kickOmni[k];
    }
    voices[2].azimuth = d->bassAz;
    voices[3].omni = 1.0f;
    if (section == DOMINE_DEMO_SECTION_FINISHED) {
        d->kickActive[0] = d->kickActive[1] = d->pingActive = d->pulseActive = 0;
        return section;
    }
    if (d->frame == 0) schedule(d);

    const double t = (double)d->frame / d->sampleRate;
    const double x = t - d->rollEnd;
    const float nKick = white(d), nPing = white(d), nFx = white(d);

    // Sidechain duck.
    const double dt = (double)(d->frame - d->duckStart) / d->sampleRate;
    const double target = 1.0 - (double)d->duckDepth * exp(-dt / DUCK_TAU);
    d->duck += (float)((1.0 - exp(-1.0 / (DUCK_SMOOTH * d->sampleRate))) * (target - (double)d->duck));

    if (d->frame >= at(d, d->rollEnd + X_ORBIT) && d->frame < at(d, d->rollEnd + X_SWELL + BASS_RELEASE)) {
        voices[2].sample = render_bass(d, x);
        voices[2].azimuth = d->bassAz;
    }
    if (d->frame == d->nextHit) {
        HitInfo h;
        if (hit_info(d, d->hitIndex, &h)) {
            if (h.section == DOMINE_DEMO_SECTION_ORBIT) h.az = d->bassAz;
            start_kick(d, &h);
        }
        d->hitIndex++;
        schedule(d);
    }
    for (int k = 0; k < 2; k++) {
        voices[k].sample = render_kick(d, k, nKick);
        voices[k].azimuth = d->kickAz[k];
        voices[k].omni = d->kickOmni[k];
    }
    if (d->frame == at(d, d->step16 * STEP16)) {
        grid_step(d, d->step16);
        d->step16++;
    }
    voices[3].sample = render_sub(d, x);
    render_chord(d, t, x, &voices[4]);
    voices[6].sample = (float)(render_ping(d, nPing) * cut_gain(x));
    voices[6].azimuth = d->pingAz;
    voices[7].sample = render_fx(d, x, nFx, &voices[7]);

    if (section == DOMINE_DEMO_SECTION_SILENCE) {
        for (int v = 0; v < DOMINE_DEMO_VOICES; v++) voices[v].sample = 0.0f;
    }

    // Safety limiter on the sum of absolute voice values.
    float sum = 0.0f;
    for (int v = 0; v < DOMINE_DEMO_VOICES; v++) sum += fabsf(voices[v].sample);
    float lim = d->limGain + (float)(1.0 - exp(-1.0 / (LIMIT_RELEASE * d->sampleRate))) * (1.0f - d->limGain);
    if (sum * lim > LIMIT) lim = LIMIT / sum;
    d->limGain = lim;
    if (lim < 1.0f)
        for (int v = 0; v < DOMINE_DEMO_VOICES; v++) voices[v].sample *= lim;

    d->frame++;
    return section;
}
