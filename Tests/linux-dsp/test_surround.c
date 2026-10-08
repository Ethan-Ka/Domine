// Tests for the N-speaker surround kernel (DomineSurround.h).
#include "DomineSurround.h"
#include "DomineQuad.h"
#include "check.h"
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define NONE DOMINE_NO_DEVICE
#define SENTINEL 9.0f

// MARK: - AudioBufferList helper

typedef struct {
    AudioBufferList *list;
    float *data[8];
    uint32_t ch[8];
    uint32_t nb, frames, cap;
} Buf;

// Buffers with the given channel counts; storage holds `cap` frames, the
// declared size `frames`, so writes past the declared size are detectable.
static Buf buf_new(uint32_t nb, const uint32_t *ch, uint32_t frames, uint32_t cap, float fill) {
    Buf b;
    memset(&b, 0, sizeof b);
    b.nb = nb; b.frames = frames; b.cap = cap;
    b.list = calloc(1, offsetof(AudioBufferList, mBuffers) + nb * sizeof(AudioBuffer));
    b.list->mNumberBuffers = nb;
    for (uint32_t i = 0; i < nb; i++) {
        b.ch[i] = ch[i];
        b.data[i] = malloc((size_t)cap * ch[i] * sizeof(float) + sizeof(float));
        for (uint32_t j = 0; j < cap * ch[i]; j++) b.data[i][j] = fill;
        b.list->mBuffers[i].mNumberChannels = ch[i];
        b.list->mBuffers[i].mDataByteSize = frames * ch[i] * (uint32_t)sizeof(float);
        b.list->mBuffers[i].mData = b.data[i];
    }
    return b;
}

static void buf_free(Buf *b) {
    for (uint32_t i = 0; i < b->nb; i++) free(b->data[i]);
    free(b->list);
}

static float *buf_at(Buf *b, uint32_t flat, uint32_t frame) {
    uint32_t base = 0;
    for (uint32_t i = 0; i < b->nb; i++) {
        if (flat < base + b->ch[i]) return &b->data[i][(size_t)frame * b->ch[i] + (flat - base)];
        base += b->ch[i];
    }
    abort();
}

static Buf stereo_in(const float *l, const float *r, uint32_t frames) {
    const uint32_t ch[1] = { 2 };
    Buf b = buf_new(1, ch, frames, frames, 0.0f);
    for (uint32_t f = 0; f < frames; f++) { b.data[0][2 * f] = l[f]; b.data[0][2 * f + 1] = r[f]; }
    return b;
}

static Buf out_new(uint32_t channels, uint32_t frames) {
    const uint32_t ch[1] = { channels };
    return buf_new(1, ch, frames, frames, SENTINEL);
}

// Deterministic pseudo-random numbers.
static uint32_t rng = 12345;
static float frand(void) { // [-1, 1]
    rng = rng * 1664525u + 1013904223u;
    return (float)((double)(rng >> 8) / (double)(1u << 24) * 2.0 - 1.0);
}

#define NF 64
static float L[NF], R[NF];
static void fill_program(void) {
    for (int i = 0; i < NF; i++) { L[i] = frand(); R[i] = frand(); }
    L[0] = 1.0f; R[0] = -1.0f; L[1] = -1.0f; R[1] = 1.0f; L[2] = 0.0f; R[2] = 0.5f;
}

static DomineSurround *make(double sr, uint32_t n, const float *az) {
    DomineSurround *s = domine_surround_create(sr, 512);
    domine_surround_set_speakers(s, n, az);
    domine_surround_set_surround_level(s, 0); // tests opt in to ambience
    return s;
}

static void run(DomineSurround *s, const float *l, const float *r, uint32_t frames, Buf *out,
                const uint32_t *offsets) {
    Buf in = stereo_in(l, r, frames);
    domine_surround_process(s, in.list, out->list, frames, offsets);
    buf_free(&in);
}

// MARK: - VBAP

static float sumsq(const float *g, uint32_t n) {
    double a = 0;
    for (uint32_t i = 0; i < n; i++) a += (double)g[i] * g[i];
    return (float)a;
}

