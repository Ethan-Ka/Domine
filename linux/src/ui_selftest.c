// Domine for Linux: `domine --self-test`. Checks the pure UI logic (stage
// geometry, snapping, presets, readouts, sink labels, effects mapping,
// settings keys and a settings round trip) without opening a window.
#include "ui_selftest.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "settings.h"
#include "ui_geometry.h"
#include "ui_logic.h"
#include "ui_sinks.h"

static int gFailures;
static int gChecks;

#define CHECK(cond) check((cond), #cond, __FILE__, __LINE__)
static void check(int ok, const char *what, const char *file, int line)
{
    gChecks++;
    if (!ok) {
        gFailures++;
        fprintf(stderr, "FAIL %s:%d: %s\n", file, line, what);
    }
}

static int near(double a, double b, double eps)
{
    return fabs(a - b) <= eps;
}

static void check_str(const char *got, const char *want, const char *file, int line)
{
    gChecks++;
    if (strcmp(got, want) != 0) {
        gFailures++;
        fprintf(stderr, "FAIL %s:%d: got \"%s\", want \"%s\"\n", file, line, got, want);
    }
}
#define CHECK_STR(got, want) check_str((got), (want), __FILE__, __LINE__)

static void test_wrap_snap(void)
{
    CHECK(near(dl_geom_wrap(0), 0, 1e-6));
    CHECK(near(dl_geom_wrap(180), 180, 1e-6));
    CHECK(near(dl_geom_wrap(-180), 180, 1e-6));
    CHECK(near(dl_geom_wrap(190), -170, 1e-4));
    CHECK(near(dl_geom_wrap(-190), 170, 1e-4));
    CHECK(near(dl_geom_wrap(720 + 30), 30, 1e-4));
    CHECK(near(dl_geom_wrap(NAN), 0, 0));
    CHECK(near(dl_geom_snap(32.4f), 30, 1e-6));
    CHECK(near(dl_geom_snap(32.6f), 35, 1e-6));
    CHECK(near(dl_geom_snap(-2.4f), 0, 1e-6));
    CHECK(near(dl_geom_snap(178.0f), 180, 1e-6));
    CHECK(near(dl_geom_snap(-178.0f), 180, 1e-6));
    CHECK(near(dl_geom_clamp_distance(0.1f), DL_DISTANCE_MIN, 1e-6));
    CHECK(near(dl_geom_clamp_distance(50.0f), DL_DISTANCE_MAX, 1e-6));
}

static void test_mapping(void)
{
    DLStageFrame f = dl_geom_frame(720, 400, 150, 70, 6);
    CHECK(near(f.cx, 360, 1e-9) && near(f.cy, 200, 1e-9));
    CHECK(near(f.outer, 200 - 35 - 6, 1e-9));
    CHECK(near(dl_geom_distance_to_radius(&f, DL_DISTANCE_MIN), f.inner, 1e-9));
    CHECK(near(dl_geom_distance_to_radius(&f, DL_DISTANCE_MAX), f.outer, 1e-9));
    CHECK(near(dl_geom_distance_to_radius(&f, 100.0f), f.outer, 1e-9));
    // Front is up, right is +x, behind is down.
    double x, y;
    dl_geom_to_point(&f, 0, 2, &x, &y);
    CHECK(near(x, f.cx, 1e-9) && y < f.cy);
    dl_geom_to_point(&f, 90, 2, &x, &y);
    CHECK(x > f.cx && near(y, f.cy, 1e-6));
    dl_geom_to_point(&f, -90, 2, &x, &y);
    CHECK(x < f.cx && near(y, f.cy, 1e-6));
    dl_geom_to_point(&f, 180, 2, &x, &y);
    CHECK(near(x, f.cx, 1e-6) && y > f.cy);
    // Round trips.
    const float az[] = { -30, 30, 0, 110, -110, 180, -135, 45 };
    const float dist[] = { 0.5f, 1, 2, 3.5f, 7, 10, 1.2f, 4 };
    for (size_t i = 0; i < G_N_ELEMENTS(az); i++) {
        float a, d;
        dl_geom_to_point(&f, az[i], dist[i], &x, &y);
        dl_geom_from_point(&f, x, y, &a, &d);
        CHECK(near(dl_geom_wrap(a - az[i]), 0, 1e-3));
        CHECK(near(d, dist[i], 1e-3));
    }
    float a, d;
    dl_geom_from_point(&f, f.cx, f.cy, &a, &d);
    CHECK(near(a, 0, 0) && near(d, DL_DISTANCE_MIN, 1e-6));
    dl_geom_from_point(&f, f.cx + 1000, f.cy, &a, &d);
    CHECK(near(a, 90, 1e-4) && near(d, DL_DISTANCE_MAX, 1e-4));
}

