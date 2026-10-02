// N-speaker surround render kernel (DomineSurround.h, SPEC section 13).
// Structure follows quad.c: same tap handling, gain ramps, delay rings, mute
// fade and effects chain, with a VBAP pan matrix in place of fixed positions.
#include "DomineSurround.h"
#include "TapMix.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define NSPK DOMINE_SURROUND_MAX_SPEAKERS
#define NPROG 4 // program sources: L, R, ambience RL, ambience RR
#define RING_MIN_RATE 96000.0
#define GAIN_RAMP_S 0.03
#define ORBIT_MAX 720.0f
#define SURROUND_LEVEL_DEFAULT 0.7f
#define SPATIAL_AMOUNT_DEFAULT 0.6f
#define ON_SPEAKER_EPS 1e-9

typedef struct {
    float applied, start, target;
    uint32_t i, len;
    int init;
} GainState;

// Present speakers grouped by position (coincident speakers share a group),
// in clockwise order. Built once per process call; no allocation.
typedef struct {
    uint32_t count;            // speakers in the layout (gains written)
    uint32_t ngroups;
    double gaz[NSPK];          // group azimuth in degrees, wrapped
    uint32_t gstart[NSPK + 1]; // members of group g: members[gstart[g] ..< gstart[g + 1]]
    uint32_t members[NSPK];
} PanLayout;

struct DomineSurround {
    double sampleRate;
    // Speaker layout, seqlock.
    _Atomic uint32_t spkSeq;
    _Atomic uint32_t spkCount;
    _Atomic uint32_t spkAzBits[NSPK];
    // Field parameters.
    _Atomic uint32_t widthBits, rotationBits, orbitRateBits, levelBits;
    _Atomic uint32_t orbitResetReq;
    // Per speaker.
    _Atomic uint32_t gainBits[NSPK];
    _Atomic uint32_t delaySamples[NSPK];
    _Atomic uint32_t peakBits[NSPK];
    _Atomic int muted;
    _Atomic int toneSpeaker; // -1 off
    _Atomic int clickOn;
    // Demo control and status.
    _Atomic uint32_t demoStartReq;
    _Atomic int demoWanted;
    _Atomic int demoPlayingPub;
    _Atomic uint32_t demoSecondsBits, demoAzBits;
    _Atomic int demoSectionPub;
    // IOProc layout, set before the device starts.
    _Atomic uint32_t layoutFirst;
    _Atomic uint32_t layoutCount;
    _Atomic uint32_t layoutOut[NSPK];
    _Atomic uint32_t inputChannels;
    _Atomic uint32_t inputNonInterleaved;
    uint32_t maxDelay;
    TapMixer taps;

    // Render thread state.
    uint32_t rcount;      // speaker count from the last consistent read
    float raz[NSPK];
    uint32_t seenOrbitReset;
    double orbitPhase;    // degrees, wrapped
    int matrixInit;
    float gPrev[NPROG][NSPK];
    uint32_t fadeLength;   // samples in a full mute fade (also the demo crossfade)
    uint32_t fadePosition; // 0 = silent, fadeLength = full gain
    GainState gain[NSPK];
    float *ring[NSPK];
    uint32_t ringMask;
    uint32_t ringPos;
    DomineEQ *eq[NSPK];
    DomineBass *bass[NSPK];
    DomineCompressor *comp[NSPK];
    DomineSpatial *spatial;
    // Demo, render side.
    DomineDemo demo;
    uint32_t seenDemoReq;
    int demoPlaying;      // demo audio wanted (not stopped, not finished)
    int demoSection;
    uint32_t demoPos;     // 0 = program only, fadeLength = demo only
    // Test tone and click test, as in kernel.c.
    uint32_t toneFadeLength;
    int playingTone;      // speaker the tone envelope belongs to, -1 = none
    uint32_t toneLevel;   // 0 = program only, toneFadeLength = tone only
    double tonePhase, tonePhaseStep;
    uint32_t clickLevel;  // 0 = program only, toneFadeLength = clicks only
    uint32_t clickCounter, clickLength, clickPeriod;
};

typedef struct { float *data; uint32_t stride, frames; } OutCh;
typedef struct { const float *data; uint32_t stride, frames; } InCh;

static inline uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static inline float clamp01(float g) {
    if (!isfinite(g) || !(g > 0.0f)) return 0.0f;
    return g < 1.0f ? g : 1.0f;
}

static uint32_t next_pow2(uint32_t v) { uint32_t p = 1; while (p < v) p <<= 1; return p; }

// Wraps to (-180, 180]; non-finite is 0.
static double wrap180(double a) {
    if (!isfinite(a)) return 0.0;
    a = fmod(a, 360.0);
    if (a <= -180.0) a += 360.0;
    else if (a > 180.0) a -= 360.0;
    return a;
}

// Wraps to [0, 360).
static double wrap360(double a) {
    a = fmod(a, 360.0);
    if (a < 0.0) a += 360.0;
    if (a >= 360.0) a -= 360.0;
    return a;
}

// MARK: - Panning

