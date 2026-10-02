// Domine for Linux: settings persistence. See settings.h.
#include "settings.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <math.h>
#include <string.h>
#include "ui_geometry.h"

static float clampf(float v, float lo, float hi, float fallback)
{
    if (!isfinite(v)) return fallback;
    return v < lo ? lo : (v > hi ? hi : v);
}

static void speaker_init(DLSpeaker *sp, float azimuth)
{
    memset(sp, 0, sizeof *sp);
    sp->azimuth = azimuth;
    sp->distance = DL_DISTANCE_DEFAULT;
    sp->trim = 1.0f;
}

void dl_settings_defaults(DLSettings *s)
{
    memset(s, 0, sizeof *s);
    s->mode = DL_MODE_STEREO;
    s->master = 0.8f;
    speaker_init(&s->stereo[0], -DL_STEREO_AZIMUTH);
    speaker_init(&s->stereo[1], DL_STEREO_AZIMUTH);
    s->count = DL_SURROUND_MIN_SPEAKERS;
    speaker_init(&s->speakers[0], -DL_STEREO_AZIMUTH);
    speaker_init(&s->speakers[1], DL_STEREO_AZIMUTH);
    speaker_init(&s->speakers[2], 180.0f);
    s->width = 30.0f;
    s->surroundLevel = 0.7f;
    s->orbit = 0.0f;
    s->rotation = 0.0f;
}

static void sanitize_speaker(DLSpeaker *sp)
{
    sp->sinkId[sizeof sp->sinkId - 1] = '\0';
    sp->azimuth = dl_geom_wrap(sp->azimuth);
    sp->distance = dl_geom_clamp_distance(sp->distance);
    sp->trim = clampf(sp->trim, 0.0f, 1.0f, 1.0f);
}

void dl_settings_sanitize(DLSettings *s)
{
    if (s->mode != DL_MODE_SURROUND) s->mode = DL_MODE_STEREO;
    s->master = clampf(s->master, 0.0f, 1.0f, 0.8f);
    s->width = clampf(s->width, 10.0f, 90.0f, 30.0f);
    s->surroundLevel = clampf(s->surroundLevel, 0.0f, 1.0f, 0.7f);
    s->orbit = clampf(s->orbit, 0.0f, 2.0f, 0.0f);
    s->rotation = clampf(s->rotation, -180.0f, 180.0f, 0.0f);
    for (int i = 0; i < 2; i++) {
        sanitize_speaker(&s->stereo[i]);
        s->stereo[i].azimuth = i == 0 ? -DL_STEREO_AZIMUTH : DL_STEREO_AZIMUTH;
        s->stereo[i].distance = DL_DISTANCE_DEFAULT;
    }
    if (s->count > DL_MAX_SPEAKERS) s->count = DL_MAX_SPEAKERS;
    while (s->count < DL_SURROUND_MIN_SPEAKERS) {
        float az[DL_MAX_SPEAKERS];
        for (uint32_t i = 0; i < s->count; i++) az[i] = s->speakers[i].azimuth;
        speaker_init(&s->speakers[s->count], dl_geom_gap_azimuth(s->count, az));
        s->count++;
    }
    for (uint32_t i = 0; i < s->count; i++) sanitize_speaker(&s->speakers[i]);
}

char *dl_settings_default_path(void)
{
    return g_build_filename(g_get_user_config_dir(), "domine", "settings.ini", NULL);
}

static float get_float(GKeyFile *kf, const char *group, const char *key, float fallback)
{
    GError *err = NULL;
    double v = g_key_file_get_double(kf, group, key, &err);
    if (err) {
        g_error_free(err);
        return fallback;
    }
    return (float)v;
}

static void get_sink(GKeyFile *kf, const char *group, const char *key, DLSpeaker *sp)
{
    char *v = g_key_file_get_string(kf, group, key, NULL);
    if (v) {
        g_strlcpy(sp->sinkId, v, sizeof sp->sinkId);
        g_free(v);
    }
}

