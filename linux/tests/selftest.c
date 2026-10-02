// Domine for Linux: headless engine self-test (make check). Needs no audio
// hardware and no PipeWire daemon: it tests the SPSC ring, the render path
// (surround kernel, rings, mono fallback, master volume, click test, test
// tone) and that dl_engine_create fails cleanly when no daemon is reachable.
#include "engine.h"
#include "engine_internal.h"
#include "engine_render.h"
#include "DomineChime.h"

#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures, checks;

#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// ---------------------------------------------------------------- ring

static void test_ring_basic(void) {
    float store[2 * 8];
    DLRing r;
    dl_ring_init(&r, store, 8);
    float in[2 * 16], out[2 * 16];
    for (int i = 0; i < 32; i++) in[i] = (float)i;
    CHECK(dl_ring_read(&r, out, 4) == 0, "empty ring reads nothing");
    CHECK(dl_ring_write(&r, in, 5) == 5, "write 5");
    CHECK(dl_ring_fill(&r) == 5, "fill 5");
    CHECK(dl_ring_read(&r, out, 3) == 3, "read 3");
    CHECK(out[0] == 0 && out[5] == 5, "read order");
    // Wraps: head at 5, tail at 3, space 6.
    CHECK(dl_ring_write(&r, in + 10, 7) == 6, "write limited to free space (got %u)", 0u);
    CHECK(dl_ring_fill(&r) == 8, "ring full");
    CHECK(dl_ring_write(&r, in, 1) == 0, "full ring accepts nothing");
    CHECK(dl_ring_read(&r, out, 16) == 8, "read all");
    const float expect[16] = { 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21 };
    CHECK(memcmp(out, expect, sizeof expect) == 0, "wrapped contents in order");
    CHECK(dl_ring_read(&r, NULL, 1) == 0, "empty again");
    // Counters past 2^32 wrap: start positions near the top.
    atomic_store(&r.head, UINT32_MAX - 2);
    atomic_store(&r.tail, UINT32_MAX - 2);
    CHECK(dl_ring_write(&r, in, 6) == 6, "write across counter wrap");
    CHECK(dl_ring_fill(&r) == 6, "fill across counter wrap");
    CHECK(dl_ring_read(&r, out, 6) == 6 && out[0] == 0 && out[11] == 11, "read across counter wrap");
}

#define STRESS_FRAMES 2000000u
static DLRing g_stress;
static float g_stressStore[2 * 256];

static void *producer(void *arg) {
    (void)arg;
    uint32_t next = 0;
    float buf[2 * 37];
    while (next < STRESS_FRAMES) {
        uint32_t n = 37;
        if (STRESS_FRAMES - next < n) n = STRESS_FRAMES - next;
        for (uint32_t i = 0; i < n; i++) { buf[2 * i] = (float)(next + i); buf[2 * i + 1] = -(float)(next + i); }
        next += dl_ring_write(&g_stress, buf, n);
        // On a short write the unsent frames are rebuilt next round.
    }
    return NULL;
}

static void test_ring_threads(void) {
    dl_ring_init(&g_stress, g_stressStore, 256);
    pthread_t t;
    pthread_create(&t, NULL, producer, NULL);
    uint32_t expect = 0;
    int bad = 0;
    float buf[2 * 53];
    while (expect < STRESS_FRAMES) {
        const uint32_t got = dl_ring_read(&g_stress, buf, 53);
        for (uint32_t i = 0; i < got; i++) {
            if (buf[2 * i] != (float)expect || buf[2 * i + 1] != -(float)expect) bad++;
            expect++;
        }
    }
    pthread_join(t, NULL);
    CHECK(bad == 0, "threaded SPSC transfer kept %u frames in order (%d bad)", STRESS_FRAMES, bad);
}

// ---------------------------------------------------------------- render helpers

#define N_FRAMES 512

static float g_in[2 * 8192];

static void make_input(uint32_t frames) {
    for (uint32_t f = 0; f < frames; f++) {
        g_in[2 * f] = 0.5f * sinf(0.01f * (float)f);              // L
        g_in[2 * f + 1] = 0.25f * cosf(0.037f * (float)f) - 0.1f; // R
    }
}