static void pan_build(PanLayout *p, uint32_t count, const float *az, const uint8_t *present) {
    if (count > NSPK) count = NSPK;
    p->count = count;
    p->ngroups = 0;
    p->gstart[0] = 0;
    uint32_t idx[NSPK];
    double a[NSPK];
    uint32_t n = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (present != NULL && !present[i]) continue;
        const double w = wrap180((double)az[i]);
        // Insertion sort by azimuth, ties by index (stable).
        uint32_t j = n;
        while (j > 0 && a[j - 1] > w) { a[j] = a[j - 1]; idx[j] = idx[j - 1]; j--; }
        a[j] = w;
        idx[j] = i;
        n++;
    }
    if (n == 0) return;
    // Start at a real gap so a group never straddles the wrap at 180.
    uint32_t start = 0;
    for (uint32_t i = 0; i < n; i++) {
        const double gap = i == 0 ? a[0] + 360.0 - a[n - 1] : a[i] - a[i - 1];
        if (gap >= (double)DOMINE_SURROUND_COINCIDENT_DEG) { start = i; break; }
    }
    uint32_t m = 0;
    for (uint32_t k = 0; k < n; k++) {
        const uint32_t i = (start + k) % n;
        int newGroup = k == 0;
        if (!newGroup) {
            const uint32_t prev = (start + k - 1) % n;
            const double gap = wrap360(a[i] - a[prev]);
            newGroup = gap >= (double)DOMINE_SURROUND_COINCIDENT_DEG;
        }
        if (newGroup) {
            p->gaz[p->ngroups] = a[i];
            p->gstart[p->ngroups] = m;
            p->ngroups++;
        }
        p->members[m++] = idx[i];
        p->gstart[p->ngroups] = m;
    }
}

static void pan_group(const PanLayout *p, uint32_t g, double gain, float *gains) {
    const uint32_t b = p->gstart[g], e = p->gstart[g + 1];
    const double share = e - b == 1 ? gain : gain / sqrt((double)(e - b));
    for (uint32_t i = b; i < e; i++) gains[p->members[i]] = (float)share;
}

static void pan_source(const PanLayout *p, double sourceAz, float *gains) {
    for (uint32_t i = 0; i < p->count; i++) gains[i] = 0.0f;
    if (p->ngroups == 0) return;
    if (p->ngroups == 1) { pan_group(p, 0, 1.0, gains); return; }
    const double s = wrap180(sourceAz);
    // The enclosing pair starts at the group closest counter-clockwise of s.
    uint32_t ga = 0;
    double d = 360.0;
    for (uint32_t g = 0; g < p->ngroups; g++) {
        const double dg = wrap360(s - p->gaz[g]);
        if (dg < d) { d = dg; ga = g; }
    }
    const uint32_t gb = ga + 1 < p->ngroups ? ga + 1 : 0;
    const double arc = wrap360(p->gaz[gb] - p->gaz[ga]);
    if (d > arc) d = arc;
    if (d <= ON_SPEAKER_EPS) { pan_group(p, ga, 1.0, gains); return; }
    if (arc - d <= ON_SPEAKER_EPS) { pan_group(p, gb, 1.0, gains); return; }
    double ka, kb;
    if (arc < 180.0) {
        const double rad = M_PI / 180.0;
        ka = sin((arc - d) * rad);
        kb = sin(d * rad);
        const double norm = sqrt(ka * ka + kb * kb);
        ka /= norm;
        kb /= norm;
    } else {
        const double f = d / arc;
        ka = cos(f * M_PI * 0.5);
        kb = sin(f * M_PI * 0.5);
    }
    pan_group(p, ga, ka, gains);
    pan_group(p, gb, kb, gains);
}

void domine_surround_vbap(uint32_t count, const float *azimuthDeg, const uint8_t *present,
                          float sourceAz, float *gainsOut) {
    if (count == 0 || azimuthDeg == NULL || gainsOut == NULL) return;
    PanLayout p;
    const uint32_t n = count > NSPK ? NSPK : count;
    pan_build(&p, n, azimuthDeg, present);
    pan_source(&p, (double)sourceAz, gainsOut);
    for (uint32_t i = n; i < count; i++) gainsOut[i] = 0.0f;
}

void domine_surround_distance_comp(uint32_t count, const float *distanceM,
                                   float *delayMsOut, float *gainOut) {
    if (count == 0 || distanceM == NULL) return;
    double dmax = 0.0;
    for (uint32_t i = 0; i < count; i++) {
        const double d = isfinite(distanceM[i]) && distanceM[i] > 0.0f ? (double)distanceM[i] : 1.0;
        if (d > dmax) dmax = d;
    }
    for (uint32_t i = 0; i < count; i++) {
        const double d = isfinite(distanceM[i]) && distanceM[i] > 0.0f ? (double)distanceM[i] : 1.0;
        if (delayMsOut != NULL) delayMsOut[i] = (float)((dmax - d) / (double)DOMINE_SPEED_OF_SOUND * 1000.0);
        if (gainOut != NULL) gainOut[i] = d == dmax ? 1.0f : (float)(d / dmax);
    }
}

// MARK: - Lifecycle and setters