int dl_settings_load(DLSettings *s, const char *path)
{
    char *own = path ? NULL : dl_settings_default_path();
    GKeyFile *kf = g_key_file_new();
    int ok = g_key_file_load_from_file(kf, path ? path : own, G_KEY_FILE_NONE, NULL);
    g_free(own);
    if (!ok) {
        g_key_file_free(kf);
        return -1;
    }

    char *mode = g_key_file_get_string(kf, "general", "mode", NULL);
    if (mode) {
        s->mode = strcmp(mode, "surround") == 0 ? DL_MODE_SURROUND : DL_MODE_STEREO;
        g_free(mode);
    }
    s->master = get_float(kf, "general", "master", s->master);
    s->width = get_float(kf, "surround", "width", s->width);
    s->surroundLevel = get_float(kf, "surround", "level", s->surroundLevel);
    s->orbit = get_float(kf, "surround", "orbit", s->orbit);
    s->rotation = get_float(kf, "surround", "rotation", s->rotation);

    get_sink(kf, "stereo", "left", &s->stereo[0]);
    get_sink(kf, "stereo", "right", &s->stereo[1]);
    s->stereo[0].trim = get_float(kf, "stereo", "left_trim", s->stereo[0].trim);
    s->stereo[1].trim = get_float(kf, "stereo", "right_trim", s->stereo[1].trim);

    GError *err = NULL;
    int count = g_key_file_get_integer(kf, "surround", "count", &err);
    if (!err && count >= 0) {
        s->count = (uint32_t)count > DL_MAX_SPEAKERS ? DL_MAX_SPEAKERS : (uint32_t)count;
        for (uint32_t i = 0; i < s->count; i++) {
            char group[32];
            g_snprintf(group, sizeof group, "speaker%u", i);
            DLSpeaker *sp = &s->speakers[i];
            speaker_init(sp, 0.0f);
            get_sink(kf, group, "sink", sp);
            sp->azimuth = get_float(kf, group, "azimuth", sp->azimuth);
            sp->distance = get_float(kf, group, "distance", sp->distance);
            sp->trim = get_float(kf, group, "trim", sp->trim);
        }
    }
    g_clear_error(&err);
    g_key_file_free(kf);
    dl_settings_sanitize(s);
    return 0;
}

int dl_settings_save(const DLSettings *s, const char *path)
{
    char *own = path ? NULL : dl_settings_default_path();
    const char *file = path ? path : own;
    GKeyFile *kf = g_key_file_new();

    g_key_file_set_string(kf, "general", "mode", s->mode == DL_MODE_SURROUND ? "surround" : "stereo");
    g_key_file_set_double(kf, "general", "master", s->master);
    g_key_file_set_string(kf, "stereo", "left", s->stereo[0].sinkId);
    g_key_file_set_string(kf, "stereo", "right", s->stereo[1].sinkId);
    g_key_file_set_double(kf, "stereo", "left_trim", s->stereo[0].trim);
    g_key_file_set_double(kf, "stereo", "right_trim", s->stereo[1].trim);
    g_key_file_set_double(kf, "surround", "width", s->width);
    g_key_file_set_double(kf, "surround", "level", s->surroundLevel);
    g_key_file_set_double(kf, "surround", "orbit", s->orbit);
    g_key_file_set_double(kf, "surround", "rotation", s->rotation);
    g_key_file_set_integer(kf, "surround", "count", (int)s->count);
    for (uint32_t i = 0; i < s->count && i < DL_MAX_SPEAKERS; i++) {
        char group[32];
        g_snprintf(group, sizeof group, "speaker%u", i);
        const DLSpeaker *sp = &s->speakers[i];
        g_key_file_set_string(kf, group, "sink", sp->sinkId);
        g_key_file_set_double(kf, group, "azimuth", sp->azimuth);
        g_key_file_set_double(kf, group, "distance", sp->distance);
        g_key_file_set_double(kf, group, "trim", sp->trim);
    }

    int rc = -1;
    char *dir = g_path_get_dirname(file);
    if (g_mkdir_with_parents(dir, 0700) == 0 && g_key_file_save_to_file(kf, file, NULL))
        rc = 0;
    g_free(dir);
    g_key_file_free(kf);
    g_free(own);
    return rc;
}