static DLRender *make_render(uint32_t count, const float *az) {
    DLRender *r = dl_render_create(48000.0, count, 256, 16384, 1, 16000);
    if (r == NULL) return NULL;
    DLSpeaker sp[DL_MAX_SPEAKERS];
    memset(sp, 0, sizeof sp);
    for (uint32_t i = 0; i < count; i++) {
        snprintf(sp[i].sinkId, sizeof sp[i].sinkId, "sink%u", i);
        sp[i].azimuth = az[i];
        sp[i].distance = 2.0f;
        sp[i].trim = 1.0f;
    }
    dl_render_configure(r, sp, count, 1.0f);
    for (uint32_t i = 0; i < count; i++) dl_render_set_present(r, i, 1);
    return r;
}

static float g_out[2 * 8192];

static uint32_t pull_all(DLRender *r, uint32_t speaker, uint32_t frames) {
    const uint32_t fill = dl_ring_fill(&r->rings[speaker]);
    dl_render_pull(r, speaker, g_out, frames);
    return fill;
}

// ---------------------------------------------------------------- render tests

static void test_render_two(void) {
    const float az[2] = { -30.0f, 30.0f };
    DLRender *r = make_render(2, az);
    CHECK(r != NULL, "render create");
    if (r == NULL) return;
    make_input(N_FRAMES);
    dl_render_capture(r, g_in, N_FRAMES);   // 512 frames, two kernel chunks of 256
    int bad = 0;
    CHECK(pull_all(r, 0, N_FRAMES) == N_FRAMES, "speaker 1 ring holds one cycle");
    for (uint32_t f = 0; f < N_FRAMES; f++) if (g_out[2 * f] != g_in[2 * f] || g_out[2 * f + 1] != g_in[2 * f]) bad++;
    CHECK(bad == 0, "2 speakers: left speaker plays L on both channels bit for bit (%d bad)", bad);
    bad = 0;
    pull_all(r, 1, N_FRAMES);
    for (uint32_t f = 0; f < N_FRAMES; f++) if (g_out[2 * f] != g_in[2 * f + 1] || g_out[2 * f + 1] != g_in[2 * f + 1]) bad++;
    CHECK(bad == 0, "2 speakers: right speaker plays R on both channels bit for bit (%d bad)", bad);
    float pk = 0.0f;
    for (uint32_t f = 0; f < N_FRAMES; f++) if (fabsf(g_in[2 * f]) > pk) pk = fabsf(g_in[2 * f]);
    CHECK(fabsf(dl_render_peak(r, 0) - pk) < 1e-7f, "peak meter of speaker 1 (%f vs %f)", dl_render_peak(r, 0), pk);
    // Underrun: ring empty, zero-filled, counted.
    g_out[0] = 1.0f;
    dl_render_pull(r, 0, g_out, 64);
    CHECK(g_out[0] == 0.0f && atomic_load(&r->underruns[0]) == 1, "underrun zero-fills and is counted");
    dl_render_destroy(r);
}

static void test_render_four(void) {
    const float az[4] = { -45.0f, 45.0f, -135.0f, 135.0f };
    DLRender *r = make_render(4, az);
    CHECK(r != NULL, "render create 4");
    if (r == NULL) return;
    domine_surround_set_surround_level(r->kernel, 0.0f);
    make_input(N_FRAMES);
    dl_render_capture(r, g_in, N_FRAMES);
    float gl[4], gr[4];
    domine_surround_vbap(4, az, NULL, -30.0f, gl);
    domine_surround_vbap(4, az, NULL, 30.0f, gr);
    double maxErr = 0.0;
    for (uint32_t s = 0; s < 4; s++) {
        pull_all(r, s, N_FRAMES);
        for (uint32_t f = 0; f < N_FRAMES; f++) {
            const float want = g_in[2 * f] * gl[s] + g_in[2 * f + 1] * gr[s];
            for (int c = 0; c < 2; c++) {
                const double err = fabs((double)g_out[2 * f + c] - want);
                if (err > maxErr) maxErr = err;
            }
        }
    }
    CHECK(maxErr < 1e-5, "4 speakers: each speaker plays its VBAP mix of L and R (max error %g)", maxErr);
    CHECK(gl[2] == 0.0f && gl[3] == 0.0f, "front sources stay off the rear speakers");
    dl_render_destroy(r);
}

