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

// Section offsets after the roll call (seconds from R).
#define X_ORBIT 6.0
#define X_SWELL 18.0
#define X_BREAK 21.5
#define X_DROP 22.0
#define X_END 26.0
#define HATS_START 2.0

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
#define DROP_F_HI 220.0
#define DROP_F_LO 60.0
#define DROP_PITCH_TAU 0.070
#define DROP_TAU 0.450
#define DROP_LEN 1.500
#define DROP_FADE 0.300

// Sidechain.
#define DUCK_TAU 0.160
#define DUCK_SMOOTH 0.002

// Bass. |bass| <= level because the output goes through tanh.
#define BASS_HZ 55.0
#define BASS_GLIDE 1.5          // 55 to 82.5 Hz over the swell
#define BASS_DETUNE 2.009       // second saw, an octave up and slightly sharp
#define ORBIT_SPEED_START 0.2   // turns per second
#define ORBIT_SPEED_END 0.8
#define LFO_HZ 4.0
#define CUT_LO 300.0
#define CUT_HI 900.0
#define CUT_OPEN 2000.0
#define BASS_Q 2.2
#define BASS_DRIVE 1.6
#define BASS_LEVEL 0.40
#define BASS_LEVEL_SWELL 0.52
#define BASS_ATTACK 0.010
#define CUT_FADE 0.030          // break cut

// Bed.
#define BED_LEVEL 0.10
#define BED_LEVEL_ORBIT 0.08
#define BED_LEVEL_SWELL 0.13
#define BED_LEVEL_DROP 0.17
#define BED_DROP_TAU 1.4

// Hats.
#define HAT_HP_HZ 6000.0

// Limiter on the voice sum.
#define LIMIT 0.98f
#define LIMIT_RELEASE 0.050

static uint64_t at(const DomineDemo *d, double seconds) {
    return (uint64_t)llround(seconds * d->sampleRate);
}

static double clamp01(double x) { return x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x); }

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
    if (t >= len) return 0.0;
    const double e = exp(-len / tau);
    return (exp(-t / tau) - e) / (1.0 - e);
}

static int section_at(const DomineDemo *d, uint64_t f) {
    const double r = d->rollEnd;
    if (f < at(d, r)) return DOMINE_DEMO_SECTION_ROLL_CALL;
    if (f < at(d, r + X_ORBIT)) return DOMINE_DEMO_SECTION_PING_PONG;
    if (f < at(d, r + X_SWELL)) return DOMINE_DEMO_SECTION_ORBIT;
    if (f < at(d, r + X_DROP)) return DOMINE_DEMO_SECTION_SWELL; // includes the break
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
    double bars = ceil(hitsLength / BAR - 1e-9);
    if (bars < 2.0) bars = 2.0;
    d->rollEnd = bars * BAR;
    d->section = DOMINE_DEMO_SECTION_ROLL_CALL;
    d->kickAz[0] = d->kickAz[1] = d->order[0];
    d->duck = 1.0f;
    d->limGain = 1.0f;
    d->noise = 0x2545F491u;
    d->step16 = (uint32_t)llround(HATS_START / STEP16);
}

double domine_demo_seconds(const DomineDemo *d) {
    return (double)d->frame / d->sampleRate;
}

double domine_demo_length(const DomineDemo *d) {
    return d->rollEnd + X_END;
}

float domine_demo_focus_azimuth(const DomineDemo *d) {
    if (d->section == DOMINE_DEMO_SECTION_ORBIT || d->section == DOMINE_DEMO_SECTION_SWELL) return d->bassAz;
    if (d->section == DOMINE_DEMO_SECTION_DROP) return 0.0f;
    return d->kickAz[d->lastKick];
}

// MARK: - Hit list

typedef struct { double t; int section; float az, omni, gain; int drop; } HitInfo;