static void test_presets(void)
{
    float out[16];
    CHECK(dl_geom_preset(DL_PRESET_QUAD, 3, out, 16) == 4);
    CHECK(out[0] == -45 && out[1] == 45 && out[2] == -135 && out[3] == 135);
    CHECK(dl_geom_preset(DL_PRESET_FIVE, 3, out, 16) == 5);
    CHECK(out[0] == -30 && out[1] == 30 && out[2] == 0 && out[3] == -110 && out[4] == 110);
    CHECK(dl_geom_preset(DL_PRESET_SEVEN, 9, out, 16) == 7);
    CHECK(out[3] == -90 && out[4] == 90 && out[5] == -150 && out[6] == 150);
    CHECK(dl_geom_preset(DL_PRESET_RING, 4, out, 16) == 4);
    CHECK(out[0] == 0 && out[1] == 90 && out[2] == 180 && out[3] == -90);
    CHECK(dl_geom_preset(DL_PRESET_RING, 6, out, 16) == 6);
    CHECK(near(out[1], 60, 1e-4) && near(out[5], -60, 1e-4));
    CHECK(dl_geom_preset(DL_PRESET_RING, 1, out, 16) == 3);
    CHECK_STR(dl_geom_preset_name(DL_PRESET_FIVE), "5 Speakers");

    const float two[] = { -30, 30 };
    CHECK(near(dl_geom_gap_azimuth(2, two), 180, 1e-6));
    const float three[] = { -30, 30, 180 };
    float g = dl_geom_gap_azimuth(3, three);
    CHECK(near(g, 105, 1e-6) || near(g, -105, 1e-6));
    CHECK(near(dl_geom_gap_azimuth(0, NULL), 0, 0));
    const float one[] = { 90 };
    CHECK(near(dl_geom_gap_azimuth(1, one), -90, 1e-6));
}

static void test_text(void)
{
    char b[64];
    dl_geom_format_angle(-30, b, sizeof b);
    CHECK_STR(b, "-30°");
    dl_geom_format_angle(45, b, sizeof b);
    CHECK_STR(b, "+45°");
    dl_geom_format_angle(0, b, sizeof b);
    CHECK_STR(b, "0°");
    dl_geom_format_angle(180, b, sizeof b);
    CHECK_STR(b, "180°");

    dl_delay_readout(4, b, sizeof b);
    CHECK_STR(b, "Right +4 ms");
    dl_delay_readout(-12.4f, b, sizeof b);
    CHECK_STR(b, "Left +12 ms");
    dl_delay_readout(0.2f, b, sizeof b);
    CHECK_STR(b, "In sync");
    dl_delay_short(12, b, sizeof b);
    CHECK_STR(b, "+12 ms");
    dl_delay_short(0, b, sizeof b);
    CHECK_STR(b, "0 ms");
    dl_balance_readout(0.2f, b, sizeof b);
    CHECK_STR(b, "Right 20%");
    dl_balance_readout(-0.05f, b, sizeof b);
    CHECK_STR(b, "Left 5%");
    dl_balance_readout(0, b, sizeof b);
    CHECK_STR(b, "Centered");
    dl_orbit_text(0, b, sizeof b);
    CHECK_STR(b, "Off");
    dl_orbit_text(0.25f, b, sizeof b);
    CHECK_STR(b, "0.25/s");
    dl_percent_text(0.7f, b, sizeof b);
    CHECK_STR(b, "70%");

    CHECK_STR(dl_demo_section_name(1), "Roll call");
    CHECK_STR(dl_demo_section_name(2), "Left and right");
    CHECK_STR(dl_demo_section_name(3), "Orbit");
    CHECK_STR(dl_demo_section_name(4), "Swell");
    CHECK_STR(dl_demo_section_name(5), "Drop");
    CHECK_STR(dl_demo_section_name(6), "");

    dl_card_name(DL_MODE_STEREO, 1, b, sizeof b);
    CHECK_STR(b, "Front Right");
    dl_card_name(DL_MODE_SURROUND, 2, b, sizeof b);
    CHECK_STR(b, "Speaker 3");
    char banner[256];
    int missing[3] = { 0, 1, 0 };
    dl_fallback_banner(DL_MODE_STEREO, 2, missing, banner, sizeof banner);
    CHECK_STR(banner, "Front Right disconnected. Front Left plays both sides until it reconnects.");
    int none[3] = { 0, 0, 0 };
    dl_fallback_banner(DL_MODE_SURROUND, 3, none, banner, sizeof banner);
    CHECK_STR(banner, "");
    dl_fallback_banner(DL_MODE_SURROUND, 3, missing, banner, sizeof banner);
    CHECK(g_str_has_prefix(banner, "Speaker 2 disconnected."));
    // No em dash or spaced en dash in any UI string built here.
    CHECK(strstr(banner, "—") == NULL && strstr(banner, " – ") == NULL);
}