DomineSurround *domine_surround_create(double sampleRate, uint32_t maxFrames) {
    (void)maxFrames;
    if (!(sampleRate > 0.0) || !isfinite(sampleRate)) return NULL;
    DomineSurround *s = calloc(1, sizeof *s);
    if (s == NULL) return NULL;
    s->sampleRate = sampleRate;
    tapmix_init(&s->taps, sampleRate);
    const double ringRate = sampleRate > RING_MIN_RATE ? sampleRate : RING_MIN_RATE;
    s->maxDelay = (uint32_t)ceil(ringRate * DOMINE_MAX_DELAY_MS / 1000.0);
    const uint32_t size = next_pow2(s->maxDelay + 1);
    s->ringMask = size - 1;
    for (int i = 0; i < NSPK; i++) {
        s->ring[i] = calloc(size, sizeof(float));
        s->eq[i] = domine_eq_create(sampleRate);
        s->bass[i] = domine_bass_create(sampleRate);
        s->comp[i] = domine_compressor_create(sampleRate);
        atomic_init(&s->gainBits[i], f2u(1.0f));
        atomic_init(&s->delaySamples[i], 0);
        atomic_init(&s->peakBits[i], 0);
        atomic_init(&s->spkAzBits[i], 0);
        atomic_init(&s->layoutOut[i], DOMINE_NO_DEVICE);
    }
    s->spatial = domine_spatial_create(sampleRate);
    atomic_init(&s->spkSeq, 0);
    atomic_init(&s->spkCount, 0);
    atomic_init(&s->widthBits, f2u(DOMINE_SURROUND_WIDTH_DEFAULT));
    atomic_init(&s->rotationBits, 0);
    atomic_init(&s->orbitRateBits, 0);
    atomic_init(&s->levelBits, f2u(SURROUND_LEVEL_DEFAULT));
    atomic_init(&s->orbitResetReq, 0);
    atomic_init(&s->muted, 0);
    atomic_init(&s->demoStartReq, 0);
    atomic_init(&s->demoWanted, 0);
    atomic_init(&s->demoPlayingPub, 0);
    atomic_init(&s->demoSecondsBits, 0);
    atomic_init(&s->demoAzBits, 0);
    atomic_init(&s->demoSectionPub, DOMINE_DEMO_SECTION_IDLE);
    atomic_init(&s->layoutFirst, 0);
    atomic_init(&s->layoutCount, 0);
    atomic_init(&s->inputChannels, 0);
    atomic_init(&s->inputNonInterleaved, 0);
    {
        const uint32_t fade = (uint32_t)lround(sampleRate * DOMINE_FADE_MS / 1000.0);
        s->fadeLength = fade > 0 ? fade : 1;
        s->fadePosition = s->fadeLength;
    }
    s->demoSection = DOMINE_DEMO_SECTION_IDLE;
    {
        const uint32_t toneFade = (uint32_t)lround(sampleRate * DOMINE_TONE_FADE_MS / 1000.0);
        s->toneFadeLength = toneFade > 0 ? toneFade : 1;
        s->tonePhaseStep = 1.0 / sampleRate;
        s->playingTone = -1;
        const uint32_t clickLength = (uint32_t)lround(sampleRate * DOMINE_CLICK_MS / 1000.0);
        s->clickLength = clickLength > 0 ? clickLength : 1;
        const uint32_t clickPeriod = (uint32_t)lround(sampleRate * DOMINE_CLICK_PERIOD_MS / 1000.0);
        s->clickPeriod = clickPeriod > s->clickLength ? clickPeriod : s->clickLength + 1;
    }
    atomic_init(&s->toneSpeaker, -1);
    atomic_init(&s->clickOn, 0);
    int ok = s->spatial != NULL;
    for (int i = 0; i < NSPK; i++) ok = ok && s->ring[i] && s->eq[i] && s->bass[i] && s->comp[i];
    if (!ok) { domine_surround_destroy(s); return NULL; }
    const DomineSpatialParams sp = { SPATIAL_AMOUNT_DEFAULT, 15.0f, 5000.0f };
    domine_spatial_set_params(s->spatial, &sp);
    return s;
}

void domine_surround_destroy(DomineSurround *s) {
    if (s == NULL) return;
    for (int i = 0; i < NSPK; i++) {
        free(s->ring[i]);
        if (s->eq[i]) domine_eq_destroy(s->eq[i]);
        if (s->bass[i]) domine_bass_destroy(s->bass[i]);
        if (s->comp[i]) domine_compressor_destroy(s->comp[i]);
    }
    domine_spatial_destroy(s->spatial);
    free(s);
}

void domine_surround_set_speakers(DomineSurround *s, uint32_t count, const float *azimuthDeg) {
    if (s == NULL) return;
    if (count > NSPK) count = NSPK;
    if (count > 0 && azimuthDeg == NULL) return;
    const uint32_t q = atomic_load_explicit(&s->spkSeq, memory_order_relaxed);
    atomic_store_explicit(&s->spkSeq, q + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&s->spkCount, count, memory_order_relaxed);
    for (uint32_t i = 0; i < count; i++)
        atomic_store_explicit(&s->spkAzBits[i], f2u((float)wrap180((double)azimuthDeg[i])), memory_order_relaxed);
    atomic_store_explicit(&s->spkSeq, q + 2, memory_order_release);
}

void domine_surround_set_width(DomineSurround *s, float degrees) {
    if (s == NULL) return;
    if (!isfinite(degrees)) degrees = DOMINE_SURROUND_WIDTH_DEFAULT;
    if (degrees < DOMINE_SURROUND_WIDTH_MIN) degrees = DOMINE_SURROUND_WIDTH_MIN;
    if (degrees > DOMINE_SURROUND_WIDTH_MAX) degrees = DOMINE_SURROUND_WIDTH_MAX;
    atomic_store_explicit(&s->widthBits, f2u(degrees), memory_order_relaxed);
}