static void test_vbap_rules(void) {
    float g[16];
    const float quad[4] = { -30, 30, -110, 110 };
    domine_surround_vbap(4, quad, NULL, 110, g);
    CHECK(g[0] == 0 && g[1] == 0 && g[2] == 0 && g[3] == 1);
    domine_surround_vbap(4, quad, NULL, -30, g);
    CHECK(g[0] == 1 && g[1] == 0 && g[2] == 0 && g[3] == 0);
    domine_surround_vbap(4, quad, NULL, 330, g); // wraps to -30
    CHECK(g[0] == 1 && g[3] == 0);

    // Midpoint of a 60 degree pair.
    const float pair[2] = { -30, 30 };
    domine_surround_vbap(2, pair, NULL, 0, g);
    CHECK(g[0] == g[1]);
    CHECK_NEAR(g[0], 0.70710678, 1e-7);

    // VBAP inside a 90 degree pair: tangent law, g1/g2 = sin(arc-d)/sin(d).
    const float wide[2] = { -45, 45 };
    domine_surround_vbap(2, wide, NULL, -15, g);
    CHECK_NEAR(g[0] / g[1], sin(60 * M_PI / 180) / sin(30 * M_PI / 180), 1e-6);
    CHECK_NEAR(sumsq(g, 2), 1.0, 1e-6);

    // Gap rule behind a front-only pair (arc of 300 degrees from 30 to -30).
    domine_surround_vbap(2, pair, NULL, 180, g);
    CHECK_NEAR(g[0], cos(M_PI / 4), 1e-7);
    CHECK_NEAR(g[1], cos(M_PI / 4), 1e-7);
    domine_surround_vbap(2, pair, NULL, 90, g);  // 60 of 300 degrees past 30
    CHECK_NEAR(g[1], cos(0.2 * M_PI / 2), 1e-7);
    CHECK_NEAR(g[0], sin(0.2 * M_PI / 2), 1e-7);
    // A 180 degree arc also uses the gap rule.
    const float lr[2] = { -90, 90 };
    domine_surround_vbap(2, lr, NULL, 0, g);
    CHECK_NEAR(g[0], cos(M_PI / 4), 1e-7);
    CHECK_NEAR(g[1], cos(M_PI / 4), 1e-7);
    domine_surround_vbap(2, lr, NULL, 45, g);
    CHECK_NEAR(g[1], cos(0.25 * M_PI / 2), 1e-7);

    // Coincident speakers share by power.
    const float co[3] = { 0, 0.3f, 90 };
    domine_surround_vbap(3, co, NULL, 0, g);
    CHECK_NEAR(g[0], 0.70710678, 1e-7);
    CHECK(g[0] == g[1] && g[2] == 0);
    domine_surround_vbap(3, co, NULL, 45, g);
    CHECK(g[0] == g[1]);
    CHECK_NEAR(g[0] * sqrt(2.0), g[2], 1e-6);
    CHECK_NEAR(sumsq(g, 3), 1.0, 1e-6);
    // Coincident across the 180 wrap.
    const float wrap[3] = { 179.8f, -179.9f, 0 };
    domine_surround_vbap(3, wrap, NULL, 179.8f, g);
    CHECK_NEAR(g[0], 0.70710678, 1e-7);
    CHECK(g[0] == g[1] && g[2] == 0);
    // All at one spot: equal power.
    const float same[4] = { 10, 10, 10, 10 };
    domine_surround_vbap(4, same, NULL, -100, g);
    for (int i = 0; i < 4; i++) CHECK(g[i] == 0.5f);

    // Absent speakers get nothing; the pair around them takes over.
    const float three[3] = { -30, 30, 0 };
    const uint8_t pr[3] = { 1, 1, 0 };
    domine_surround_vbap(3, three, pr, 0, g);
    CHECK(g[2] == 0 && g[0] == g[1]);
    CHECK_NEAR(g[0], 0.70710678, 1e-7);
    domine_surround_vbap(3, three, NULL, 0, g);
    CHECK(g[2] == 1 && g[0] == 0 && g[1] == 0);

    // Single speaker, single present speaker, none present.
    const float one[1] = { 45 };
    domine_surround_vbap(1, one, NULL, -170, g);
    CHECK(g[0] == 1);
    const uint8_t onlyLast[3] = { 0, 0, 1 };
    domine_surround_vbap(3, three, onlyLast, 123, g);
    CHECK(g[0] == 0 && g[1] == 0 && g[2] == 1);
    const uint8_t noneP[3] = { 0, 0, 0 };
    g[0] = g[1] = g[2] = 5;
    domine_surround_vbap(3, three, noneP, 0, g);
    CHECK(g[0] == 0 && g[1] == 0 && g[2] == 0);
}

static void test_vbap_unit_power_sweep(void) {
    float az[16], g[16];
    uint8_t pr[16];
    for (int trial = 0; trial < 200; trial++) {
        const uint32_t n = 1 + (uint32_t)((frand() + 1.0f) * 7.99f);
        int any = 0;
        for (uint32_t i = 0; i < n; i++) {
            az[i] = frand() * 200.0f;
            if (trial % 5 == 0 && i > 0) az[i] = az[i - 1] + frand() * 0.3f; // near coincident
            pr[i] = frand() > -0.6f;
            any |= pr[i];
        }
        if (!any) pr[0] = 1;
        for (int a = -180; a <= 180; a++) {
            domine_surround_vbap(n, az, pr, (float)a, g);
            int ok = 1;
            for (uint32_t i = 0; i < n; i++) ok &= g[i] >= 0.0f && g[i] <= 1.0f && (pr[i] || g[i] == 0.0f);
            CHECK(ok);
            const double p = sumsq(g, n);
            if (fabs(p - 1.0) > 1e-5) { CHECK_NEAR(p, 1.0, 1e-5); return; }
        }
    }
}

static void test_distance_comp(void) {
    const float d[4] = { 2.0f, 3.43f, 0.0f, NAN };
    float ms[4], g[4];
    domine_surround_distance_comp(4, d, ms, g);
    CHECK(ms[1] == 0.0f && g[1] == 1.0f);
    CHECK_NEAR(ms[0], 1.43 / 343.0 * 1000.0, 1e-4);
    CHECK_NEAR(g[0], 2.0 / 3.43, 1e-6);
    CHECK_NEAR(ms[2], 2.43 / 343.0 * 1000.0, 1e-4);
    CHECK_NEAR(g[2], 1.0 / 3.43, 1e-6);
    CHECK_NEAR(ms[3], ms[2], 1e-6);
    domine_surround_distance_comp(4, d, NULL, g); // NULL outputs allowed
    domine_surround_distance_comp(4, d, ms, NULL);
    CHECK(g[1] == 1.0f);
}

