// Tests for the showcase demo generator (DomineDemo.h).
#include "DomineDemo.h"
#include "check.h"
#include <stdint.h>
#include <string.h>

#define SR 48000.0
#define MAXHITS 256

typedef struct {
    uint64_t frame[MAXHITS];
    float az[MAXHITS];
    float omni[MAXHITS];
    float gain[MAXHITS];
    int section[MAXHITS];
    int count;
} Hits;

static uint64_t at(double s) { return (uint64_t)llround(s * SR); }

// 1 if the tick that rendered frame f started a kick.
static int onset(const DomineDemo *d, uint64_t f) {
    const int k = d->lastKick;
    return d->kickActive[k] && d->kickStart[k] == f;
}

// Runs the whole demo and records every kick onset.
static void run(uint32_t n, const float *az, Hits *h, DomineDemo *d) {
    memset(h, 0, sizeof *h);
    domine_demo_reset(d, SR, n, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    const uint64_t end = at(domine_demo_length(d));
    for (uint64_t f = 0; f < end; f++) {
        int sec = domine_demo_tick(d, v);
        if (onset(d, f) && h->count < MAXHITS) {
            const int k = d->lastKick;
            h->frame[h->count] = f;
            h->az[h->count] = d->kickAz[k];
            h->omni[h->count] = d->kickOmni[k];
            h->gain[h->count] = d->kickGain[k];
            h->section[h->count] = sec;
            h->count++;
        }
    }
}

static int count_section(const Hits *h, int sec, int *first) {
    int c = 0;
    *first = -1;
    for (int i = 0; i < h->count; i++)
        if (h->section[i] == sec) { if (*first < 0) *first = i; c++; }
    return c;
}

static void test_lengths(void) {
    static const struct { uint32_t n; double len; } t[] = {
        { 1, 47 }, { 2, 47 }, { 3, 47 }, { 4, 47 }, { 5, 49 }, { 6, 49 }, { 7, 51 }, { 8, 51 },
        { 9, 47 }, { 12, 47 }, { 16, 47 },
    };
    float az[16];
    for (int i = 0; i < 16; i++) az[i] = -180.0f + 22.5f * (float)i;
    for (size_t i = 0; i < sizeof t / sizeof t[0]; i++) {
        DomineDemo d;
        domine_demo_reset(&d, SR, t[i].n, az);
        CHECK_NEAR(domine_demo_length(&d), t[i].len, 1e-12);
        CHECK(domine_demo_length(&d) <= DOMINE_DEMO_LENGTH_S);
    }
}

static void test_section_boundaries(double sr) {
    static const struct { double x; int sec; } b[] = {
        { 0.0, DOMINE_DEMO_SECTION_PING_PONG }, { 6.0, DOMINE_DEMO_SECTION_SWEEP },
        { 12.0, DOMINE_DEMO_SECTION_ORBIT }, { 22.0, DOMINE_DEMO_SECTION_SWELL },
        { 32.0, DOMINE_DEMO_SECTION_SILENCE }, { 33.0, DOMINE_DEMO_SECTION_DROP },
        { 41.0, DOMINE_DEMO_SECTION_FINISHED },
    };
    enum { NB = sizeof b / sizeof b[0] };
    DomineDemo d;
    float az[2] = { -30.0f, 30.0f };
    domine_demo_reset(&d, sr, 2, az);
    const double r = domine_demo_length(&d) - 41.0;
    CHECK_NEAR(r, 6.0, 1e-12);
    CHECK(d.section == DOMINE_DEMO_SECTION_ROLL_CALL);
    CHECK(domine_demo_seconds(&d) == 0.0);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    int prev = DOMINE_DEMO_SECTION_ROLL_CALL, bi = 0;
    for (uint64_t f = 0; f < (uint64_t)llround(47.0 * sr) + 100; f++) {
        int sec = domine_demo_tick(&d, v);
        if (f == 0) CHECK(sec == DOMINE_DEMO_SECTION_ROLL_CALL);
        if (sec != prev) {
            CHECK(bi < NB);
            if (bi < NB) {
                CHECK(sec == b[bi].sec);
                CHECK(f == (uint64_t)llround((r + b[bi].x) * sr));
            }
            bi++;
            prev = sec;
        }
    }
    CHECK(bi == NB);
    CHECK_NEAR(domine_demo_seconds(&d), 47.0, 1e-9);
}

// Roll call: exactly one hit per speaker per round, in clockwise order from
// hard left, on the grid after the 2 s lead-in.
static void test_roll_call(uint32_t n, const float *az, const float *expected) {
    static Hits h;
    DomineDemo d;
    run(n, az, &h, &d);
    const double r = domine_demo_length(&d) - 41.0;
    int first;
    int c = count_section(&h, DOMINE_DEMO_SECTION_ROLL_CALL, &first);
    CHECK(first == 0);
    if (n <= 2) {
        CHECK(c == 8);
        for (int i = 0; i < c; i++) {
            const int slot = i / 2;
            CHECK(h.az[i] == expected[(uint32_t)slot % n]);
            CHECK(h.frame[i] == at(2.0 + slot + (i & 1) * 0.25));
            if (i & 1) CHECK(h.gain[i] > h.gain[i - 1]);
        }
    } else {
        const int rounds = n <= 8 ? 2 : 1;
        const double step = n <= 8 ? 0.5 : 0.25;
        CHECK(c == (int)n * rounds);
        for (int i = 0; i < c && i < MAXHITS; i++) {
            CHECK(h.az[i] == expected[(uint32_t)i % n]);
            CHECK(h.frame[i] == at(2.0 + i * step));
        }
    }
    for (int i = 0; i < c; i++) {
        CHECK(h.omni[i] == 0.0f);
        CHECK(h.frame[i] < at(r));
    }
}

static void test_roll_calls(void) {
    float two[2] = { 30.0f, -30.0f }, twoE[2] = { -30.0f, 30.0f };
    test_roll_call(2, two, twoE);
    float four[4] = { 45.0f, -45.0f, 135.0f, -135.0f }, fourE[4] = { -45.0f, 45.0f, 135.0f, -135.0f };
    test_roll_call(4, four, fourE);
    float five[5] = { 0.0f, 110.0f, -30.0f, -90.0f, 30.0f }, fiveE[5] = { -90.0f, -30.0f, 0.0f, 30.0f, 110.0f };
    test_roll_call(5, five, fiveE);
    float s8[8], e8[8];
    for (int i = 0; i < 8; i++) s8[i] = -135.0f + 45.0f * (float)i;
    for (int i = 0; i < 8; i++) { float a = -90.0f + 45.0f * (float)i; e8[i] = a > 180.0f ? a - 360.0f : a; }
    test_roll_call(8, s8, e8);
    float s9[9];
    for (int i = 0; i < 9; i++) s9[i] = 40.0f * (float)i - 160.0f;  // -160 ... 160
    float e9[9] = { -80.0f, -40.0f, 0.0f, 40.0f, 80.0f, 120.0f, 160.0f, -160.0f, -120.0f };
    test_roll_call(9, s9, e9);
    float s16[16], e16[16];
    for (int i = 0; i < 16; i++) s16[i] = 180.0f - 22.5f * (float)i;
    for (int i = 0; i < 16; i++) { float a = -90.0f + 22.5f * (float)i; e16[i] = a > 180.0f ? a - 360.0f : a; }
    test_roll_call(16, s16, e16);
    // Count 0 is one speaker at 0: double hits on it.
    static Hits h;
    DomineDemo d;
    run(0, NULL, &h, &d);
    int first;
    CHECK(count_section(&h, DOMINE_DEMO_SECTION_ROLL_CALL, &first) == 8);
    CHECK(h.az[0] == 0.0f && h.az[7] == 0.0f);
}

static void test_ping_pong(void) {
    static Hits h;
    DomineDemo d;
    float az[2] = { -30.0f, 30.0f };
    run(2, az, &h, &d);
    int first;
    int c = count_section(&h, DOMINE_DEMO_SECTION_PING_PONG, &first);
    CHECK(c == 24);
    if (first < 0) return;
    CHECK(h.frame[first] == at(6.0));
    double prevGap = 1e9;
    for (int i = 0; i < c; i++) {
        CHECK(h.az[first + i] == ((i & 1) ? 90.0f : -90.0f));
        if (i > 0) {
            double gap = (double)(h.frame[first + i] - h.frame[first + i - 1]) / SR;
            CHECK(gap <= prevGap + 1e-9);
            prevGap = gap;
        }
    }
    CHECK_NEAR((double)(h.frame[first + 1] - h.frame[first]) / SR, 0.5, 1e-9);
    CHECK_NEAR(prevGap, 0.125, 1e-9);
}

static void test_sweep(void) {
    DomineDemo d;
    float az[2] = { -30.0f, 30.0f };
    domine_demo_reset(&d, SR, 2, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    double unwrapped = 0.0, prevAz = 0.0;
    double prevPhase = 0.0;
    int started = 0, bendUp = 0, bendDown = 0;
    for (uint64_t f = 0; f < at(18.0); f++) {
        const int sec = domine_demo_tick(&d, v);
        if (sec != DOMINE_DEMO_SECTION_SWEEP) { prevPhase = d.sweepPhase; continue; }
        if (!started) {
            CHECK(f == at(12.0));
            CHECK(v[7].azimuth == -90.0f);
            started = 1;
        } else {
            double step = (double)v[7].azimuth - prevAz;
            if (step < -180.0) step += 360.0;
            CHECK(step >= 0.0);
            unwrapped += step;
        }
        prevAz = v[7].azimuth;
        CHECK(domine_demo_focus_azimuth(&d) == v[7].azimuth);
        // Doppler in the first pass (12 to 14 s, base 220 Hz rising): above
        // the base at a quarter of the pass, below it at three quarters.
        double inc = d.sweepPhase - prevPhase;
        if (inc < 0.0) inc += 1.0;
        const double hz = inc * SR;
        const double base = 220.0 * pow(2.0, ((double)f / SR - 12.0) / 2.0 / 6.0);
        if (f == at(12.5)) bendUp = hz > base * 1.04;
        if (f == at(13.5)) bendDown = hz < base * 0.96;
        prevPhase = d.sweepPhase;
    }
    CHECK(bendUp);
    CHECK(bendDown);
    CHECK_NEAR(unwrapped, 1080.0, 0.5);
}

static void test_orbit(void) {
    DomineDemo d;
    float az[4] = { -45.0f, 45.0f, 135.0f, -135.0f };
    domine_demo_reset(&d, SR, 4, az);
    const double r = domine_demo_length(&d) - 41.0;
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    double unwrapped = 0.0, prevAz = 0.0;
    int started = 0, kicks = 0;
    for (uint64_t f = 0; f < at(r + 22.0); f++) {
        int sec = domine_demo_tick(&d, v);
        if (sec != DOMINE_DEMO_SECTION_ORBIT) {
            if (f < at(r + 12.0)) CHECK(v[2].sample == 0.0f);
            continue;
        }
        if (!started) {
            CHECK(f == at(r + 12.0));
            CHECK(v[2].azimuth == 90.0f);
            started = 1;
        } else {
            double step = (double)v[2].azimuth - prevAz;
            if (step < -180.0) step += 360.0;
            CHECK(step > 0.0);
            unwrapped += step;
        }
        prevAz = v[2].azimuth;
        if (onset(&d, f)) {
            CHECK(f == at(r + 12.0 + kicks));
            CHECK(d.kickAz[d.lastKick] == v[2].azimuth);
            kicks++;
        }
        CHECK(v[2].omni == 0.0f);
        if (f == at(r + 13.0)) CHECK(fabsf(v[2].sample) > 0.0f);
    }
    CHECK(kicks == 10);
    // 0.25 to 0.6 turns/s over 10 s is 4.25 turns.
    CHECK_NEAR(unwrapped / 360.0, 4.25, 0.01);
}

static void test_swell_silence_impact(void) {
    DomineDemo d;
    float az[2] = { -30.0f, 30.0f };
    domine_demo_reset(&d, SR, 2, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    int impactHits = 0, silentOk = 1, finishedOk = 1;
    float subEarly = 0.0f, subLate = 0.0f, chordEarly = 0.0f, chordLate = 0.0f;
    for (uint64_t f = 0; f < at(47.0) + 1000; f++) {
        int sec = domine_demo_tick(&d, v);
        const double t = (double)f / SR;
        if (sec == DOMINE_DEMO_SECTION_SWELL) {
            CHECK(v[0].sample == 0.0f && v[1].sample == 0.0f);
            if (t < 30.0) { subEarly = fmaxf(subEarly, fabsf(v[3].sample)); chordEarly = fmaxf(chordEarly, fabsf(v[4].sample)); }
            if (t > 36.5 && t < 37.9) { subLate = fmaxf(subLate, fabsf(v[3].sample)); chordLate = fmaxf(chordLate, fabsf(v[4].sample)); }
            if (f == at(28.0)) CHECK(v[4].azimuth == 0.0f && v[5].azimuth == 0.0f);
            if (f == at(37.9)) CHECK(v[4].azimuth < -89.0f && v[5].azimuth > 89.0f);
        }
        if (sec == DOMINE_DEMO_SECTION_SILENCE)
            for (int i = 0; i < DOMINE_DEMO_VOICES; i++) silentOk &= v[i].sample == 0.0f;
        if (sec == DOMINE_DEMO_SECTION_DROP && onset(&d, f)) {
            impactHits++;
            CHECK(f == at(39.0));
            CHECK(d.kickOmni[d.lastKick] == 1.0f);
            CHECK(domine_demo_focus_azimuth(&d) == 0.0f);
        }
        if (f == at(39.0) + 100) {
            CHECK(v[3].omni == 1.0f && v[7].omni == 1.0f);
            CHECK(fabsf(v[3].sample) > 0.0f && fabsf(v[7].sample) > 0.0f && fabsf(v[4].sample) > 0.0f);
        }
        if (f == at(47.0) - 1)
            for (int i = 0; i < DOMINE_DEMO_VOICES; i++) CHECK(fabsf(v[i].sample) < 1e-3f);
        if (f >= at(47.0)) {
            finishedOk &= sec == DOMINE_DEMO_SECTION_FINISHED;
            for (int i = 0; i < DOMINE_DEMO_VOICES; i++) finishedOk &= v[i].sample == 0.0f;
        }
    }
    CHECK(silentOk);
    CHECK(finishedOk);
    CHECK(impactHits == 1);
    CHECK(subLate > 4.0f * subEarly && subLate > 0.15f);
    CHECK(chordLate > 2.0f * chordEarly && chordLate > 0.2f);
    CHECK_NEAR(domine_demo_seconds(&d), 47.0, 1e-9);
}

static void test_levels_and_finite(uint32_t n, const float *az, double sr) {
    DomineDemo d;
    domine_demo_reset(&d, sr, n, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    float peak[DOMINE_DEMO_VOICES] = { 0 }, sumPeak = 0.0f;
    int bad = 0;
    const uint64_t end = (uint64_t)llround(domine_demo_length(&d) * sr);
    for (uint64_t f = 0; f < end; f++) {
        domine_demo_tick(&d, v);
        float sum = 0.0f;
        for (int i = 0; i < DOMINE_DEMO_VOICES; i++) {
            if (!isfinite(v[i].sample) || !isfinite(v[i].azimuth) || !isfinite(v[i].omni)) bad++;
            if (v[i].omni < 0.0f || v[i].omni > 1.0f) bad++;
            float a = fabsf(v[i].sample);
            if (a > peak[i]) peak[i] = a;
            sum += a;
        }
        if (sum > sumPeak) sumPeak = sum;
    }
    CHECK(bad == 0);
    for (int i = 0; i < DOMINE_DEMO_VOICES; i++) {
        CHECK(peak[i] <= 0.8f);
        CHECK(peak[i] > 0.02f);
    }
    CHECK(peak[0] > 0.5f);
    CHECK(sumPeak <= 1.0f);
}

static void test_levels(void) {
    float two[2] = { -30.0f, 30.0f };
    test_levels_and_finite(2, two, 48000.0);
    test_levels_and_finite(2, two, 44100.0);
    test_levels_and_finite(2, two, 8000.0);
    float s16[16];
    for (int i = 0; i < 16; i++) s16[i] = -180.0f + 22.5f * (float)i;
    test_levels_and_finite(16, s16, 96000.0);
}

static void test_determinism(void) {
    static DomineDemoVoice a[2][DOMINE_DEMO_VOICES];
    float az[2] = { -30.0f, 30.0f };
    DomineDemo d1, d2;
    domine_demo_reset(&d1, SR, 2, az);
    // Run d2 partway with another setup, then reset: it must match a fresh run.
    domine_demo_reset(&d2, 44100.0, 1, az);
    for (int i = 0; i < 100000; i++) domine_demo_tick(&d2, a[1]);
    domine_demo_reset(&d2, SR, 2, az);
    int diff = 0;
    for (uint64_t f = 0; f < at(47.0); f++) {
        int s1 = domine_demo_tick(&d1, a[0]);
        int s2 = domine_demo_tick(&d2, a[1]);
        if (s1 != s2) diff++;
        for (int i = 0; i < DOMINE_DEMO_VOICES; i++)
            if (memcmp(&a[0][i], &a[1][i], sizeof a[0][i]) != 0) diff++;
    }
    CHECK(diff == 0);
}

static void test_odd_inputs(void) {
    DomineDemo d;
    float az[20];
    for (int i = 0; i < 20; i++) az[i] = (float)i * 10.0f;
    domine_demo_reset(&d, SR, 20, az);
    CHECK(d.speakerCount == 16);
    CHECK(d.rollCallHits == 16);
    domine_demo_reset(&d, 0.0, 2, az);
    CHECK(d.sampleRate == 48000.0);
    float w[2] = { 270.0f, -450.0f };  // keys 0 and 0: stable order
    domine_demo_reset(&d, SR, 2, w);
    CHECK(d.order[0] == 270.0f && d.order[1] == -450.0f);
}

int main(void) {
    test_lengths();
    test_section_boundaries(48000.0);
    test_section_boundaries(44100.0);
    test_roll_calls();
    test_ping_pong();
    test_sweep();
    test_orbit();
    test_swell_silence_impact();
    test_levels();
    test_determinism();
    test_odd_inputs();
    CHECK_DONE();
}