void domine_surround_set_rotation(DomineSurround *s, float degrees) {
    if (s == NULL) return;
    atomic_store_explicit(&s->rotationBits, f2u((float)wrap180((double)degrees)), memory_order_relaxed);
}

void domine_surround_set_orbit_rate(DomineSurround *s, float degreesPerSecond) {
    if (s == NULL) return;
    float r = isfinite(degreesPerSecond) ? degreesPerSecond : 0.0f;
    if (r > ORBIT_MAX) r = ORBIT_MAX;
    if (r < -ORBIT_MAX) r = -ORBIT_MAX;
    atomic_store_explicit(&s->orbitRateBits, f2u(r), memory_order_relaxed);
}

void domine_surround_reset_orbit(DomineSurround *s) {
    if (s == NULL) return;
    atomic_fetch_add_explicit(&s->orbitResetReq, 1, memory_order_relaxed);
}

void domine_surround_set_surround_level(DomineSurround *s, float level) {
    if (s == NULL) return;
    atomic_store_explicit(&s->levelBits, f2u(clamp01(level)), memory_order_relaxed);
}

void domine_surround_set_spatial(DomineSurround *s, const DomineSpatialParams *params) {
    if (s != NULL) domine_spatial_set_params(s->spatial, params);
}

void domine_surround_set_gain(DomineSurround *s, uint32_t speaker, float gain) {
    if (s == NULL || speaker >= NSPK) return;
    atomic_store_explicit(&s->gainBits[speaker], f2u(clamp01(gain)), memory_order_relaxed);
}

void domine_surround_set_delay_ms(DomineSurround *s, uint32_t speaker, float ms) {
    if (s == NULL || speaker >= NSPK) return;
    if (!isfinite(ms) || ms < 0.0f) ms = 0.0f;
    if (ms > DOMINE_MAX_DELAY_MS) ms = DOMINE_MAX_DELAY_MS;
    uint32_t n = (uint32_t)llround((double)ms * s->sampleRate / 1000.0);
    if (n > s->maxDelay) n = s->maxDelay;
    atomic_store_explicit(&s->delaySamples[speaker], n, memory_order_relaxed);
}

void domine_surround_set_eq(DomineSurround *s, uint32_t speaker, const DomineEQParams *p) {
    if (s != NULL && speaker < NSPK) domine_eq_set_params(s->eq[speaker], p);
}
void domine_surround_set_bass(DomineSurround *s, uint32_t speaker, const DomineBassParams *p) {
    if (s != NULL && speaker < NSPK) domine_bass_set_params(s->bass[speaker], p);
}
void domine_surround_set_compressor(DomineSurround *s, uint32_t speaker, const DomineCompressorParams *p) {
    if (s != NULL && speaker < NSPK) domine_compressor_set_params(s->comp[speaker], p);
}

void domine_surround_set_muted(DomineSurround *s, int muted) {
    if (s == NULL) return;
    atomic_store_explicit(&s->muted, muted != 0, memory_order_relaxed);
}

void domine_surround_start_faded_out(DomineSurround *s) {
    if (s == NULL) return;
    s->fadePosition = 0;
}

void domine_surround_set_test_tone(DomineSurround *s, int speaker) {
    if (s == NULL) return;
    const int v = speaker >= 0 && speaker < NSPK ? speaker : -1;
    atomic_store_explicit(&s->toneSpeaker, v, memory_order_relaxed);
}

void domine_surround_set_click_test(DomineSurround *s, int on) {
    if (s == NULL) return;
    atomic_store_explicit(&s->clickOn, on != 0, memory_order_relaxed);
}

void domine_surround_set_demo(DomineSurround *s, int on) {
    if (s == NULL) return;
    atomic_store_explicit(&s->demoWanted, on != 0, memory_order_relaxed);
    if (on) atomic_fetch_add_explicit(&s->demoStartReq, 1, memory_order_release);
}

int domine_surround_demo_status(DomineSurround *s, float *seconds, float *azimuth, int *section) {
    if (s == NULL) return 0;
    if (seconds != NULL) *seconds = u2f(atomic_load_explicit(&s->demoSecondsBits, memory_order_relaxed));
    if (azimuth != NULL) *azimuth = u2f(atomic_load_explicit(&s->demoAzBits, memory_order_relaxed));
    if (section != NULL) *section = atomic_load_explicit(&s->demoSectionPub, memory_order_relaxed);
    return atomic_load_explicit(&s->demoPlayingPub, memory_order_relaxed);
}

float domine_surround_peak(DomineSurround *s, uint32_t speaker) {
    if (s == NULL || speaker >= NSPK) return 0.0f;
    return u2f(atomic_load_explicit(&s->peakBits[speaker], memory_order_relaxed));
}

// MARK: - Render

static InCh in_channel(const AudioBuffer *b, uint32_t ch) {
    InCh c = { NULL, 1, 0 };
    if (b->mData == NULL || b->mNumberChannels == 0 || ch >= b->mNumberChannels) return c;
    c.data = (const float *)b->mData + ch;
    c.stride = b->mNumberChannels;
    c.frames = b->mDataByteSize / (uint32_t)(sizeof(float) * b->mNumberChannels);
    return c;
}