// MARK: - Bit-exact layouts

static void test_two_speakers_bit_exact(void) {
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(48000, 2, az);
    const uint32_t off[2] = { 0, 2 };
    for (int call = 0; call < 3; call++) {
        fill_program();
        Buf out = out_new(4, NF);
        run(s, L, R, NF, &out, off);
        int ok = 1;
        for (uint32_t f = 0; f < NF; f++)
            ok &= *buf_at(&out, 0, f) == L[f] && *buf_at(&out, 1, f) == L[f]
               && *buf_at(&out, 2, f) == R[f] && *buf_at(&out, 3, f) == R[f];
        CHECK(ok);
        buf_free(&out);
    }
    CHECK(domine_surround_peak(s, 0) <= 1.0f && domine_surround_peak(s, 3) == 0.0f);
    domine_surround_destroy(s);

    // Speaker order does not matter.
    const float rev[2] = { 30, -30 };
    s = make(48000, 2, rev);
    fill_program();
    Buf out = out_new(4, NF);
    run(s, L, R, NF, &out, off);
    int ok = 1;
    for (uint32_t f = 0; f < NF; f++) ok &= *buf_at(&out, 0, f) == R[f] && *buf_at(&out, 2, f) == L[f];
    CHECK(ok);
    float pk = 0;
    for (uint32_t f = 0; f < NF; f++) if (fabsf(R[f]) > pk) pk = fabsf(R[f]);
    CHECK(domine_surround_peak(s, 0) == pk);
    buf_free(&out);
    domine_surround_destroy(s);
}

static void test_one_speaker_bit_exact(void) {
    const float az[1] = { 77 };
    DomineSurround *s = make(48000, 1, az);
    const uint32_t off[1] = { 0 };
    fill_program();
    Buf out = out_new(2, NF);
    run(s, L, R, NF, &out, off);
    int ok = 1;
    for (uint32_t f = 0; f < NF; f++) {
        const float mono = 0.5f * (L[f] + R[f]); // the quad kernel's formula
        ok &= *buf_at(&out, 0, f) == mono && *buf_at(&out, 1, f) == mono;
    }
    CHECK(ok);
    buf_free(&out);
    domine_surround_destroy(s);
}

static void test_quad_layout_matches_quad_mirror(void) {
    const float az[4] = { -30, 30, -110, 110 };
    DomineSurround *s = make(48000, 4, az);
    const DomineSpatialParams sp = { 0.0f, 15.0f, 5000.0f };
    domine_surround_set_spatial(s, &sp);
    domine_surround_set_surround_level(s, 1.0f);
    DomineQuad *q = domine_quad_create(48000, 512);
    const uint32_t off[4] = { 0, 2, 4, 6 };
    for (int call = 0; call < 3; call++) {
        fill_program();
        Buf a = out_new(8, NF), b = out_new(8, NF);
        run(s, L, R, NF, &a, off);
        Buf in = stereo_in(L, R, NF);
        domine_quad_process(q, in.list, b.list, NF, off);
        buf_free(&in);
        CHECK(memcmp(a.data[0], b.data[0], NF * 8 * sizeof(float)) == 0);
        CHECK(*buf_at(&a, 4, 5) == L[5] && *buf_at(&a, 7, 5) == R[5]);
        buf_free(&a); buf_free(&b);
    }
    domine_quad_destroy(q);
    domine_surround_destroy(s);
}

static void test_absent_speaker_redistribution(void) {
    // A third speaker in the middle that is absent: the pair plays as a pair,
    // and with only 2 present there is no ambience.
    const float az[3] = { -30, 0, 30 };
    DomineSurround *s = make(48000, 3, az);
    const uint32_t off[3] = { 0, NONE, 2 };
    fill_program();
    Buf out = out_new(4, NF);
    run(s, L, R, NF, &out, off);
    int ok = 1;
    for (uint32_t f = 0; f < NF; f++) ok &= *buf_at(&out, 0, f) == L[f] && *buf_at(&out, 2, f) == R[f];
    CHECK(ok);
    CHECK(domine_surround_peak(s, 1) == 0.0f);
    buf_free(&out);

    // Now present: the centre speaker gets part of L and R.
    const uint32_t all[3] = { 0, 2, 4 };
    Buf out3 = out_new(6, NF);
    const DomineSpatialParams sp = { 0.0f, 15.0f, 5000.0f };
    domine_surround_set_spatial(s, &sp);
    domine_surround_set_surround_level(s, 0.0f);
    float one[NF], zero[NF];
    for (int i = 0; i < NF; i++) { one[i] = 1.0f; zero[i] = 0.0f; }
    run(s, one, zero, NF, &out3, all); // ramps from the 2-speaker matrix
    run(s, one, zero, NF, &out3, all);
    CHECK(*buf_at(&out3, 0, 10) == 1.0f); // L sits on speaker 0
    CHECK(*buf_at(&out3, 2, 10) == 0.0f);
    buf_free(&out3);
    domine_surround_destroy(s);
}

// MARK: - Gain, delay, mute