static void test_master(void) {
    const float az[2] = { -30.0f, 30.0f };
    DLRender *r = make_render(2, az);
    if (r == NULL) { CHECK(0, "render create"); return; }
    dl_render_set_master(r, 0.5f);
    make_input(N_FRAMES);
    dl_render_capture(r, g_in, N_FRAMES);
    pull_all(r, 0, N_FRAMES);
    double maxErr = 0.0;
    for (uint32_t f = 0; f < N_FRAMES; f++) {
        const double err = fabs(g_out[2 * f] - 0.5 * g_in[2 * f]);
        if (err > maxErr) maxErr = err;
    }
    CHECK(maxErr < 1e-6, "master 0.5 halves the output from the first cycle (max error %g)", maxErr);
    pull_all(r, 1, N_FRAMES);
    // Change to 0.25: ramps (30 ms), then settles.
    dl_render_set_master(r, 0.25f);
    make_input(4096);
    for (int k = 0; k < 4; k++) {
        dl_render_capture(r, g_in, 4096);
        dl_ring_read(&r->rings[1], NULL, 4096);
        pull_all(r, 0, 4096);
    }
    maxErr = 0.0;
    for (uint32_t f = 2048; f < 4096; f++) {
        const double err = fabs(g_out[2 * f] - 0.25 * g_in[2 * f]);
        if (err > maxErr) maxErr = err;
    }
    CHECK(maxErr < 1e-6, "master 0.25 settles after its ramp (max error %g)", maxErr);
    dl_render_destroy(r);
}

static void test_absent(void) {
    // 3 speakers, the centre one absent: L and R still land exactly on the
    // speakers at -30 and +30 and the absent one is never fed.
    const float az[3] = { -30.0f, 30.0f, 0.0f };
    DLRender *r = make_render(3, az);
    if (r == NULL) { CHECK(0, "render create"); return; }
    domine_surround_set_surround_level(r->kernel, 0.0f);
    dl_render_set_present(r, 2, 0);
    make_input(N_FRAMES);
    dl_render_capture(r, g_in, N_FRAMES);
    CHECK(dl_ring_fill(&r->rings[2]) == 0, "absent speaker's ring is not fed");
    pull_all(r, 2, N_FRAMES);
    int nonzero = 0;
    for (uint32_t f = 0; f < 2 * N_FRAMES; f++) if (g_out[f] != 0.0f) nonzero++;
    CHECK(nonzero == 0, "absent speaker plays silence");
    double maxErr = 0.0;
    pull_all(r, 0, N_FRAMES);
    for (uint32_t f = 0; f < N_FRAMES; f++) maxErr = fmax(maxErr, fabs(g_out[2 * f] - g_in[2 * f]));
    pull_all(r, 1, N_FRAMES);
    for (uint32_t f = 0; f < N_FRAMES; f++) maxErr = fmax(maxErr, fabs(g_out[2 * f + 1] - g_in[2 * f + 1]));
    CHECK(maxErr < 1e-6, "remaining speakers play L and R (max error %g)", maxErr);
    dl_render_destroy(r);

    // Mono fallback: 2 speakers, only the right one present -> (L + R) / 2.
    const float az2[2] = { -30.0f, 30.0f };
    r = make_render(2, az2);
    if (r == NULL) { CHECK(0, "render create"); return; }
    dl_render_set_present(r, 0, 0);
    CHECK(atomic_load(&r->mono) == 1, "mono fallback selects the remaining speaker");
    dl_render_capture(r, g_in, N_FRAMES);
    CHECK(dl_ring_fill(&r->rings[0]) == 0, "lost speaker is not fed");
    pull_all(r, 1, N_FRAMES);
    maxErr = 0.0;
    for (uint32_t f = 0; f < N_FRAMES; f++) {
        const double want = (g_in[2 * f] + g_in[2 * f + 1]) * 0.5;
        maxErr = fmax(maxErr, fabs(g_out[2 * f] - want));
        maxErr = fmax(maxErr, fabs(g_out[2 * f + 1] - want));
    }
    CHECK(maxErr < 1e-6, "mono fallback plays (L + R) / 2 on both channels (max error %g)", maxErr);
    // The speaker comes back: stereo again.
    dl_render_set_present(r, 0, 1);
    CHECK(atomic_load(&r->mono) == DL_NO_SPEAKER, "both present again leaves mono fallback");
    dl_render_destroy(r);
}