static inline float read_in(const InCh *c, uint32_t f) {
    return (c->data != NULL && f < c->frames) ? c->data[(size_t)f * c->stride] : 0.0f;
}

static int map_out(AudioBufferList *abl, uint32_t flat, OutCh *o) {
    if (flat == DOMINE_NO_DEVICE) return 0;
    uint32_t base = 0;
    for (uint32_t b = 0; b < abl->mNumberBuffers; b++) {
        AudioBuffer *buf = &abl->mBuffers[b];
        const uint32_t n = buf->mNumberChannels;
        if (n == 0) continue;
        if (flat < base + n) {
            if (buf->mData == NULL) return 0;
            o->data = (float *)buf->mData + (flat - base);
            o->stride = n;
            o->frames = buf->mDataByteSize / (uint32_t)(sizeof(float) * n);
            return 1;
        }
        base += n;
    }
    return 0;
}

// Picks up the speaker layout; keeps the previous one if a write is in progress.
static void pickup_speakers(DomineSurround *s) {
    for (int attempt = 0; attempt < 4; attempt++) {
        const uint32_t a = atomic_load_explicit(&s->spkSeq, memory_order_acquire);
        if (a & 1u) continue;
        uint32_t n = atomic_load_explicit(&s->spkCount, memory_order_relaxed);
        if (n > NSPK) n = NSPK;
        float az[NSPK];
        for (uint32_t i = 0; i < n; i++) az[i] = u2f(atomic_load_explicit(&s->spkAzBits[i], memory_order_relaxed));
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&s->spkSeq, memory_order_relaxed) != a) continue;
        s->rcount = n;
        for (uint32_t i = 0; i < n; i++) s->raz[i] = az[i];
        return;
    }
}

// Demo voice gains on present speakers: (1 - omni) * vbap + omni / sqrt(N).
static void demo_voice_gains(const PanLayout *p, const uint8_t *present, uint32_t nPresent,
                             const DomineDemoVoice *v, float *gains) {
    pan_source(p, (double)v->azimuth, gains);
    const float omni = v->omni > 1.0f ? 1.0f : (v->omni > 0.0f ? v->omni : 0.0f);
    if (omni == 0.0f || nPresent == 0) return;
    const float flat = omni / sqrtf((float)nPresent);
    for (uint32_t k = 0; k < p->count; k++)
        gains[k] = present[k] ? (1.0f - omni) * gains[k] + flat : 0.0f;
}