static void test_gain_ramp(void) {
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(1000, 2, az);
    const uint32_t off[2] = { 0, 2 };
    float one[60];
    for (int i = 0; i < 60; i++) one[i] = 1.0f;
    Buf out = out_new(4, 60);
    run(s, one, one, 60, &out, off);
    domine_surround_set_gain(s, 0, 0.5f);
    domine_surround_set_gain(s, 1, 7.0f); // clamps to 1
    run(s, one, one, 60, &out, off);
    int ok = 1;
    for (int i = 0; i < 60; i++) {
        const float e = i + 1 >= 30 ? 0.5f : 1.0f + (0.5f - 1.0f) * (float)(i + 1) / 30.0f;
        ok &= *buf_at(&out, 0, (uint32_t)i) == e && *buf_at(&out, 2, (uint32_t)i) == 1.0f;
    }
    CHECK(ok);
    buf_free(&out);
    domine_surround_destroy(s);
}

static void test_delay(void) {
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(48000, 2, az);
    const uint32_t off[2] = { 0, 2 };
    domine_surround_set_delay_ms(s, 1, 0.25f); // 12 samples
    domine_surround_set_delay_ms(s, 0, -3.0f);
    float l[32], r[32];
    for (int i = 0; i < 32; i++) { l[i] = (float)(i + 1) / 64; r[i] = -(float)(i + 1) / 64; }
    Buf out = out_new(4, 32);
    run(s, l, r, 32, &out, off);
    int ok = 1;
    for (int i = 0; i < 32; i++) {
        ok &= *buf_at(&out, 0, (uint32_t)i) == l[i];
        ok &= *buf_at(&out, 2, (uint32_t)i) == (i < 12 ? 0.0f : r[i - 12]);
        ok &= *buf_at(&out, 3, (uint32_t)i) == (i < 12 ? 0.0f : r[i - 12]);
    }
    CHECK(ok);
    buf_free(&out);
    domine_surround_destroy(s);
}

static void test_mute_fade(void) {
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(1000, 2, az);
    const uint32_t off[2] = { 0, 2 };
    float one[100];
    for (int i = 0; i < 100; i++) one[i] = 1.0f;
    Buf out = out_new(4, 100);
    domine_surround_set_muted(s, 1);
    run(s, one, one, 100, &out, off);
    int ok = 1;
    for (int i = 0; i < 100; i++)
        for (uint32_t c = 0; c < 4; c++) ok &= *buf_at(&out, c, (uint32_t)i) == (i < 50 ? (float)(49 - i) / 50 : 0.0f);
    CHECK(ok);
    domine_surround_set_muted(s, 0);
    run(s, one, one, 100, &out, off);
    ok = 1;
    for (int i = 0; i < 100; i++)
        for (uint32_t c = 0; c < 4; c++) ok &= *buf_at(&out, c, (uint32_t)i) == (i < 50 ? (float)(i + 1) / 50 : 1.0f);
    CHECK(ok);
    buf_free(&out);
    domine_surround_destroy(s);

    s = make(1000, 2, az);
    domine_surround_start_faded_out(s);
    Buf o2 = out_new(4, 100);
    run(s, one, one, 100, &o2, off);
    CHECK(*buf_at(&o2, 0, 0) == 1.0f / 50 && *buf_at(&o2, 0, 49) == 1.0f && *buf_at(&o2, 2, 99) == 1.0f);
    buf_free(&o2);
    domine_surround_destroy(s);
}

// MARK: - Field: orbit, width, headroom

static void test_orbit(void) {
    const float az[4] = { 0, 90, 180, -90 };
    DomineSurround *s = make(1000, 4, az);
    domine_surround_set_surround_level(s, 0.0f);
    domine_surround_set_width(s, 90);
    domine_surround_set_orbit_rate(s, 90); // degrees per second
    const uint32_t off[4] = { 0, 2, 4, 6 };
    float half[1000], zero[1000];
    for (int i = 0; i < 1000; i++) { half[i] = 0.5f; zero[i] = 0.0f; }
    Buf out = out_new(8, 1000);
    // First call snaps to the phase at its end: 90 degrees, so L (at -90) is at 0.
    run(s, half, zero, 1000, &out, off);
    CHECK(*buf_at(&out, 0, 0) == 0.5f && *buf_at(&out, 6, 0) == 0.0f && *buf_at(&out, 2, 999) == 0.0f);
    // Second call moves L from speaker 0 to speaker 1.
    run(s, half, zero, 1000, &out, off);
    CHECK(*buf_at(&out, 0, 999) == 0.0f && *buf_at(&out, 2, 999) == 0.5f);
    CHECK(*buf_at(&out, 0, 499) > 0.2f && *buf_at(&out, 2, 499) > 0.2f);
    // Stop and reset: back to -90 by the end of the next call.
    domine_surround_set_orbit_rate(s, 0);
    domine_surround_reset_orbit(s);
    run(s, half, zero, 1000, &out, off);
    CHECK(*buf_at(&out, 6, 999) == 0.5f && *buf_at(&out, 2, 999) == 0.0f);
    run(s, half, zero, 1000, &out, off);
    CHECK(*buf_at(&out, 6, 0) == 0.5f);
    // Static rotation moves it too.
    domine_surround_set_rotation(s, 180 + 360);
    run(s, half, zero, 1000, &out, off);
    CHECK(*buf_at(&out, 2, 999) == 0.5f);
    buf_free(&out);
    domine_surround_destroy(s);
}