// Global hit g: time (s) and parameters. Returns 0 when there is none.
static int hit_info(const DomineDemo *d, uint32_t g, HitInfo *h) {
    const double r = d->rollEnd;
    const uint32_t n = d->speakerCount;
    h->omni = 0.0f;
    h->drop = 0;
    if (g < d->rollCallHits) {
        h->section = DOMINE_DEMO_SECTION_ROLL_CALL;
        if (n <= 2) {
            const uint32_t slot = g / 2;
            h->t = slot * 2.0 * BEAT + (g & 1u) * STEP16 * 2.0;
            h->az = d->order[slot % n];
            h->gain = (g & 1u) ? 0.62f : 0.48f;
        } else {
            h->t = g * (n <= 8 ? BEAT : BEAT * 0.5);
            h->az = d->order[g % n];
            h->gain = 0.62f;
        }
        return 1;
    }
    g -= d->rollCallHits;
    if (g < 24) {
        h->section = DOMINE_DEMO_SECTION_PING_PONG;
        h->az = (g & 1u) ? 90.0f : -90.0f;
        if (g < 4) { h->t = r + g * BEAT; h->gain = 0.62f; }
        else if (g < 12) { h->t = r + BAR + (g - 4) * BEAT * 0.5; h->gain = 0.56f; }
        else { h->t = r + 2.0 * BAR + (g - 12) * STEP16; h->gain = 0.44f + 0.12f * (float)(g - 12) / 11.0f; }
        return 1;
    }
    g -= 24;
    if (g < 24) {
        h->section = DOMINE_DEMO_SECTION_ORBIT;
        h->t = r + X_ORBIT + g * BEAT;
        h->az = 0.0f; // filled with the bass azimuth when fired
        h->gain = 0.50f;
        return 1;
    }
    g -= 24;
    if (g < 12) {
        h->section = DOMINE_DEMO_SECTION_SWELL;
        if (g < 4) h->t = r + X_SWELL + g * BEAT;
        else if (g < 8) h->t = r + X_SWELL + BAR + (g - 4) * BEAT * 0.5;
        else h->t = r + X_SWELL + 1.5 * BAR + (g - 8) * STEP16;
        h->az = 0.0f;
        h->gain = 0.30f + 0.12f * (float)g / 11.0f;
        return 1;
    }
    g -= 12;
    if (g == 0) {
        h->section = DOMINE_DEMO_SECTION_DROP;
        h->t = r + X_DROP;
        h->az = 0.0f;
        h->omni = 1.0f;
        h->gain = 0.60f;
        h->drop = 1;
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
    d->kickDecay[k] = (float)(h->drop ? DROP_TAU : KICK_TAU);
    d->kickLen[k] = (float)(h->drop ? DROP_LEN : KICK_LEN);
    d->kickActive[k] = 1;
    d->lastKick = k;
    d->nextKick = k ^ 1;
    d->duckStart = d->frame;
    d->duckDepth = h->drop ? 0.75f : 0.6f;
}

static float render_kick(DomineDemo *d, int k, float tick) {
    if (!d->kickActive[k]) return 0.0f;
    const double sr = d->sampleRate;
    const double t = (double)(d->frame - d->kickStart[k]) / sr;
    const double len = d->kickLen[k];
    if (t >= len) { d->kickActive[k] = 0; return 0.0f; }
    const int drop = len > 0.5;
    const double fade = drop ? DROP_FADE : KICK_FADE;
    double env = t < KICK_ATTACK ? t / KICK_ATTACK : 1.0;
    if (t > len - fade) env *= 0.5 * (1.0 + cos(M_PI * (t - (len - fade)) / fade));
    const double body = tanh(KICK_DRIVE * sin(2.0 * M_PI * d->kickPhase[k])) / tanh(KICK_DRIVE)
                      * exp(-t / (double)d->kickDecay[k]);
    const double beater = BEATER_LEVEL * exp(-t / BEATER_TAU) * sin(2.0 * M_PI * BEATER_HZ * t)
                        + TICK_LEVEL * exp(-t / TICK_TAU) * (double)tick;
    const double lo = drop ? DROP_F_LO : KICK_F_LO, hi = drop ? DROP_F_HI : KICK_F_HI;
    const double hz = lo + (hi - lo) * exp(-t / (drop ? DROP_PITCH_TAU : KICK_PITCH_TAU));
    double ph = d->kickPhase[k] + hz / sr;
    if (ph >= 1.0) ph -= 1.0;
    d->kickPhase[k] = ph;
    return (float)((double)d->kickGain[k] * env * (body + beater));
}

// MARK: - Bass

static double polyblep(double p, double dt) {
    if (p < dt) { double x = p / dt; return x + x - x * x - 1.0; }
    if (p > 1.0 - dt) { double x = (p - 1.0) / dt; return x * x + x + x + 1.0; }
    return 0.0;
}

static double advance(double p, double inc) {
    p += inc;
    return p >= 1.0 ? p - 1.0 : p;
}

// Swell progress 0...1 at time x after R.
static double swell_progress(double x) {
    return clamp01((x - X_SWELL) / (X_BREAK - X_SWELL));
}

// Gain of everything that cuts at the break: 1, then a cosine fade to 0.
static double break_cut(double x) {
    if (x < X_BREAK) return 1.0;
    const double u = (x - X_BREAK) / CUT_FADE;
    return u >= 1.0 ? 0.0 : 0.5 * (1.0 + cos(M_PI * u));
}

static float render_bass(DomineDemo *d, double x) {
    const double sr = d->sampleRate;
    const double s = swell_progress(x);
    const double speed = x < X_SWELL
        ? ORBIT_SPEED_START + (ORBIT_SPEED_END - ORBIT_SPEED_START) * (x - X_ORBIT) / (X_SWELL - X_ORBIT)
        : ORBIT_SPEED_END;
    d->bassOmni = (float)s;
    d->bassAz = wrap180(d->orbitPhase * 360.0);

    double env = x - X_ORBIT < BASS_ATTACK ? clamp01((x - X_ORBIT) / BASS_ATTACK) : 1.0;
    env *= break_cut(x);
    const double level = BASS_LEVEL + (BASS_LEVEL_SWELL - BASS_LEVEL) * s;

    const double hz = BASS_HZ * pow(BASS_GLIDE, s);
    const double dt = hz / sr, dt2 = hz * BASS_DETUNE / sr;
    const double saw = 2.0 * d->bassPhase - 1.0 - polyblep(d->bassPhase, dt);
    const double saw2 = 2.0 * d->bassPhase2 - 1.0 - polyblep(d->bassPhase2, dt2);
    const double sub = sin(2.0 * M_PI * d->subPhase);

    const double wob = 0.5 - 0.5 * cos(2.0 * M_PI * d->lfoPhase);
    const double lo = CUT_LO * pow(CUT_OPEN / CUT_LO, s);
    const double hi = CUT_HI * pow(CUT_OPEN / CUT_HI, s);
    double fc = lo * pow(hi / lo, wob);
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

    const double out = level * env * (double)d->duck * tanh(BASS_DRIVE * (0.6 * v2 + 0.45 * sub));

    d->bassPhase = advance(d->bassPhase, dt);
    d->bassPhase2 = advance(d->bassPhase2, dt2);
    d->subPhase = advance(d->subPhase, dt);
    d->lfoPhase = advance(d->lfoPhase, LFO_HZ / sr);
    d->orbitPhase = advance(d->orbitPhase, speed / sr);
    return (float)out;
}

// MARK: - Bed

static float render_bed(DomineDemo *d, double t) {
    static const double hz[4] = { 55.0, 110.0, 164.81, 220.0 };
    static const double w[4] = { 0.15, 0.40, 0.25, 0.20 };
    const double x = t - d->rollEnd;
    double level, ratio = 1.0;
    if (x < X_DROP) {
        if (t < BAR) level = BED_LEVEL * 0.5 * (1.0 - cos(M_PI * t / BAR));
        else if (x < X_ORBIT - BEAT) level = BED_LEVEL;
        else if (x < X_ORBIT) level = BED_LEVEL + (BED_LEVEL_ORBIT - BED_LEVEL) * (x - (X_ORBIT - BEAT)) / BEAT;
        else if (x < X_SWELL) level = BED_LEVEL_ORBIT;
        else {
            const double s = swell_progress(x);
            level = BED_LEVEL_ORBIT + (BED_LEVEL_SWELL - BED_LEVEL_ORBIT) * s;
            ratio = pow(BASS_GLIDE, s);
        }
        level *= break_cut(x);
    } else {
        const double u = x - X_DROP;
        level = BED_LEVEL_DROP * decay_to_zero(u, BED_DROP_TAU, X_END - X_DROP);
        if (u < 0.005) level *= u / 0.005;
    }
    double sum = 0.0;
    for (int i = 0; i < 4; i++) {
        sum += w[i] * sin(2.0 * M_PI * d->bedPhase[i]);
        d->bedPhase[i] = advance(d->bedPhase[i], hz[i] * ratio / d->sampleRate);
    }
    return (float)(level * (double)d->duck * sum);
}

// MARK: - Hats

static void hat_step(DomineDemo *d, uint32_t k) {
    const double x = k * STEP16 - d->rollEnd;
    if (x >= X_BREAK) return;
    float amp = 0.0f, tau = 0.0f;
    if (k % 4 == 2) {
        amp = x < X_SWELL ? 0.10f : (float)(0.10 + 0.03 * swell_progress(x));
        tau = 0.035f;
    } else if ((k & 1u) && x >= X_ORBIT + 6.0) {
        amp = x < X_SWELL ? 0.045f : (float)(0.045 + 0.04 * swell_progress(x));
        tau = 0.014f;
    }
    if (amp == 0.0f) return;
    d->hatStart = d->frame;
    d->hatAmp = amp;
    d->hatTau = tau;
    // Mirror path: opposite side of the latest kick, or of the bass.
    if (x < X_ORBIT) {
        d->hatAz = wrap180(-(double)d->kickAz[d->lastKick]);
        d->hatOmni = 0.0f;
    } else {
        d->hatAz = wrap180(-(double)d->bassAz);
        d->hatOmni = d->bassOmni;
    }
    d->hatActive = 1;
}

static float render_hat(DomineDemo *d, float x) {
    double c = 1.0 - exp(-2.0 * M_PI * fmin(HAT_HP_HZ, 0.4 * d->sampleRate) / d->sampleRate);
    d->hatLp += (float)c * (x - d->hatLp);
    if (!d->hatActive) return 0.0f;
    const double t = (double)(d->frame - d->hatStart) / d->sampleRate;
    const double len = 5.0 * (double)d->hatTau;
    if (t >= len) { d->hatActive = 0; return 0.0f; }
    double env = decay_to_zero(t, d->hatTau, len);
    if (t < 0.0005) env *= t / 0.0005;
    return (float)((double)d->hatAmp * env * 0.6 * (double)(x - d->hatLp));
}

// MARK: - Noise effects

typedef struct { double amp, fc, mix, az, omni; } FxTarget;

static double expsweep(double a, double b, double u) { return a * pow(b / a, u); }

// Riser shape: rises as u^2 to peak at end, then a short tail.
static int riser(double t, double start, double end, double peak, FxTarget *f, double *u) {
    if (t < start || t >= end + 0.25) return 0;
    if (t < end) { *u = (t - start) / (end - start); f->amp = peak * *u * *u; }
    else { *u = 1.0; f->amp = peak * decay_to_zero(t - end, 0.05, 0.25); }
    return 1;
}

static void fx_target(const DomineDemo *d, double t, FxTarget *f) {
    const double r = d->rollEnd, x = t - r;
    double u;
    f->amp = 0.0; f->fc = 1000.0; f->mix = 0.0; f->az = 0.0; f->omni = 0.0;
    if (riser(t, r - BEAT * 2.0, r, 0.20, f, &u)) {
        f->fc = expsweep(500.0, 8000.0, u);
        f->az = -90.0 * u;
    } else if (riser(t, r + X_ORBIT - BEAT, r + X_ORBIT, 0.22, f, &u)) {
        f->fc = expsweep(700.0, 9000.0, u);
        f->az = 90.0 + 270.0 * u;
    } else if (x >= X_SWELL && x < X_BREAK + 0.1) {
        const double s = swell_progress(x);
        f->amp = (0.03 + 0.15 * s * s) * break_cut(x);
        f->fc = expsweep(300.0, 7000.0, s);
        f->az = -(double)d->bassAz;
        f->omni = s;
    }
    if (x >= X_BREAK && x < X_DROP) {
        const double v = (x - X_BREAK) / (X_DROP - X_BREAK);
        f->amp += 0.2 * v * v * v;
        f->fc = expsweep(1500.0, 9000.0, v);
        f->omni = 1.0;
    } else if (x >= X_DROP && x < X_DROP + 2.5) {
        const double v = x - X_DROP;
        f->amp = 0.2 * decay_to_zero(v, 0.4, 2.5);
        f->fc = expsweep(9000.0, 250.0, clamp01(v / 2.0));
        f->mix = 1.0;
        f->omni = 1.0;
    }
}

static float render_fx(DomineDemo *d, double t, float n, DomineDemoVoice *v) {
    FxTarget f;
    fx_target(d, t, &f);
    const double sr = d->sampleRate;
    const double sm = 1.0 - exp(-1.0 / (0.003 * sr));
    d->fxAmp += (float)(sm * (f.amp - (double)d->fxAmp));
    d->fxMix += (float)(sm * (f.mix - (double)d->fxMix));
    double fc = f.fc;
    if (fc > 0.45 * sr) fc = 0.45 * sr;
    const double kq = 1.0 / 1.5, g = tan(M_PI * fc / sr);
    const double a1 = 1.0 / (1.0 + g * (g + kq)), a2 = g * a1, a3 = g * a2;
    const double v3 = (double)n - (double)d->fxLp2;
    const double v1 = a1 * (double)d->fxLp1 + a2 * v3;
    const double v2 = (double)d->fxLp2 + a2 * (double)d->fxLp1 + a3 * v3;
    d->fxLp1 = (float)(2.0 * v1 - (double)d->fxLp1);
    d->fxLp2 = (float)(2.0 * v2 - (double)d->fxLp2);
    const double mix = (double)d->fxMix;
    v->azimuth = wrap180(f.az);
    v->omni = (float)f.omni;
    if (d->fxAmp < 1e-6f) return 0.0f;
    return (float)((double)d->fxAmp * ((1.0 - mix) * kq * v1 + mix * v2));
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
    voices[2].azimuth = d->bassAz;
    voices[3].omni = 1.0f;
    voices[4].azimuth = d->hatAz;
    for (int k = 0; k < 2; k++) {
        voices[k].azimuth = d->kickAz[k];
        voices[k].omni = d->kickOmni[k];
    }
    if (section == DOMINE_DEMO_SECTION_FINISHED) {
        d->kickActive[0] = d->kickActive[1] = d->hatActive = 0;
        return section;
    }
    if (d->frame == 0) schedule(d);

    const double t = (double)d->frame / d->sampleRate;
    const double x = t - d->rollEnd;
    const float nKick = white(d), nHat = white(d), nFx = white(d);

    // Sidechain duck.
    const double dt = (double)(d->frame - d->duckStart) / d->sampleRate;
    const double target = 1.0 - (double)d->duckDepth * exp(-dt / DUCK_TAU);
    d->duck += (float)((1.0 - exp(-1.0 / (DUCK_SMOOTH * d->sampleRate))) * (target - (double)d->duck));

    if (d->frame >= at(d, d->rollEnd + X_ORBIT) && d->frame < at(d, d->rollEnd + X_DROP)) {
        voices[2].sample = render_bass(d, x);
        voices[2].azimuth = d->bassAz;
        voices[2].omni = d->bassOmni;
    }
    if (d->frame == d->nextHit) {
        HitInfo h;
        if (hit_info(d, d->hitIndex, &h)) {
            if (h.section == DOMINE_DEMO_SECTION_ORBIT || h.section == DOMINE_DEMO_SECTION_SWELL) {
                h.az = d->bassAz;
                h.omni = d->bassOmni;
            }
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
    voices[3].sample = render_bed(d, t);
    if (d->frame == at(d, d->step16 * STEP16)) {
        hat_step(d, d->step16);
        d->step16++;
    }
    voices[4].sample = render_hat(d, nHat);
    voices[4].azimuth = d->hatAz;
    voices[4].omni = d->hatOmni;
    voices[5].sample = render_fx(d, t, nFx, &voices[5]);

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