static void surround_render(DomineSurround *s, InCh inL, InCh inR, const TapSet *tapSet,
                            AudioBufferList *out, uint32_t frames,
                            const uint32_t *offsets, uint32_t offsetCount) {
    for (uint32_t b = 0; b < out->mNumberBuffers; b++) {
        if (out->mBuffers[b].mData != NULL) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
    }

    const uint32_t n = s->rcount;
    uint8_t present[NSPK] = { 0 };
    uint32_t nPresent = 0;
    OutCh oc[NSPK][2];
    for (uint32_t k = 0; k < n; k++) {
        const uint32_t off = k < offsetCount ? offsets[k] : DOMINE_NO_DEVICE;
        present[k] = off != DOMINE_NO_DEVICE;
        nPresent += present[k];
        const int a = map_out(out, off, &oc[k][0]);
        const int b = present[k] && off != UINT32_MAX - 1 && map_out(out, off + 1, &oc[k][1]);
        if (!a) oc[k][0].data = NULL;
        if (!b) oc[k][1].data = NULL;
    }
    PanLayout pan;
    pan_build(&pan, n, s->raz, present);

    // Field: rotation plus orbit phase (end of this call).
    const float width = u2f(atomic_load_explicit(&s->widthBits, memory_order_relaxed));
    const float rotation = u2f(atomic_load_explicit(&s->rotationBits, memory_order_relaxed));
    const float rate = u2f(atomic_load_explicit(&s->orbitRateBits, memory_order_relaxed));
    const float level = u2f(atomic_load_explicit(&s->levelBits, memory_order_relaxed));
    const uint32_t resetReq = atomic_load_explicit(&s->orbitResetReq, memory_order_relaxed);
    if (resetReq != s->seenOrbitReset) { s->seenOrbitReset = resetReq; s->orbitPhase = 0.0; }
    if (rate != 0.0f) s->orbitPhase = wrap180(s->orbitPhase + (double)rate * (double)frames / s->sampleRate);
    const double field = (double)rotation + s->orbitPhase;

    // Target pan matrix with headroom.
    float gT[NPROG][NSPK];
    memset(gT, 0, sizeof gT);
    const double srcAz[NPROG] = { -(double)width, (double)width,
                                  -(double)DOMINE_SURROUND_REAR_AZ, (double)DOMINE_SURROUND_REAR_AZ };
    const int nsrc = nPresent >= 3 ? NPROG : 2;
    for (int src = 0; src < nsrc; src++) pan_source(&pan, srcAz[src] + field, gT[src]);
    for (uint32_t k = 0; k < n; k++) {
        float sum = 0.0f;
        for (int src = 0; src < nsrc; src++) sum += fabsf(gT[src][k]);
        if (sum > 1.0f) {
            for (int src = 0; src < nsrc; src++) gT[src][k] /= sum;
        }
    }
    if (!s->matrixInit) { memcpy(s->gPrev, gT, sizeof gT); s->matrixInit = 1; }
    float gStep[NPROG][NSPK];
    int ramping = 0, loopSrc = 2;
    for (int src = 0; src < NPROG; src++)
        for (uint32_t k = 0; k < NSPK; k++) {
            const float a = s->gPrev[src][k], b = gT[src][k];
            gStep[src][k] = frames > 0 ? (b - a) / (float)frames : 0.0f;
            if (a != b) ramping = 1;
            if (src >= 2 && (a != 0.0f || b != 0.0f)) loopSrc = NPROG;
        }

    uint32_t delay[NSPK];
    for (uint32_t k = 0; k < n; k++) {
        const float target = u2f(atomic_load_explicit(&s->gainBits[k], memory_order_relaxed));
        GainState *g = &s->gain[k];
        if (!g->init) {
            g->init = 1; g->applied = g->start = g->target = target; g->i = g->len = 0;
        } else if (target != g->target) {
            g->start = g->applied;
            g->target = target;
            g->i = 0;
            g->len = (uint32_t)llround(GAIN_RAMP_S * s->sampleRate);
            if (g->len == 0) g->applied = target;
        }
        delay[k] = atomic_load_explicit(&s->delaySamples[k], memory_order_relaxed);
    }

    // Demo control.
    const uint32_t demoReq = atomic_load_explicit(&s->demoStartReq, memory_order_acquire);
    if (demoReq != s->seenDemoReq) {
        s->seenDemoReq = demoReq;
        float az[NSPK];
        uint32_t m = 0;
        for (uint32_t k = 0; k < n; k++) if (present[k]) az[m++] = s->raz[k];
        domine_demo_reset(&s->demo, s->sampleRate, m, az);
        s->demoPlaying = 1;
        s->demoSection = DOMINE_DEMO_SECTION_ROLL_CALL;
    }
    if (!atomic_load_explicit(&s->demoWanted, memory_order_relaxed) && s->demoPlaying) {
        s->demoPlaying = 0;
        s->demoSection = DOMINE_DEMO_SECTION_IDLE;
    }
    float voiceGain[DOMINE_DEMO_VOICES][NSPK];
    float voiceAz[DOMINE_DEMO_VOICES], voiceOmni[DOMINE_DEMO_VOICES];
    for (int v = 0; v < DOMINE_DEMO_VOICES; v++) { voiceAz[v] = NAN; voiceOmni[v] = NAN; }

    const uint32_t fadeTarget = atomic_load_explicit(&s->muted, memory_order_relaxed) ? 0 : s->fadeLength;
    const int toneReq = atomic_load_explicit(&s->toneSpeaker, memory_order_relaxed);
    const int clickOn = atomic_load_explicit(&s->clickOn, memory_order_relaxed);
    const uint32_t tfull = s->toneFadeLength;
    float peak[NSPK] = { 0 };
    for (uint32_t f = 0; f < frames; f++) {
        if (s->fadePosition < fadeTarget) s->fadePosition++;
        else if (s->fadePosition > fadeTarget) s->fadePosition--;
        const float fade = s->fadePosition == s->fadeLength ? 1.0f : (float)s->fadePosition / (float)s->fadeLength;

        float L, R;
        if (tapSet != NULL) tapmix_read(&s->taps, tapSet, f, &L, &R);
        else { L = read_in(&inL, f); R = read_in(&inR, f); }
        float rl, rr;
        domine_spatial_tick(s->spatial, L, R, &rl, &rr); // always, so its state stays warm
        if (level != 1.0f) { rl *= level; rr *= level; }
        const float src[NPROG] = { L, R, rl, rr };

        // Demo voices and the program/demo crossfade.
        float demoMix[NSPK];
        const int demoActive = s->demoPlaying || s->demoPos > 0;
        if (demoActive) {
            const uint32_t target = s->demoPlaying ? s->fadeLength : 0;
            if (s->demoPos < target) s->demoPos++;
            else if (s->demoPos > target) s->demoPos--;
            DomineDemoVoice voices[DOMINE_DEMO_VOICES];
            const int section = domine_demo_tick(&s->demo, voices);
            if (s->demoPlaying) {
                s->demoSection = section;
                if (section == DOMINE_DEMO_SECTION_FINISHED) s->demoPlaying = 0;
            }
            for (uint32_t k = 0; k < n; k++) demoMix[k] = 0.0f;
            for (int v = 0; v < DOMINE_DEMO_VOICES; v++) {
                if (voices[v].sample == 0.0f) continue;
                if (voices[v].azimuth != voiceAz[v] || voices[v].omni != voiceOmni[v]) {
                    voiceAz[v] = voices[v].azimuth;
                    voiceOmni[v] = voices[v].omni;
                    demo_voice_gains(&pan, present, nPresent, &voices[v], voiceGain[v]);
                }
                for (uint32_t k = 0; k < n; k++) demoMix[k] += voiceGain[v][k] * voices[v].sample;
            }
        }
        const float demoAmt = (float)s->demoPos / (float)s->fadeLength;
        const float progAmt = s->demoPos == 0 ? 1.0f : (float)(s->fadeLength - s->demoPos) / (float)s->fadeLength;
        const int last = f + 1 == frames;

        // Click test (kernel.c click_mix): replaces the source before gain
        // and delay on every speaker, on the same sample.
        const int clickActive = clickOn || s->clickLevel != 0;
        float click = 0.0f, clickKeep = 1.0f;
        if (clickActive) {
            if (clickOn && s->clickLevel == tfull) {
                const uint32_t c = s->clickCounter;
                if (c < s->clickLength) {
                    const double window = 0.5 - 0.5 * cos(2.0 * M_PI * (double)c / (double)s->clickLength);
                    click = (float)(DOMINE_CLICK_AMPLITUDE * window
                                    * sin(2.0 * M_PI * DOMINE_CLICK_HZ * (double)c / s->sampleRate));
                }
                s->clickCounter = c + 1 < s->clickPeriod ? c + 1 : 0;
            } else {
                s->clickCounter = 0;
            }
            clickKeep = s->clickLevel == tfull ? 0.0f : 1.0f - (float)s->clickLevel / (float)tfull;
            const uint32_t target = clickOn ? tfull : 0;
            if (s->clickLevel < target) s->clickLevel++;
            else if (s->clickLevel > target) s->clickLevel--;
        }

        // Test tone (kernel.c): a new request takes over once the current
        // tone has faded out. Replaces the output after gain and delay.
        if (s->toneLevel == 0 && s->playingTone != toneReq) {
            s->playingTone = toneReq;
            s->tonePhase = 0.0;
        }
        const int toneActive = s->playingTone >= 0;
        float tone = 0.0f, toneE = 0.0f, toneKeep = 1.0f;
        int toneFull = 0;
        if (toneActive) {
            tone = (float)domine_chime_sample(s->tonePhase);
            s->tonePhase += s->tonePhaseStep;
            if (s->tonePhase >= DOMINE_CHIME_PERIOD_S) s->tonePhase -= DOMINE_CHIME_PERIOD_S;
            const uint32_t target = toneReq == s->playingTone ? tfull : 0;
            toneFull = s->toneLevel == tfull && target == tfull;
            toneE = (float)s->toneLevel / (float)tfull;
            toneKeep = 1.0f - toneE;
            if (s->toneLevel < target) s->toneLevel++;
            else if (s->toneLevel > target) s->toneLevel--;
        }

        for (uint32_t k = 0; k < n; k++) {
            float x = 0.0f;
            for (int j = 0; j < loopSrc; j++) {
                const float g = !ramping || last ? gT[j][k] : s->gPrev[j][k] + gStep[j][k] * (float)(f + 1);
                x = j == 0 ? g * src[0] : x + g * src[j];
            }
            if (demoActive) {
                if (progAmt != 1.0f) x *= progAmt;
                x += demoAmt * demoMix[k];
            }
            if (!domine_eq_is_idle(s->eq[k])) domine_eq_process(s->eq[k], &x, 1);
            if (!domine_bass_is_idle(s->bass[k])) domine_bass_process(s->bass[k], &x, 1);
            if (!domine_compressor_is_idle(s->comp[k])) domine_compressor_process(s->comp[k], &x, 1);
            if (clickActive) x = clickKeep == 0.0f ? click : x * clickKeep + click;

            GainState *g = &s->gain[k];
            if (g->i < g->len) {
                g->i++;
                g->applied = g->i == g->len ? g->target
                    : g->start + (g->target - g->start) * (float)g->i / (float)g->len;
            }
            if (g->applied != 1.0f) x *= g->applied;

            s->ring[k][s->ringPos & s->ringMask] = x;
            float o = delay[k] > 0 ? s->ring[k][(s->ringPos - delay[k]) & s->ringMask] : x;
            if (toneActive) {
                const int mine = (int)k == s->playingTone;
                if (toneFull) o = mine ? tone : 0.0f;
                else o = mine ? tone * toneE + o * toneKeep : o * toneKeep;
            }
            if (fade != 1.0f) o *= fade;
            if (present[k]) {
                const float a = fabsf(o);
                if (a > peak[k]) peak[k] = a;
                for (int c = 0; c < 2; c++) {
                    const OutCh *ch = &oc[k][c];
                    if (ch->data != NULL && f < ch->frames) ch->data[(size_t)f * ch->stride] = o;
                }
            }
        }
        s->ringPos++;
    }
    memcpy(s->gPrev, gT, sizeof gT);
    for (uint32_t k = 0; k < NSPK; k++)
        atomic_store_explicit(&s->peakBits[k], f2u(k < n ? peak[k] : 0.0f), memory_order_relaxed);

    const int showDemo = s->demoPlaying;
    atomic_store_explicit(&s->demoSectionPub, s->demoSection, memory_order_relaxed);
    atomic_store_explicit(&s->demoSecondsBits, f2u(showDemo ? (float)domine_demo_seconds(&s->demo) : 0.0f),
                          memory_order_relaxed);
    if (showDemo)
        atomic_store_explicit(&s->demoAzBits, f2u(domine_demo_focus_azimuth(&s->demo)), memory_order_relaxed);
    atomic_store_explicit(&s->demoPlayingPub, showDemo, memory_order_relaxed);
}