static void test_width(void) {
    const float az[2] = { -30, 30 };
    float g0[2], g1[2];
    for (int pass = 0; pass < 2; pass++) {
        DomineSurround *s = make(48000, 2, az);
        domine_surround_set_width(s, pass == 0 ? 15.0f : 2.0f); // 2 clamps to 10
        const float w = pass == 0 ? 15.0f : 10.0f;
        domine_surround_vbap(2, az, NULL, -w, g0);
        domine_surround_vbap(2, az, NULL, w, g1);
        const uint32_t off[2] = { 0, 2 };
        float one[8], zero[8];
        for (int i = 0; i < 8; i++) { one[i] = 1.0f; zero[i] = 0.0f; }
        Buf out = out_new(4, 8);
        run(s, one, zero, 8, &out, off);
        const float scale = 1.0f / (g0[0] + g1[0]);
        CHECK_NEAR(*buf_at(&out, 0, 3), g0[0] * scale, 1e-6);
        CHECK_NEAR(*buf_at(&out, 2, 3), g0[1] * scale, 1e-6);
        CHECK(*buf_at(&out, 0, 3) > *buf_at(&out, 2, 3));
        CHECK(*buf_at(&out, 2, 3) > 0.0f);
        buf_free(&out);
        domine_surround_destroy(s);
    }
}

static void test_headroom(void) {
    float az[8];
    for (int trial = 0; trial < 20; trial++) {
        const uint32_t n = 3 + (uint32_t)trial % 6;
        for (uint32_t i = 0; i < n; i++) az[i] = frand() * 180.0f;
        DomineSurround *s = make(48000, n, az);
        domine_surround_set_surround_level(s, 1.0f);
        domine_surround_set_rotation(s, 17.0f * (float)trial);
        domine_surround_set_orbit_rate(s, 300.0f);
        domine_surround_set_width(s, 10.0f + (float)trial * 4.0f);
        uint32_t off[8];
        for (uint32_t i = 0; i < n; i++) off[i] = 2 * i;
        float l[256], r[256];
        float worst = 0;
        for (int call = 0; call < 30; call++) {
            for (int i = 0; i < 256; i++) {
                l[i] = frand() > 0 ? 1.0f : -1.0f;
                r[i] = (call & 1) ? -l[i] : (frand() > 0 ? 1.0f : -1.0f);
            }
            Buf out = out_new(2 * n, 256);
            run(s, l, r, 256, &out, off);
            for (uint32_t c = 0; c < 2 * n; c++)
                for (uint32_t f = 0; f < 256; f++) if (fabsf(*buf_at(&out, c, f)) > worst) worst = fabsf(*buf_at(&out, c, f));
            buf_free(&out);
        }
        CHECK(worst <= 1.0f + 1e-6f);
        CHECK(worst > 0.3f);
        domine_surround_destroy(s);
    }
}

// MARK: - Demo

typedef struct { DomineDemo d; } Ref;

// Reference demo mix for one frame on n present speakers.
static void ref_demo_frame(DomineDemo *d, uint32_t n, const float *az, float *mix) {
    DomineDemoVoice v[DOMINE_DEMO_VOICES];
    (void)domine_demo_tick(d, v);
    for (uint32_t k = 0; k < n; k++) mix[k] = 0;
    for (int i = 0; i < DOMINE_DEMO_VOICES; i++) {
        if (v[i].sample == 0.0f) continue;
        float g[16];
        domine_surround_vbap(n, az, NULL, v[i].azimuth, g);
        const float omni = v[i].omni;
        for (uint32_t k = 0; k < n; k++) {
            const float gk = omni == 0.0f ? g[k] : (1.0f - omni) * g[k] + omni / sqrtf((float)n);
            mix[k] += gk * v[i].sample;
        }
    }
}