static void test_click(void) {
    const float az[2] = { -30.0f, 30.0f };
    DLRender *r = make_render(2, az);
    if (r == NULL) { CHECK(0, "render create"); return; }
    dl_render_set_manual_delay(r, 1, 10.0f);   // 480 frames
    dl_render_set_click_test(r, 1);
    const uint32_t frames = 4096;
    dl_render_capture(r, NULL, frames);
    const uint32_t L = 1920, N = 96, D = 480;  // fade, click length, delay at 48 kHz
    for (uint32_t s = 0; s < 2; s++) {
        pull_all(r, s, frames);
        int bad = 0;
        const uint32_t start = L + (s == 1 ? D : 0);
        for (uint32_t f = 0; f < frames; f++) {
            const float want = (f >= start && f < start + N) ? dl_click_sample(f - start, 48000.0) : 0.0f;
            if (g_out[2 * f] != want || g_out[2 * f + 1] != want) bad++;
        }
        CHECK(bad == 0, "click test: speaker %u clicks at frame %u (%d bad)", s + 1, start, bad);
    }
    CHECK(dl_click_sample(N / 2, 48000.0) != 0.0f && dl_click_sample(N, 48000.0) == 0.0f, "click is 2 ms long");
    dl_render_destroy(r);
}

static void test_tone(void) {
    const float az[2] = { -30.0f, 30.0f };
    DLRender *r = make_render(2, az);
    if (r == NULL) { CHECK(0, "render create"); return; }
    dl_render_set_test_tone(r, 0);
    const uint32_t frames = 4096, L = 1920;
    make_input(frames);
    dl_render_capture(r, g_in, frames);
    pull_all(r, 0, frames);
    double maxErr = 0.0;
    for (uint32_t f = 0; f < frames; f++) {
        const double e = f < L ? (double)f / L : 1.0;
        const double want = (double)(float)domine_chime_sample((double)f / 48000.0) * (float)e
                          + (double)g_in[2 * f] * (1.0 - e);
        maxErr = fmax(maxErr, fabs(g_out[2 * f] - want));
        maxErr = fmax(maxErr, fabs(g_out[2 * f + 1] - want));
    }
    CHECK(maxErr < 1e-5, "test tone: chime fades in on speaker 1 over 40 ms (max error %g)", maxErr);
    pull_all(r, 1, frames);
    maxErr = 0.0;
    for (uint32_t f = L; f < frames; f++) maxErr = fmax(maxErr, fabs(g_out[2 * f]));
    CHECK(maxErr == 0.0, "test tone: other speaker is silent once faded");
    dl_render_destroy(r);
}

// ---------------------------------------------------------------- engine

static void test_json(void) {
    char name[64];
    CHECK(dl_json_name("{ \"name\": \"alsa_output.usb\" }", name, sizeof name) && strcmp(name, "alsa_output.usb") == 0,
          "parses default sink JSON");
    CHECK(dl_json_name("{\"name\":\"bluez_output.AA_BB.1\"}", name, sizeof name) && strcmp(name, "bluez_output.AA_BB.1") == 0,
          "parses compact JSON");
    CHECK(!dl_json_name("{ \"other\": 1 }", name, sizeof name) && name[0] == '\0', "no name");
    CHECK(!dl_json_name(NULL, name, sizeof name), "NULL json");
}

static void test_engine_no_daemon(void) {
    char dir[] = "/tmp/domine-selftest-XXXXXX";
    if (mkdtemp(dir) == NULL) { CHECK(0, "mkdtemp"); return; }
    setenv("XDG_RUNTIME_DIR", dir, 1);
    setenv("PIPEWIRE_RUNTIME_DIR", dir, 1);
    setenv("PIPEWIRE_REMOTE", "domine-selftest-no-such-daemon", 1);
    char err[256] = "unset";
    DLEngine *e = dl_engine_create(err, sizeof err);
    CHECK(e == NULL, "create without a daemon returns NULL");
    CHECK(err[0] != '\0' && strcmp(err, "unset") != 0, "create without a daemon explains why");
    printf("  (no daemon) dl_engine_create: %s\n", err);
    if (e != NULL) dl_engine_destroy(e);
    // NULL-safety of the public API.
    CHECK(dl_engine_state(NULL) == DL_ERROR, "state of NULL engine");
    CHECK(dl_engine_sinks(NULL, NULL, 0) == 0, "sinks of NULL engine");
    CHECK(dl_engine_peak(NULL, 0) == 0.0f, "peak of NULL engine");
    rmdir(dir);
}

int main(void) {
    test_ring_basic();
    test_ring_threads();
    test_render_two();
    test_render_four();
    test_master();
    test_absent();
    test_click();
    test_tone();
    test_json();
    test_engine_no_daemon();
    printf("selftest: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