// Same input rules as the quad kernel: first buffer with 2+ channels is
// interleaved stereo; else two buffers (unless the format says mono) are
// deinterleaved stereo; else mono feeds both sides.
static void surround_resolve(const AudioBuffer *buffers, uint32_t count, uint32_t formatChannels,
                             InCh *l, InCh *r) {
    const InCh none = { NULL, 1, 0 };
    *l = none; *r = none;
    if (buffers == NULL || count == 0) return;
    const AudioBuffer *b0 = &buffers[0];
    if (b0->mNumberChannels >= 2) { *l = in_channel(b0, 0); *r = in_channel(b0, 1); }
    else if (count >= 2 && formatChannels != 1) { *l = in_channel(b0, 0); *r = in_channel(&buffers[1], 0); }
    else { *l = in_channel(b0, 0); *r = *l; }
}

void domine_surround_process(DomineSurround *s, const AudioBufferList *in, AudioBufferList *out,
                             uint32_t frames, const uint32_t *out_offsets) {
    if (s == NULL || out == NULL || out_offsets == NULL) return;
    pickup_speakers(s);
    InCh inL, inR;
    TapSet tapSet;
    const int useTaps = tapmix_begin(&s->taps);
    if (useTaps) {
        (void)tapmix_resolve(&s->taps, in, &tapSet, NULL);
        inL = inR = (InCh){ NULL, 1, 0 };
    } else {
        surround_resolve(in != NULL ? in->mBuffers : NULL, in != NULL ? in->mNumberBuffers : 0, 0, &inL, &inR);
    }
    surround_render(s, inL, inR, useTaps ? &tapSet : NULL, out, frames, out_offsets, s->rcount);
}