static void test_demo(void) {
    const double sr = 8000;
    const float az[4] = { -45, 45, -135, 135 };
    DomineSurround *s = make(sr, 4, az);
    domine_surround_set_surround_level(s, 0.0f);
    const uint32_t off[4] = { 0, 2, 4, 6 };
    CHECK(domine_surround_demo_status(s, NULL, NULL, NULL) == 0);
    enum { BLOCK = 500 };
    float l[BLOCK], r[BLOCK];
    for (int i = 0; i < BLOCK; i++) { l[i] = 0.25f; r[i] = 0.25f; }
    // Program reference: the same kernel state without the demo.
    Buf out = out_new(8, BLOCK);
    run(s, l, r, BLOCK, &out, off);
    float prog[4];
    for (uint32_t k = 0; k < 4; k++) prog[k] = *buf_at(&out, 2 * k, BLOCK - 1);

    domine_surround_set_demo(s, 1);
    DomineDemo ref;
    domine_demo_reset(&ref, sr, 4, az);
    const uint32_t fl = 400; // 50 ms at 8 kHz
    float mix[4];
    double worst = 0;
    run(s, l, r, BLOCK, &out, off);
    for (uint32_t f = 0; f < BLOCK; f++) {
        ref_demo_frame(&ref, 4, az, mix);
        const uint32_t pos = f + 1 < fl ? f + 1 : fl;
        const float dA = (float)pos / (float)fl, pA = (float)(fl - pos) / (float)fl;
        for (uint32_t k = 0; k < 4; k++) {
            const double e = (double)prog[k] * pA + (double)dA * mix[k];
            const double d = fabs(*buf_at(&out, 2 * k, f) - e);
            if (d > worst) worst = d;
        }
    }
    CHECK(worst < 1e-5);
    float sec = -1, a = 0;
    int section = -1;
    CHECK(domine_surround_demo_status(s, &sec, &a, &section) != 0);
    CHECK_NEAR(sec, BLOCK / sr, 1e-6);
    CHECK(section == DOMINE_DEMO_SECTION_ROLL_CALL);
    CHECK(a == domine_demo_focus_azimuth(&ref));
    // The demo is audible: something moves on the speakers.
    float peakSum = 0;
    for (uint32_t k = 0; k < 4; k++) peakSum += domine_surround_peak(s, k);
    CHECK(peakSum > 0.1f);

    // Stop: program fades back in over 50 ms, demo status off.
    domine_surround_set_demo(s, 0);
    run(s, l, r, BLOCK, &out, off);
    CHECK(domine_surround_demo_status(s, &sec, NULL, &section) == 0);
    CHECK(section == DOMINE_DEMO_SECTION_IDLE && sec == 0.0f);
    int ok = 1;
    for (uint32_t f = fl; f < BLOCK; f++)
        for (uint32_t k = 0; k < 4; k++) ok &= *buf_at(&out, 2 * k, f) == prog[k];
    CHECK(ok);

    // Run to the end: finishes by itself, then program returns.
    domine_surround_set_demo(s, 1);
    int sawOrbit = 0;
    const uint32_t calls = (uint32_t)(DOMINE_DEMO_LENGTH_S * sr / BLOCK) + 2;
    for (uint32_t c = 0; c < calls; c++) {
        run(s, l, r, BLOCK, &out, off);
        domine_surround_demo_status(s, NULL, NULL, &section);
        sawOrbit |= section == DOMINE_DEMO_SECTION_ORBIT;
        for (uint32_t k = 0; k < 8; k++)
            for (uint32_t f = 0; f < BLOCK; f++) if (fabsf(*buf_at(&out, k, f)) > 1.0f) ok = 0;
    }
    CHECK(ok);
    CHECK(sawOrbit);
    CHECK(domine_surround_demo_status(s, NULL, NULL, &section) == 0);
    CHECK(section == DOMINE_DEMO_SECTION_FINISHED);
    run(s, l, r, BLOCK, &out, off);
    ok = 1;
    for (uint32_t k = 0; k < 4; k++) ok &= *buf_at(&out, 2 * k, BLOCK - 1) == prog[k];
    CHECK(ok);
    buf_free(&out);
    domine_surround_destroy(s);
}

// MARK: - Test tone and click test

static void test_test_tone(void) {
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(1000, 2, az);
    domine_surround_set_gain(s, 1, 0.5f);     // ignored by the tone
    domine_surround_set_delay_ms(s, 1, 5.0f); // ignored by the tone
    const uint32_t off[2] = { 0, 2 };
    float one[100];
    for (int i = 0; i < 100; i++) one[i] = 1.0f;
    Buf out = out_new(4, 100);
    run(s, one, one, 100, &out, off);
    domine_surround_set_test_tone(s, 1);
    run(s, one, one, 100, &out, off);
    double phase = 0;
    int ok = 1;
    for (int i = 0; i < 100; i++) {
        const float tone = (float)domine_chime_sample(phase);
        phase += 1.0 / 1000.0;
        const float e = i < 40 ? (float)i / 40.0f : 1.0f;
        const float a = i < 40 ? 1.0f * (1.0f - e) : 0.0f;
        const float b = i < 40 ? tone * e + 0.5f * (1.0f - e) : tone;
        ok &= *buf_at(&out, 0, (uint32_t)i) == a && *buf_at(&out, 1, (uint32_t)i) == a;
        ok &= *buf_at(&out, 2, (uint32_t)i) == b && *buf_at(&out, 3, (uint32_t)i) == b;
    }
    CHECK(ok);
    // Off: program returns after 40 ms (gain and delay apply again).
    domine_surround_set_test_tone(s, -1);
    run(s, one, one, 100, &out, off);
    CHECK(*buf_at(&out, 0, 99) == 1.0f && *buf_at(&out, 2, 99) == 0.5f);
    // Mute applies to the tone.
    domine_surround_set_test_tone(s, 0);
    domine_surround_set_muted(s, 1);
    run(s, one, one, 100, &out, off);
    CHECK(*buf_at(&out, 0, 99) == 0.0f);
    buf_free(&out);
    domine_surround_destroy(s);
}

static void test_click_test(void) {
    const double sr = 8000;
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(sr, 2, az);
    domine_surround_set_gain(s, 0, 0.5f);
    domine_surround_set_delay_ms(s, 1, 1.0f); // 8 samples
    const uint32_t off[2] = { 0, 2 };
    enum { N = 400 };
    float zero[N];
    for (int i = 0; i < N; i++) zero[i] = 0.0f;
    Buf out = out_new(4, N);
    run(s, zero, zero, N, &out, off);
    domine_surround_set_click_test(s, 1);
    run(s, zero, zero, N, &out, off);
    const uint32_t full = 320, len = 16; // 40 ms and 2 ms at 8 kHz
    int ok = 1;
    for (uint32_t f = 0; f < N; f++) {
        float click = 0.0f, late = 0.0f;
        if (f >= full && f - full < len) {
            const uint32_t n = f - full;
            click = (float)(DOMINE_CLICK_AMPLITUDE * (0.5 - 0.5 * cos(2.0 * M_PI * n / len))
                            * sin(2.0 * M_PI * DOMINE_CLICK_HZ * n / sr));
        }
        if (f >= full + 8 && f - full - 8 < len) {
            const uint32_t n = f - full - 8;
            late = (float)(DOMINE_CLICK_AMPLITUDE * (0.5 - 0.5 * cos(2.0 * M_PI * n / len))
                           * sin(2.0 * M_PI * DOMINE_CLICK_HZ * n / sr));
        }
        ok &= *buf_at(&out, 0, f) == click * 0.5f;
        ok &= *buf_at(&out, 2, f) == late;
    }
    CHECK(ok);
    CHECK(fabsf(*buf_at(&out, 0, full + 5)) > 0.01f);
    buf_free(&out);
    domine_surround_destroy(s);
}