static void test_tuning_math(void)
{
    CHECK(near(dl_balance_left_gain(0.25f), 0.75, 1e-6) && near(dl_balance_right_gain(0.25f), 1, 0));
    CHECK(near(dl_balance_right_gain(-1), 0, 1e-6) && near(dl_balance_left_gain(-1), 1, 0));
    float l, r;
    dl_stereo_delays(4, &l, &r);
    CHECK(l == 0 && r == 4);
    dl_stereo_delays(-120, &l, &r);
    CHECK(l == 120 && r == 0);
    dl_stereo_delays(1000, &l, &r);
    CHECK(r == DL_DELAY_LIMIT);
    CHECK(near(dl_volume_to_slider(0.125f), 0.5, 1e-6));
    CHECK(near(dl_slider_to_volume(0.5f), 0.125, 1e-6));
    CHECK(dl_volume_to_slider(0) == 0 && dl_slider_to_volume(1) == 1);
}

static void test_effects(void)
{
    DLEffects fx;
    dl_fx_preset(DL_FX_NIGHT, &fx);
    CHECK(dl_fx_match(&fx) == DL_FX_NIGHT);
    fx.eqDb[2] = 1;
    CHECK(dl_fx_match(&fx) == -1);
    dl_effects_defaults(&fx);
    CHECK(dl_fx_match(&fx) == DL_FX_FLAT);

    dl_fx_preset(DL_FX_BASS_BOOST, &fx);
    DomineEQParams eq;
    DomineBassParams bass;
    dl_fx_eq_params(&fx, &eq);
    dl_fx_bass_params(&fx, &bass);
    CHECK(eq.enabled == 1 && eq.bands[0].freqHz == 80 && eq.bands[0].gainDb == 6 && eq.bands[4].freqHz == 10000);
    CHECK(bass.enabled == 1 && bass.amount == 0.5f && bass.cutoffHz == 120);

    DomineCompressorParams c;
    fx.compOn = 1;
    fx.comp = 1.0f;
    dl_fx_comp_params(&fx, &c);
    CHECK(c.enabled == 1 && near(c.thresholdDb, -30, 1e-5) && near(c.ratio, 4, 1e-5));
    CHECK(near(c.makeupDb, 30 * 0.75 * 0.5, 1e-4) && c.limiterCeilingDb == -1);
    fx.comp = 0;
    dl_fx_comp_params(&fx, &c);
    CHECK(near(c.thresholdDb, -6, 1e-6) && near(c.ratio, 1.5, 1e-6));
}

