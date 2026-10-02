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
    int section[MAXHITS];
    int count;
} Hits;

static uint64_t at(double s) { return (uint64_t)llround(s * SR); }

// Runs the whole demo and records every kick onset.
static void run(uint32_t n, const float *az, Hits *h, DomineDemo *d) {
    memset(h, 0, sizeof *h);
    domine_demo_reset(d, SR, n, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    for (uint64_t f = 0; f < at(32.0); f++) {
        int sec = domine_demo_tick(d, v);
        int k = d->lastKick;
        if (d->kickActive[k] && d->kickStart[k] == f && h->count < MAXHITS) {
            h->frame[h->count] = f;
            h->az[h->count] = d->kickAz[k];
            h->omni[h->count] = d->kickOmni[k];
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

static void test_section_boundaries(double sr) {
    static const struct { double s; int sec; } b[] = {
        { 8.0, DOMINE_DEMO_SECTION_PING_PONG }, { 14.0, DOMINE_DEMO_SECTION_ORBIT },
        { 26.0, DOMINE_DEMO_SECTION_SWELL }, { 30.0, DOMINE_DEMO_SECTION_DROP },
        { 32.0, DOMINE_DEMO_SECTION_FINISHED },
    };
    DomineDemo d;
    float az[2] = { -90.0f, 90.0f };
    domine_demo_reset(&d, sr, 2, az);
    CHECK(d.section == DOMINE_DEMO_SECTION_ROLL_CALL);
    CHECK(domine_demo_seconds(&d) == 0.0);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    int prev = DOMINE_DEMO_SECTION_ROLL_CALL, bi = 0;
    for (uint64_t f = 0; f < (uint64_t)llround(32.0 * sr) + 100; f++) {
        int sec = domine_demo_tick(&d, v);
        if (f == 0) CHECK(sec == DOMINE_DEMO_SECTION_ROLL_CALL);
        if (sec != prev) {
            CHECK(bi < 5);
            if (bi < 5) {
                CHECK(sec == b[bi].sec);
                CHECK(f == (uint64_t)llround(b[bi].s * sr));
            }
            bi++;
            prev = sec;
        }
    }
    CHECK(bi == 5);
    CHECK_NEAR(domine_demo_seconds(&d), 32.0, 1e-9);
}

static void test_roll_call(uint32_t n, const float *az, const float *expected) {
    static Hits h;
    DomineDemo d;
    run(n, az, &h, &d);
    int first;
    int c = count_section(&h, DOMINE_DEMO_SECTION_ROLL_CALL, &first);
    uint32_t rounds = n <= 8 ? 2 : 1;
    CHECK(c == (int)(n * rounds));
    CHECK(first == 0);
    for (int i = 0; i < c && i < MAXHITS; i++) {
        CHECK(h.az[i] == expected[(uint32_t)i % n]);
        CHECK(h.omni[i] == 0.0f);
        CHECK(h.frame[i] == (uint64_t)llround(i * 8.0 * SR / c));
    }
}

static void test_roll_calls(void) {
    float two[2] = { 90.0f, -90.0f }, twoE[2] = { -90.0f, 90.0f };
    test_roll_call(2, two, twoE);
    float four[4] = { 45.0f, -45.0f, 135.0f, -135.0f }, fourE[4] = { -45.0f, 45.0f, 135.0f, -135.0f };
    test_roll_call(4, four, fourE);
    // 5.0-ish layout, unsorted, with a speaker exactly at hard left.
    float five[5] = { 0.0f, 110.0f, -30.0f, -90.0f, 30.0f }, fiveE[5] = { -90.0f, -30.0f, 0.0f, 30.0f, 110.0f };
    test_roll_call(5, five, fiveE);
    // 16 speakers every 22.5 degrees, given in reverse.
    float s16[16], e16[16];
    for (int i = 0; i < 16; i++) s16[i] = 180.0f - 22.5f * (float)i;  // 180 ... -157.5
    for (int i = 0; i < 16; i++) {
        float a = -90.0f + 22.5f * (float)i;                           // -90 clockwise
        e16[i] = a > 180.0f ? a - 360.0f : a;
    }
    test_roll_call(16, s16, e16);
    // 8 speakers get two rounds, 9 get one.
    float s8[8], e8[8], s9[9], e9[9];
    for (int i = 0; i < 8; i++) { s8[i] = -135.0f + 45.0f * (float)i; }
    for (int i = 0; i < 8; i++) { float a = -90.0f + 45.0f * (float)i; e8[i] = a > 180.0f ? a - 360.0f : a; }
    test_roll_call(8, s8, e8);
    for (int i = 0; i < 9; i++) { s9[i] = 40.0f * (float)i - 160.0f; }  // -160 ... 160
    static const float e9c[9] = { -80.0f, -40.0f, 0.0f, 40.0f, 80.0f, 120.0f, 160.0f, -160.0f, -120.0f };
    for (int i = 0; i < 9; i++) e9[i] = e9c[i];
    test_roll_call(9, s9, e9);
    // Count 0 is one speaker at 0: two hits.
    static Hits h;
    DomineDemo d;
    run(0, NULL, &h, &d);
    int first;
    CHECK(count_section(&h, DOMINE_DEMO_SECTION_ROLL_CALL, &first) == 2);
    CHECK(h.az[0] == 0.0f && h.az[1] == 0.0f);
}

static void test_ping_pong(void) {
    static Hits h;
    DomineDemo d;
    float az[2] = { -90.0f, 90.0f };
    run(2, az, &h, &d);
    int first;
    int c = count_section(&h, DOMINE_DEMO_SECTION_PING_PONG, &first);
    CHECK(c >= 15);
    CHECK(first >= 0);
    if (first < 0) return;
    CHECK(h.frame[first] == at(8.0));
    double prevGap = 1e9;
    for (int i = 0; i < c; i++) {
        CHECK(h.az[first + i] == ((i & 1) ? 90.0f : -90.0f));
        if (i > 0) {
            double gap = (double)(h.frame[first + i] - h.frame[first + i - 1]) / SR;
            if (i == 1) CHECK_NEAR(gap, 0.5, 1e-4);
            CHECK(gap < prevGap);
            CHECK(gap >= 0.15 - 1e-4);
            prevGap = gap;
        }
    }
    CHECK(prevGap < 0.2);
    CHECK(h.frame[first + c - 1] < at(14.0));
}

static void test_orbit(void) {
    DomineDemo d;
    float az[4] = { -45.0f, 45.0f, 135.0f, -135.0f };
    domine_demo_reset(&d, SR, 4, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    double unwrapped = 0.0, prevAz = 0.0;
    int started = 0, orbitKicks = 0;
    for (uint64_t f = 0; f < at(29.5); f++) {
        int sec = domine_demo_tick(&d, v);
        if (sec == DOMINE_DEMO_SECTION_ROLL_CALL || sec == DOMINE_DEMO_SECTION_PING_PONG) {
            CHECK(v[2].sample == 0.0f);
            continue;
        }
        if (!started) {
            CHECK(f == at(14.0));
            CHECK(v[2].azimuth == 0.0f);
            CHECK(domine_demo_focus_azimuth(&d) == 0.0f);
            started = 1;
            prevAz = v[2].azimuth;
        } else {
            double step = (double)v[2].azimuth - prevAz;
            if (step < -180.0) step += 360.0;
            CHECK(step > 0.0);
            unwrapped += step;
            prevAz = v[2].azimuth;
        }
        int k = d.lastKick;
        if (sec == DOMINE_DEMO_SECTION_ORBIT && d.kickActive[k] && d.kickStart[k] == f) {
            CHECK(f == at(14.0 + 0.5 * orbitKicks));
            CHECK(d.kickAz[k] == v[2].azimuth);
            orbitKicks++;
        }
        if (sec == DOMINE_DEMO_SECTION_ORBIT) CHECK(v[2].omni == 0.0f);
        if (f == at(14.0) + 2400) CHECK(fabsf(v[2].sample) > 0.0f);
    }
    CHECK(orbitKicks == 24);
    // 0.2 to 0.8 turns/s over 12 s is 6 turns, then 0.8 turns/s for 3.5 s.
    CHECK_NEAR(unwrapped / 360.0, 6.0 + 2.8, 0.01);
    CHECK_NEAR(v[2].omni, 1.0, 1e-3);
}

static void test_drop_and_finish(void) {
    DomineDemo d;
    float az[5] = { -110.0f, -30.0f, 0.0f, 30.0f, 110.0f };
    domine_demo_reset(&d, SR, 5, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    int dropHits = 0;
    float dropPeak = 0.0f;
    for (uint64_t f = 0; f < at(32.0) + 1000; f++) {
        int sec = domine_demo_tick(&d, v);
        if (f >= at(29.5) + at(0.03) && f < at(30.0)) {
            for (int i = 0; i < DOMINE_DEMO_VOICES; i++) CHECK(v[i].sample == 0.0f);
        }
        if (sec == DOMINE_DEMO_SECTION_DROP) {
            int k = d.lastKick;
            if (d.kickActive[k] && d.kickStart[k] == f) {
                dropHits++;
                CHECK(f == at(30.0));
            }
            CHECK(v[k].omni == 1.0f);
            if (fabsf(v[k].sample) > dropPeak) dropPeak = fabsf(v[k].sample);
            CHECK(v[2].sample == 0.0f);
            if (f == at(31.4)) CHECK(d.kickActive[k]);
        }
        if (f >= at(32.0)) {
            CHECK(sec == DOMINE_DEMO_SECTION_FINISHED);
            for (int i = 0; i < DOMINE_DEMO_VOICES; i++) CHECK(v[i].sample == 0.0f);
        }
    }
    CHECK(dropHits == 1);
    CHECK(dropPeak > 0.5f);
    CHECK_NEAR(domine_demo_seconds(&d), 32.0, 1e-9);
}

static void test_levels_and_finite(uint32_t n, const float *az, double sr) {
    DomineDemo d;
    domine_demo_reset(&d, sr, n, az);
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    float peak[DOMINE_DEMO_VOICES] = { 0 }, sumPeak = 0.0f;
    int bad = 0;
    uint64_t end = (uint64_t)llround(32.0 * sr);
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
    for (int i = 0; i < DOMINE_DEMO_VOICES; i++) CHECK(peak[i] <= 0.8f);
    CHECK(peak[0] > 0.6f);
    CHECK(peak[2] > 0.5f);
    CHECK(sumPeak <= 1.0f);
}

static void test_levels(void) {
    float two[2] = { -90.0f, 90.0f };
    test_levels_and_finite(2, two, 48000.0);
    test_levels_and_finite(2, two, 44100.0);
    float s16[16];
    for (int i = 0; i < 16; i++) s16[i] = -180.0f + 22.5f * (float)i;
    test_levels_and_finite(16, s16, 96000.0);
}

static void test_determinism(void) {
    static DomineDemoVoice a[2][DOMINE_DEMO_VOICES];
    float az[4] = { -45.0f, 45.0f, 135.0f, -135.0f };
    DomineDemo d1, d2;
    domine_demo_reset(&d1, SR, 4, az);
    // Run d2 partway, then reset: it must match a fresh run sample for sample.
    domine_demo_reset(&d2, 44100.0, 2, az);
    for (int i = 0; i < 100000; i++) domine_demo_tick(&d2, a[1]);
    domine_demo_reset(&d2, SR, 4, az);
    int diff = 0;
    for (uint64_t f = 0; f < at(32.0); f++) {
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
    test_section_boundaries(48000.0);
    test_section_boundaries(44100.0);
    test_roll_calls();
    test_ping_pong();
    test_orbit();
    test_drop_and_finish();
    test_levels();
    test_determinism();
    test_odd_inputs();
    CHECK_DONE();
}