static void test_calibration_pair(void) {
    // domine_calibration_chirp_sample matches domine_calibration_chirp.
    {
        enum { M = 1200 };
        float up[M], down[M];
        domine_calibration_chirp(up, M, 8000, 1);
        domine_calibration_chirp(down, M, 8000, 0);
        int ok = 1;
        for (uint32_t n = 0; n < M; n++) {
            ok &= domine_calibration_chirp_sample(n, 8000, 1) == up[n];
            ok &= domine_calibration_chirp_sample(n, 8000, 0) == down[n];
        }
        CHECK(ok);
    }
    const double sr = 8000;
    const float az[3] = { -30, 30, 180 };
    DomineSurround *s = make(sr, 3, az);
    domine_surround_set_gain(s, 0, 0.5f);
    domine_surround_set_delay_ms(s, 0, 1.0f); // must not shift the chirp
    const uint32_t off[3] = { 0, 2, 4 };
    enum { N = 9000 };
    static float zero[N];
    Buf out = out_new(6, N);
    run(s, zero, zero, 400, &out, off); // settle gains
    domine_surround_set_calibration_pair(s, 0, 2);
    run(s, zero, zero, N, &out, off);
    const uint32_t full = 320, period = 8000; // 40 ms fade, 1000 ms period
    int ok = 1, silent = 1;
    for (uint32_t f = 0; f < N; f++) {
        float up = 0.0f, down = 0.0f;
        if (f >= full) {
            const uint32_t n = (f - full) % period;
            up = domine_calibration_chirp_sample(n, sr, 1);
            down = domine_calibration_chirp_sample(n, sr, 0);
        }
        ok &= *buf_at(&out, 0, f) == up * 0.5f && *buf_at(&out, 1, f) == up * 0.5f;
        ok &= *buf_at(&out, 4, f) == down && *buf_at(&out, 5, f) == down;
        silent &= *buf_at(&out, 2, f) == 0.0f && *buf_at(&out, 3, f) == 0.0f;
    }
    CHECK(ok);
    CHECK(silent);
    CHECK(fabsf(*buf_at(&out, 4, full + 100)) > 0.01f);
    CHECK(fabsf(*buf_at(&out, 0, full + period + 100)) > 0.001f);
    buf_free(&out);
    domine_surround_destroy(s);

    // Off by default and for invalid pairs: two speakers pass L and R.
    const float az2[2] = { -30, 30 };
    const uint32_t off2[2] = { 0, 2 };
    const int bad[4][2] = { { -1, 1 }, { 1, 1 }, { 0, 16 }, { -1, -1 } };
    for (int t = 0; t < 5; t++) {
        DomineSurround *k = make(48000, 2, az2);
        if (t < 4) domine_surround_set_calibration_pair(k, bad[t][0], bad[t][1]);
        fill_program();
        Buf o = out_new(4, NF);
        run(k, L, R, NF, &o, off2);
        int pass = 1;
        for (uint32_t f = 0; f < NF; f++) pass &= *buf_at(&o, 0, f) == L[f] && *buf_at(&o, 2, f) == R[f];
        CHECK(pass);
        buf_free(&o);
        domine_surround_destroy(k);
    }

    // Turning it off crossfades back to program.
    {
        DomineSurround *k = make(sr, 2, az2);
        enum { M = 2000 };
        static float ones[M];
        for (int i = 0; i < M; i++) ones[i] = 0.25f;
        Buf o = out_new(4, M);
        domine_surround_set_calibration_pair(k, 0, 1);
        run(k, ones, ones, M, &o, off2);
        domine_surround_set_calibration_pair(k, -1, -1);
        run(k, ones, ones, M, &o, off2);
        CHECK(*buf_at(&o, 0, M - 1) == 0.25f);
        CHECK(*buf_at(&o, 2, M - 1) == 0.25f);
        buf_free(&o);
        domine_surround_destroy(k);
    }
}

// MARK: - IO

static void test_multi_tap(void) {
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(48000, 2, az);
    const uint32_t first[2] = { 0, 1 }, chans[2] = { 2, 2 }, inter[2] = { 1, 1 };
    domine_surround_set_tap_layout(s, 2, first, chans, inter);
    const uint32_t ch[2] = { 2, 2 };
    Buf in = buf_new(2, ch, 16, 16, 0.0f);
    for (uint32_t f = 0; f < 16; f++) {
        *buf_at(&in, 0, f) = 0.25f; *buf_at(&in, 1, f) = -0.25f;
        *buf_at(&in, 2, f) = 0.125f; *buf_at(&in, 3, f) = 0.5f;
    }
    Buf out = out_new(4, 16);
    const uint32_t off[2] = { 0, 2 };
    domine_surround_process(s, in.list, out.list, 16, off);
    CHECK(*buf_at(&out, 0, 7) == 0.375f && *buf_at(&out, 2, 7) == 0.25f);
    domine_surround_set_tap_gain(s, 1, 0.0f);
    domine_surround_process(s, in.list, out.list, 16, off);
    domine_surround_process(s, in.list, out.list, 16, off); // 20 ms ramp, not done
    CHECK(*buf_at(&out, 0, 15) < 0.375f && *buf_at(&out, 0, 15) > 0.25f);
    buf_free(&in); buf_free(&out);
    domine_surround_destroy(s);
}