static void test_sinks(void)
{
    char b[300];
    dl_sink_suffix("bluez_output.AA_BB_CC_DD_EE_FF.1", b, 5);
    CHECK_STR(b, "EEFF");
    dl_sink_suffix("bluez_output.11_22_33_44_55_66.a2dp-sink", b, 5);
    CHECK_STR(b, "SINK");
    dl_sink_suffix("ab", b, 5);
    CHECK_STR(b, "AB");
    DLSink s[3];
    memset(s, 0, sizeof s);
    strcpy(s[0].id, "bluez_output.AA_BB_CC_DD_EE_FF.1");
    strcpy(s[0].label, "JBL Grip");
    strcpy(s[1].id, "bluez_output.11_22_33_44_12_34.1");
    strcpy(s[1].label, "JBL Grip");
    strcpy(s[2].id, "alsa_output.pci-0000_00_1f.3.analog-stereo");
    strcpy(s[2].label, "Built-in Audio");
    dl_sink_display_label(s, 3, 0, b, sizeof b);
    CHECK_STR(b, "JBL Grip (EEFF)");
    dl_sink_display_label(s, 3, 1, b, sizeof b);
    CHECK_STR(b, "JBL Grip (1234)");
    dl_sink_display_label(s, 3, 2, b, sizeof b);
    CHECK_STR(b, "Built-in Audio");
    CHECK(dl_sink_find(s, 3, s[1].id) == 1 && dl_sink_find(s, 3, "x") == -1 && dl_sink_find(s, 3, "") == -1);
}