void domine_surround_set_layout(DomineSurround *s, uint32_t inFirstBuffer, uint32_t count, const uint32_t *out_offsets) {
    if (s == NULL) return;
    if (count > NSPK) count = NSPK;
    atomic_store_explicit(&s->layoutFirst, inFirstBuffer, memory_order_relaxed);
    for (uint32_t i = 0; i < NSPK; i++) {
        const uint32_t off = i < count && out_offsets != NULL ? out_offsets[i] : DOMINE_NO_DEVICE;
        atomic_store_explicit(&s->layoutOut[i], off, memory_order_relaxed);
    }
    atomic_store_explicit(&s->layoutCount, count, memory_order_relaxed);
}

void domine_surround_set_tap_layout(DomineSurround *s, uint32_t tapCount, const uint32_t *firstBuffer,
                                    const uint32_t *channels, const uint32_t *interleaved) {
    if (s == NULL) return;
    tapmix_set_layout(&s->taps, tapCount, firstBuffer, channels, interleaved);
}

void domine_surround_set_tap_gain(DomineSurround *s, uint32_t tap, float gain) {
    if (s == NULL) return;
    tapmix_set_gain(&s->taps, tap, gain);
}

void domine_surround_set_input_format(DomineSurround *s, uint32_t channelsPerFrame, int nonInterleaved) {
    if (s == NULL) return;
    atomic_store_explicit(&s->inputChannels, channelsPerFrame, memory_order_relaxed);
    atomic_store_explicit(&s->inputNonInterleaved, nonInterleaved ? 1 : 0, memory_order_relaxed);
}

OSStatus domine_surround_ioproc(AudioObjectID inDevice, const AudioTimeStamp *inNow,
                                const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime,
                                AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime,
                                void *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputTime; (void)inOutputTime;
    DomineSurround *s = (DomineSurround *)inClientData;
    if (s == NULL || outOutputData == NULL) return 0;
    pickup_speakers(s);
    const uint32_t first = atomic_load_explicit(&s->layoutFirst, memory_order_relaxed);
    const uint32_t fmt = atomic_load_explicit(&s->inputChannels, memory_order_relaxed);
    uint32_t count = atomic_load_explicit(&s->layoutCount, memory_order_relaxed);
    if (count > NSPK) count = NSPK;
    uint32_t offsets[NSPK];
    for (uint32_t i = 0; i < NSPK; i++) offsets[i] = atomic_load_explicit(&s->layoutOut[i], memory_order_relaxed);

    uint32_t frames = 0;
    for (uint32_t b = 0; b < outOutputData->mNumberBuffers; b++) {
        const AudioBuffer *buf = &outOutputData->mBuffers[b];
        if (buf->mNumberChannels == 0) continue;
        const uint32_t nf = buf->mDataByteSize / (uint32_t)(sizeof(float) * buf->mNumberChannels);
        if (nf > frames) frames = nf;
    }
    const AudioBuffer *inBuffers = NULL;
    uint32_t inCount = 0;
    if (inInputData != NULL && first < inInputData->mNumberBuffers) {
        inBuffers = inInputData->mBuffers + first;
        inCount = inInputData->mNumberBuffers - first;
    }
    InCh inL, inR;
    TapSet tapSet;
    const int useTaps = tapmix_begin(&s->taps);
    if (useTaps) {
        (void)tapmix_resolve(&s->taps, inInputData, &tapSet, NULL);
        inL = inR = (InCh){ NULL, 1, 0 };
    } else {
        surround_resolve(inBuffers, inCount, fmt, &inL, &inR);
    }
    surround_render(s, inL, inR, useTaps ? &tapSet : NULL, outOutputData, frames, offsets, count);
    return 0;
}