static void test_ioproc(void) {
    const float az[2] = { -30, 30 };
    DomineSurround *s = make(48000, 2, az);
    const uint32_t off[2] = { 0, 2 };
    domine_surround_set_layout(s, 1, 2, off);
    domine_surround_set_input_format(s, 2, 0);
    fill_program();
    const uint32_t ich[2] = { 2, 2 };
    Buf in = buf_new(2, ich, NF, NF, 0.9f); // buffer 0 is a sub-device input
    for (uint32_t f = 0; f < NF; f++) { *buf_at(&in, 2, f) = L[f]; *buf_at(&in, 3, f) = R[f]; }
    const uint32_t och[2] = { 2, 2 };
    Buf out = buf_new(2, och, NF, NF, SENTINEL);
    AudioTimeStamp t;
    memset(&t, 0, sizeof t);
    CHECK(domine_surround_ioproc(0, &t, in.list, &t, out.list, &t, s) == 0);
    int ok = 1;
    for (uint32_t f = 0; f < NF; f++)
        ok &= *buf_at(&out, 0, f) == L[f] && *buf_at(&out, 1, f) == L[f]
           && *buf_at(&out, 2, f) == R[f] && *buf_at(&out, 3, f) == R[f];
    CHECK(ok);
    // Layout count 1: speaker 1 is absent, speaker 0 plays the mono sum.
    domine_surround_set_layout(s, 1, 1, off);
    CHECK(domine_surround_ioproc(0, &t, in.list, &t, out.list, &t, s) == 0);
    CHECK(*buf_at(&out, 2, 5) == 0.0f);
    CHECK(*buf_at(&out, 0, NF - 1) == 0.5f * (L[NF - 1] + R[NF - 1]));
    CHECK(domine_surround_ioproc(0, &t, in.list, &t, out.list, &t, NULL) == 0);
    buf_free(&in); buf_free(&out);
    domine_surround_destroy(s);
}

static void test_bounds_and_zeroing(void) {
    const float az[3] = { -30, 30, 110 };
    DomineSurround *s = make(48000, 3, az);
    domine_surround_set_surround_level(s, 0.7f); // the rear speaker plays ambience
    fill_program();
    // Declared 32 frames, storage 48; speaker 2 at the last channel (offset+1 missing).
    const uint32_t ch[2] = { 3, 5 };
    Buf out = buf_new(2, ch, 32, 48, SENTINEL);
    const uint32_t off[3] = { 0, 3, 7 };
    Buf in = stereo_in(L, R, NF);
    domine_surround_process(s, in.list, out.list, NF, off); // more frames than the buffers hold
    int ok = 1;
    for (uint32_t c = 0; c < 8; c++) {
        for (uint32_t f = 0; f < 32; f++) {
            const float v = *buf_at(&out, c, f);
            ok &= isfinite(v) && v != SENTINEL;
            if (c == 2 || c == 5 || c == 6) ok &= v == 0.0f; // unwritten channels zeroed
        }
        for (uint32_t f = 32; f < 48; f++) ok &= *buf_at(&out, c, f) == SENTINEL;
    }
    CHECK(ok);
    CHECK(*buf_at(&out, 7, 3) != 0.0f);
    // NULL input is silence; NULL output and offsets are ignored.
    domine_surround_process(s, NULL, out.list, 32, off);
    CHECK(*buf_at(&out, 0, 31) == 0.0f || fabsf(*buf_at(&out, 0, 31)) < 1.0f);
    domine_surround_process(s, in.list, NULL, 32, off);
    // Zero speakers: everything zeroed.
    domine_surround_set_speakers(s, 0, NULL);
    domine_surround_process(s, in.list, out.list, 32, off);
    ok = 1;
    for (uint32_t c = 0; c < 8; c++) for (uint32_t f = 0; f < 32; f++) ok &= *buf_at(&out, c, f) == 0.0f;
    CHECK(ok);
    // Zero frames is harmless.
    domine_surround_process(s, in.list, out.list, 0, off);
    buf_free(&in); buf_free(&out);
    domine_surround_destroy(s);
    domine_surround_destroy(NULL);
    CHECK(domine_surround_create(0, 512) == NULL);
}

int main(void) {
    test_vbap_rules();
    test_vbap_unit_power_sweep();
    test_distance_comp();
    test_two_speakers_bit_exact();
    test_one_speaker_bit_exact();
    test_quad_layout_matches_quad_mirror();
    test_absent_speaker_redistribution();
    test_gain_ramp();
    test_delay();
    test_mute_fade();
    test_orbit();
    test_width();
    test_headroom();
    test_demo();
    test_test_tone();
    test_click_test();
    test_calibration_pair();
    test_multi_tap();
    test_ioproc();
    test_bounds_and_zeroing();
    CHECK_DONE();
}