static void test_settings(void)
{
    const char *ids[] = { "b.sink", "", "a.sink" };
    char *g = dl_settings_set_group(DL_MODE_STEREO, ids, 3);
    CHECK_STR(g, "set stereo a.sink|b.sink");
    g_free(g);
    const char *rev[] = { "a.sink", "b.sink" };
    g = dl_settings_set_group(DL_MODE_SURROUND, rev, 2);
    CHECK_STR(g, "set surround a.sink|b.sink");
    g_free(g);
    const char *empty[] = { "", "" };
    CHECK(dl_settings_set_group(DL_MODE_STEREO, empty, 2) == NULL);
    g = dl_settings_safe_name("a[b]=c\nd");
    CHECK_STR(g, "a_b__c_d");
    g_free(g);

    char *dir = g_dir_make_tmp("domine-selftest-XXXXXX", NULL);
    CHECK(dir != NULL);
    if (!dir) return;
    char *path = g_build_filename(dir, "sub", "settings.ini", NULL);

    DLSettings *s = g_new0(DLSettings, 1);
    dl_settings_defaults(s);
    s->mode = DL_MODE_SURROUND;
    s->master = 0.3f;
    strcpy(s->stereo[0].sp.sinkId, "left.sink");
    strcpy(s->stereo[1].sp.sinkId, "right[x].sink");
    s->stereoDelay = 12;
    s->balance = -0.25f;
    s->stereo[1].fx.eqOn = 1;
    s->stereo[1].fx.eqDb[3] = 4;
    s->count = 4;
    for (uint32_t i = 0; i < 4; i++) {
        g_snprintf(s->cards[i].sp.sinkId, sizeof s->cards[i].sp.sinkId, "sink%u", i);
        s->cards[i].sp.azimuth = -90.0f + 60.0f * (float)i;
        s->cards[i].sp.distance = 1.5f + (float)i;
        s->cards[i].sp.trim = 0.5f;
        s->cards[i].delayMs = (float)(i * 10);
    }
    s->cards[3].fx.compOn = 1;
    s->cards[3].fx.comp = 0.4f;
    s->width = 45;
    s->orbit = 0.5f;
    s->rotation = -20;
    s->keepRunning = 1;
    s->roomCount = 1;
    strcpy(s->rooms[0].name, "Patio");
    s->rooms[0].mode = DL_MODE_SURROUND;
    s->rooms[0].count = 2;
    strcpy(s->rooms[0].sinks[0], "sink0");
    strcpy(s->rooms[0].sinks[1], "sink1");
    s->appCount = 1;
    strcpy(s->apps[0].key, "zoom");
    strcpy(s->apps[0].label, "Zoom");
    s->apps[0].excluded = 1;

    GKeyFile *kf = g_key_file_new();
    dl_settings_to_keyfile(s, kf);
    // Also keep the stereo set's record.
    s->mode = DL_MODE_STEREO;
    dl_settings_store_set(s, kf);
    s->mode = DL_MODE_SURROUND;
    CHECK(dl_settings_save_file(kf, path) == 0);
    g_key_file_free(kf);

    DLSettings *t = g_new0(DLSettings, 1);
    dl_settings_defaults(t);
    kf = g_key_file_new();
    CHECK(dl_settings_load_file(kf, path) == 0);
    dl_settings_from_keyfile(t, kf);
    CHECK(t->mode == DL_MODE_SURROUND && near(t->master, 0.3, 1e-6));
    CHECK_STR(t->stereo[1].sp.sinkId, "right[x].sink");
    CHECK(near(t->stereoDelay, 12, 1e-6) && near(t->balance, -0.25, 1e-6));
    CHECK(t->stereo[1].fx.eqOn && near(t->stereo[1].fx.eqDb[3], 4, 1e-6));
    CHECK(t->count == 4 && near(t->cards[2].sp.azimuth, 30, 1e-5) && near(t->cards[3].sp.distance, 4.5, 1e-5));
    CHECK(near(t->cards[3].delayMs, 30, 1e-6) && t->cards[3].fx.compOn && near(t->cards[3].fx.comp, 0.4, 1e-6));
    CHECK(near(t->width, 45, 1e-6) && near(t->orbit, 0.5, 1e-6) && near(t->rotation, -20, 1e-6));
    CHECK(t->keepRunning && t->roomCount == 1 && t->rooms[0].count == 2);
    CHECK_STR(t->rooms[0].name, "Patio");
    CHECK(t->appCount == 1 && t->apps[0].excluded);
    CHECK_STR(t->apps[0].key, "zoom");

    // Per-set records: the swapped stereo pair restores the same physical tuning.
    t->mode = DL_MODE_STEREO;
    strcpy(t->stereo[0].sp.sinkId, "right[x].sink");
    strcpy(t->stereo[1].sp.sinkId, "left.sink");
    t->stereoDelay = 0;
    t->balance = 0;
    dl_effects_defaults(&t->stereo[0].fx);
    CHECK(dl_settings_restore_set(t, kf) == 1);
    CHECK(near(t->stereoDelay, -12, 1e-5) && near(t->balance, 0.25, 1e-5));
    CHECK(t->stereo[0].fx.eqOn && near(t->stereo[0].fx.eqDb[3], 4, 1e-6));
    // Surround set restores positions even with the cards in another order.
    t->mode = DL_MODE_SURROUND;
    DLCard tmp = t->cards[0];
    t->cards[0] = t->cards[3];
    t->cards[3] = tmp;
    t->cards[0].sp.azimuth = 0;
    t->cards[0].delayMs = 0;
    CHECK(dl_settings_restore_set(t, kf) == 1);
    CHECK_STR(t->cards[0].sp.sinkId, "sink3");
    CHECK(near(t->cards[0].sp.azimuth, 90, 1e-5) && near(t->cards[0].delayMs, 30, 1e-5));
    // An unknown set restores nothing.
    strcpy(t->cards[1].sp.sinkId, "other");
    CHECK(dl_settings_restore_set(t, kf) == 0);

    // Sanitize clamps.
    t->master = 7;
    t->count = 1;
    t->width = 200;
    t->cards[0].sp.distance = 0.01f;
    dl_settings_sanitize(t);
    CHECK(t->master == 1 && t->count == 3 && t->width == 90 && near(t->cards[0].sp.distance, DL_DISTANCE_MIN, 1e-6));

    g_key_file_free(kf);
    g_free(s);
    g_free(t);
    g_remove(path);
    char *sub = g_path_get_dirname(path);
    g_rmdir(sub);
    g_rmdir(dir);
    g_free(sub);
    g_free(path);
    g_free(dir);
}

int dl_self_test(void)
{
    test_wrap_snap();
    test_mapping();
    test_presets();
    test_text();
    test_tuning_math();
    test_effects();
    test_sinks();
    test_settings();
    printf("domine self-test: %d checks, %d failed\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
