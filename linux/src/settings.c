// Domine for Linux: settings persistence. See settings.h.
#include "settings.h"

#include <glib/gstdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "ui_geometry.h"
#include "ui_logic.h"

static float clampf(float v, float lo, float hi, float fallback)
{
    if (!isfinite(v)) return fallback;
    return v < lo ? lo : (v > hi ? hi : v);
}

void dl_effects_defaults(DLEffects *fx)
{
    memset(fx, 0, sizeof *fx);
}

static void card_init(DLCard *c, float azimuth)
{
    memset(c, 0, sizeof *c);
    c->sp.azimuth = azimuth;
    c->sp.distance = DL_DISTANCE_DEFAULT;
    c->sp.trim = 1.0f;
    dl_effects_defaults(&c->fx);
}

void dl_settings_defaults(DLSettings *s)
{
    memset(s, 0, sizeof *s);
    s->mode = DL_MODE_STEREO;
    s->master = 0.512f;   // 80% on the slider
    card_init(&s->stereo[0], -DL_STEREO_AZIMUTH);
    card_init(&s->stereo[1], DL_STEREO_AZIMUTH);
    s->stereoLink = 1;
    s->count = DL_SURROUND_MIN_SPEAKERS;
    card_init(&s->cards[0], -DL_STEREO_AZIMUTH);
    card_init(&s->cards[1], DL_STEREO_AZIMUTH);
    card_init(&s->cards[2], 180.0f);
    s->surroundLink = 1;
    s->width = 30.0f;
    s->surroundLevel = 0.7f;
    s->orbit = 0.0f;
    s->rotation = 0.0f;
    s->spatial = 0.6f;
    s->roomMs = 15.0f;
    s->currentRoom = -1;
}

static void sanitize_fx(DLEffects *fx)
{
    fx->eqOn = fx->eqOn != 0;
    fx->bassOn = fx->bassOn != 0;
    fx->compOn = fx->compOn != 0;
    for (int i = 0; i < DL_EQ_BANDS; i++) fx->eqDb[i] = roundf(clampf(fx->eqDb[i], -12.0f, 12.0f, 0.0f));
    fx->bass = clampf(fx->bass, 0.0f, 1.0f, 0.0f);
    fx->comp = clampf(fx->comp, 0.0f, 1.0f, 0.0f);
}

static void sanitize_card(DLCard *c)
{
    c->sp.sinkId[sizeof c->sp.sinkId - 1] = '\0';
    c->sp.azimuth = dl_geom_wrap(c->sp.azimuth);
    c->sp.distance = dl_geom_clamp_distance(c->sp.distance);
    c->sp.trim = clampf(c->sp.trim, 0.0f, 1.0f, 1.0f);
    c->delayMs = clampf(c->delayMs, 0.0f, DL_DELAY_LIMIT, 0.0f);
    sanitize_fx(&c->fx);
}

void dl_settings_sanitize(DLSettings *s)
{
    if (s->mode != DL_MODE_SURROUND) s->mode = DL_MODE_STEREO;
    s->master = clampf(s->master, 0.0f, 1.0f, 0.512f);
    s->stereoDelay = clampf(s->stereoDelay, -DL_DELAY_LIMIT, DL_DELAY_LIMIT, 0.0f);
    s->stereoExtended = s->stereoExtended != 0;
    if (fabsf(s->stereoDelay) > DL_STEREO_DELAY_NORMAL) s->stereoExtended = 1;
    s->balance = clampf(s->balance, -1.0f, 1.0f, 0.0f);
    s->width = clampf(s->width, 10.0f, 90.0f, 30.0f);
    s->surroundLevel = clampf(s->surroundLevel, 0.0f, 1.0f, 0.7f);
    s->orbit = clampf(s->orbit, 0.0f, 2.0f, 0.0f);
    s->rotation = clampf(s->rotation, -180.0f, 180.0f, 0.0f);
    s->spatial = clampf(s->spatial, 0.0f, 1.0f, 0.6f);
    s->roomMs = clampf(s->roomMs, 5.0f, 30.0f, 15.0f);
    for (int i = 0; i < 2; i++) {
        sanitize_card(&s->stereo[i]);
        s->stereo[i].sp.azimuth = i == 0 ? -DL_STEREO_AZIMUTH : DL_STEREO_AZIMUTH;
        s->stereo[i].sp.distance = DL_DISTANCE_DEFAULT;
        s->stereo[i].sp.trim = 1.0f;
        s->stereo[i].delayMs = 0.0f;
    }
    if (s->count > DL_MAX_SPEAKERS) s->count = DL_MAX_SPEAKERS;
    while (s->count < DL_SURROUND_MIN_SPEAKERS) {
        float az[DL_MAX_SPEAKERS];
        for (uint32_t i = 0; i < s->count; i++) az[i] = s->cards[i].sp.azimuth;
        card_init(&s->cards[s->count], dl_geom_gap_azimuth(s->count, az));
        s->count++;
    }
    for (uint32_t i = 0; i < s->count; i++) sanitize_card(&s->cards[i]);
    if (s->roomCount > DL_MAX_ROOMS) s->roomCount = DL_MAX_ROOMS;
    if (s->currentRoom < -1 || s->currentRoom >= (int)s->roomCount) s->currentRoom = -1;
    if (s->appCount > DL_MAX_APP_PREFS) s->appCount = DL_MAX_APP_PREFS;
    for (uint32_t i = 0; i < s->appCount; i++)
        s->apps[i].volume = clampf(s->apps[i].volume, 0.0f, 1.0f, 1.0f);
}

char *dl_settings_default_path(void)
{
    return g_build_filename(g_get_user_config_dir(), "domine", "settings.ini", NULL);
}

char *dl_settings_safe_name(const char *raw)
{
    char *out = g_strdup(raw ? raw : "");
    for (char *p = out; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c < 0x20 || c == 0x7f || c == '[' || c == ']' || c == '=') *p = '_';
    }
    return out;
}

static int cmp_str(const void *a, const void *b)
{
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

char *dl_settings_set_group(DLMode mode, const char *const *ids, uint32_t n)
{
    const char *list[DL_MAX_SPEAKERS];
    uint32_t k = 0;
    for (uint32_t i = 0; i < n && k < DL_MAX_SPEAKERS; i++)
        if (ids[i] && ids[i][0]) list[k++] = ids[i];
    if (k == 0) return NULL;
    qsort(list, k, sizeof list[0], cmp_str);
    GString *g = g_string_new(mode == DL_MODE_SURROUND ? "set surround " : "set stereo ");
    for (uint32_t i = 0; i < k; i++) {
        if (i) g_string_append_c(g, '|');
        g_string_append(g, list[i]);
    }
    char *raw = g_string_free(g, FALSE);
    char *safe = dl_settings_safe_name(raw);
    g_free(raw);
    return safe;
}

// ---- Key file helpers ----

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

static int get_bool(GKeyFile *kf, const char *group, const char *key, int fallback)
{
    GError *err = NULL;
    gboolean v = g_key_file_get_boolean(kf, group, key, &err);
    if (err) {
        g_error_free(err);
        return fallback;
    }
    return v ? 1 : 0;
}

static int get_int(GKeyFile *kf, const char *group, const char *key, int fallback)
{
    GError *err = NULL;
    int v = g_key_file_get_integer(kf, group, key, &err);
    if (err) {
        g_error_free(err);
        return fallback;
    }
    return v;
}

static void get_str(GKeyFile *kf, const char *group, const char *key, char *out, size_t len)
{
    char *v = g_key_file_get_string(kf, group, key, NULL);
    if (v) {
        g_strlcpy(out, v, len);
        g_free(v);
    }
}

static char *pkey(const char *prefix, const char *key)
{
    return prefix && prefix[0] ? g_strconcat(prefix, ".", key, NULL) : g_strdup(key);
}

static void read_fx(GKeyFile *kf, const char *group, const char *prefix, DLEffects *fx)
{
    char *k;
    k = pkey(prefix, "eq"); fx->eqOn = get_bool(kf, group, k, fx->eqOn); g_free(k);
    for (int i = 0; i < DL_EQ_BANDS; i++) {
        char name[16];
        g_snprintf(name, sizeof name, "eq%d", i);
        k = pkey(prefix, name); fx->eqDb[i] = get_float(kf, group, k, fx->eqDb[i]); g_free(k);
    }
    k = pkey(prefix, "bass_on"); fx->bassOn = get_bool(kf, group, k, fx->bassOn); g_free(k);
    k = pkey(prefix, "bass"); fx->bass = get_float(kf, group, k, fx->bass); g_free(k);
    k = pkey(prefix, "comp_on"); fx->compOn = get_bool(kf, group, k, fx->compOn); g_free(k);
    k = pkey(prefix, "comp"); fx->comp = get_float(kf, group, k, fx->comp); g_free(k);
}

static void write_fx(GKeyFile *kf, const char *group, const char *prefix, const DLEffects *fx)
{
    char *k;
    k = pkey(prefix, "eq"); g_key_file_set_boolean(kf, group, k, fx->eqOn); g_free(k);
    for (int i = 0; i < DL_EQ_BANDS; i++) {
        char name[16];
        g_snprintf(name, sizeof name, "eq%d", i);
        k = pkey(prefix, name); g_key_file_set_double(kf, group, k, fx->eqDb[i]); g_free(k);
    }
    k = pkey(prefix, "bass_on"); g_key_file_set_boolean(kf, group, k, fx->bassOn); g_free(k);
    k = pkey(prefix, "bass"); g_key_file_set_double(kf, group, k, fx->bass); g_free(k);
    k = pkey(prefix, "comp_on"); g_key_file_set_boolean(kf, group, k, fx->compOn); g_free(k);
    k = pkey(prefix, "comp"); g_key_file_set_double(kf, group, k, fx->comp); g_free(k);
}

static void remove_groups_with_prefix(GKeyFile *kf, const char *prefix)
{
    gchar **groups = g_key_file_get_groups(kf, NULL);
    for (gchar **g = groups; g && *g; g++)
        if (g_str_has_prefix(*g, prefix)) g_key_file_remove_group(kf, *g, NULL);
    g_strfreev(groups);
}

// ---- Whole settings ----

void dl_settings_from_keyfile(DLSettings *s, GKeyFile *kf)
{
    char mode[32] = "";
    get_str(kf, "general", "mode", mode, sizeof mode);
    if (mode[0]) s->mode = strcmp(mode, "surround") == 0 ? DL_MODE_SURROUND : DL_MODE_STEREO;
    s->master = get_float(kf, "general", "master", s->master);
    s->startPlaying = get_bool(kf, "general", "start_playing", s->startPlaying);
    s->keepRunning = get_bool(kf, "general", "keep_running", s->keepRunning);
    s->launchAtLogin = get_bool(kf, "general", "launch_at_login", s->launchAtLogin);
    s->welcomeDone = get_bool(kf, "general", "welcome_done", s->welcomeDone);
    s->currentRoom = get_int(kf, "general", "current_room", s->currentRoom);
    get_str(kf, "general", "exclude_sink", s->excludeSinkId, sizeof s->excludeSinkId);

    get_str(kf, "stereo", "left", s->stereo[0].sp.sinkId, sizeof s->stereo[0].sp.sinkId);
    get_str(kf, "stereo", "right", s->stereo[1].sp.sinkId, sizeof s->stereo[1].sp.sinkId);
    s->stereoDelay = get_float(kf, "stereo", "delay", s->stereoDelay);
    s->stereoExtended = get_bool(kf, "stereo", "extended", s->stereoExtended);
    s->balance = get_float(kf, "stereo", "balance", s->balance);
    s->stereoLink = get_bool(kf, "stereo", "link", s->stereoLink);
    read_fx(kf, "stereo", "left", &s->stereo[0].fx);
    read_fx(kf, "stereo", "right", &s->stereo[1].fx);

    s->width = get_float(kf, "surround", "width", s->width);
    s->surroundLevel = get_float(kf, "surround", "level", s->surroundLevel);
    s->orbit = get_float(kf, "surround", "orbit", s->orbit);
    s->rotation = get_float(kf, "surround", "rotation", s->rotation);
    s->spatial = get_float(kf, "surround", "spatial", s->spatial);
    s->roomMs = get_float(kf, "surround", "room", s->roomMs);
    s->surroundLink = get_bool(kf, "surround", "link", s->surroundLink);
    int count = get_int(kf, "surround", "count", -1);
    if (count >= 0) {
        s->count = (uint32_t)count > DL_MAX_SPEAKERS ? DL_MAX_SPEAKERS : (uint32_t)count;
        for (uint32_t i = 0; i < s->count; i++) {
            char group[32];
            g_snprintf(group, sizeof group, "speaker%u", i);
            DLCard *c = &s->cards[i];
            card_init(c, 0.0f);
            get_str(kf, group, "sink", c->sp.sinkId, sizeof c->sp.sinkId);
            c->sp.azimuth = get_float(kf, group, "azimuth", c->sp.azimuth);
            c->sp.distance = get_float(kf, group, "distance", c->sp.distance);
            c->sp.trim = get_float(kf, group, "trim", c->sp.trim);
            c->delayMs = get_float(kf, group, "delay", c->delayMs);
            read_fx(kf, group, NULL, &c->fx);
        }
    }

    int rooms = get_int(kf, "rooms", "count", 0);
    s->roomCount = 0;
    for (int i = 0; i < rooms && s->roomCount < DL_MAX_ROOMS; i++) {
        char group[32];
        g_snprintf(group, sizeof group, "room %d", i);
        if (!g_key_file_has_group(kf, group)) continue;
        DLRoom *r = &s->rooms[s->roomCount++];
        memset(r, 0, sizeof *r);
        get_str(kf, group, "name", r->name, sizeof r->name);
        char m[32] = "";
        get_str(kf, group, "mode", m, sizeof m);
        r->mode = strcmp(m, "surround") == 0 ? DL_MODE_SURROUND : DL_MODE_STEREO;
        get_str(kf, group, "left", r->stereo[0], sizeof r->stereo[0]);
        get_str(kf, group, "right", r->stereo[1], sizeof r->stereo[1]);
        gsize n = 0;
        gchar **list = g_key_file_get_string_list(kf, group, "sinks", &n, NULL);
        for (gsize k = 0; list && k < n && k < DL_MAX_SPEAKERS; k++)
            g_strlcpy(r->sinks[r->count++], list[k], sizeof r->sinks[0]);
        g_strfreev(list);
    }

    gchar **groups = g_key_file_get_groups(kf, NULL);
    s->appCount = 0;
    for (gchar **g = groups; g && *g; g++) {
        if (!g_str_has_prefix(*g, "app ") || s->appCount >= DL_MAX_APP_PREFS) continue;
        DLAppPref *a = &s->apps[s->appCount++];
        memset(a, 0, sizeof *a);
        get_str(kf, *g, "key", a->key, sizeof a->key);
        if (!a->key[0]) g_strlcpy(a->key, *g + 4, sizeof a->key);
        get_str(kf, *g, "label", a->label, sizeof a->label);
        a->excluded = get_bool(kf, *g, "excluded", 0);
        a->hasVolume = g_key_file_has_key(kf, *g, "volume", NULL);
        a->volume = get_float(kf, *g, "volume", 1.0f);
    }
    g_strfreev(groups);
    dl_settings_sanitize(s);
}

void dl_settings_to_keyfile(const DLSettings *s, GKeyFile *kf)
{
    g_key_file_set_string(kf, "general", "mode", s->mode == DL_MODE_SURROUND ? "surround" : "stereo");
    g_key_file_set_double(kf, "general", "master", s->master);
    g_key_file_set_boolean(kf, "general", "start_playing", s->startPlaying);
    g_key_file_set_boolean(kf, "general", "keep_running", s->keepRunning);
    g_key_file_set_boolean(kf, "general", "launch_at_login", s->launchAtLogin);
    g_key_file_set_boolean(kf, "general", "welcome_done", s->welcomeDone);
    g_key_file_set_integer(kf, "general", "current_room", s->currentRoom);
    g_key_file_set_string(kf, "general", "exclude_sink", s->excludeSinkId);

    g_key_file_set_string(kf, "stereo", "left", s->stereo[0].sp.sinkId);
    g_key_file_set_string(kf, "stereo", "right", s->stereo[1].sp.sinkId);
    g_key_file_set_double(kf, "stereo", "delay", s->stereoDelay);
    g_key_file_set_boolean(kf, "stereo", "extended", s->stereoExtended);
    g_key_file_set_double(kf, "stereo", "balance", s->balance);
    g_key_file_set_boolean(kf, "stereo", "link", s->stereoLink);
    write_fx(kf, "stereo", "left", &s->stereo[0].fx);
    write_fx(kf, "stereo", "right", &s->stereo[1].fx);

    g_key_file_set_double(kf, "surround", "width", s->width);
    g_key_file_set_double(kf, "surround", "level", s->surroundLevel);
    g_key_file_set_double(kf, "surround", "orbit", s->orbit);
    g_key_file_set_double(kf, "surround", "rotation", s->rotation);
    g_key_file_set_double(kf, "surround", "spatial", s->spatial);
    g_key_file_set_double(kf, "surround", "room", s->roomMs);
    g_key_file_set_boolean(kf, "surround", "link", s->surroundLink);
    g_key_file_set_integer(kf, "surround", "count", (int)s->count);
    remove_groups_with_prefix(kf, "speaker");
    for (uint32_t i = 0; i < s->count && i < DL_MAX_SPEAKERS; i++) {
        char group[32];
        g_snprintf(group, sizeof group, "speaker%u", i);
        const DLCard *c = &s->cards[i];
        g_key_file_set_string(kf, group, "sink", c->sp.sinkId);
        g_key_file_set_double(kf, group, "azimuth", c->sp.azimuth);
        g_key_file_set_double(kf, group, "distance", c->sp.distance);
        g_key_file_set_double(kf, group, "trim", c->sp.trim);
        g_key_file_set_double(kf, group, "delay", c->delayMs);
        write_fx(kf, group, NULL, &c->fx);
    }

    remove_groups_with_prefix(kf, "room ");
    g_key_file_set_integer(kf, "rooms", "count", (int)s->roomCount);
    for (uint32_t i = 0; i < s->roomCount; i++) {
        const DLRoom *r = &s->rooms[i];
        char group[32];
        g_snprintf(group, sizeof group, "room %u", i);
        g_key_file_set_string(kf, group, "name", r->name);
        g_key_file_set_string(kf, group, "mode", r->mode == DL_MODE_SURROUND ? "surround" : "stereo");
        g_key_file_set_string(kf, group, "left", r->stereo[0]);
        g_key_file_set_string(kf, group, "right", r->stereo[1]);
        const gchar *list[DL_MAX_SPEAKERS];
        for (uint32_t k = 0; k < r->count; k++) list[k] = r->sinks[k];
        g_key_file_set_string_list(kf, group, "sinks", list, r->count);
    }

    remove_groups_with_prefix(kf, "app ");
    for (uint32_t i = 0; i < s->appCount; i++) {
        const DLAppPref *a = &s->apps[i];
        char *safe = dl_settings_safe_name(a->key);
        char *group = g_strconcat("app ", safe, NULL);
        g_key_file_set_string(kf, group, "key", a->key);
        g_key_file_set_string(kf, group, "label", a->label);
        g_key_file_set_boolean(kf, group, "excluded", a->excluded);
        if (a->hasVolume) g_key_file_set_double(kf, group, "volume", a->volume);
        g_free(group);
        g_free(safe);
    }
    dl_settings_store_set(s, kf);
}

// ---- Per speaker set records ----

static char *current_set_group(const DLSettings *s)
{
    const char *ids[DL_MAX_SPEAKERS];
    if (s->mode == DL_MODE_STEREO) {
        ids[0] = s->stereo[0].sp.sinkId;
        ids[1] = s->stereo[1].sp.sinkId;
        return dl_settings_set_group(DL_MODE_STEREO, ids, 2);
    }
    for (uint32_t i = 0; i < s->count; i++) ids[i] = s->cards[i].sp.sinkId;
    return dl_settings_set_group(DL_MODE_SURROUND, ids, s->count);
}

void dl_settings_store_set(const DLSettings *s, GKeyFile *kf)
{
    char *group = current_set_group(s);
    if (!group) return;
    g_key_file_remove_group(kf, group, NULL);
    if (s->mode == DL_MODE_STEREO) {
        float delay[2];
        dl_stereo_delays(s->stereoDelay, &delay[0], &delay[1]);
        float gain[2] = { dl_balance_left_gain(s->balance), dl_balance_right_gain(s->balance) };
        g_key_file_set_boolean(kf, group, "extended", s->stereoExtended);
        g_key_file_set_boolean(kf, group, "link", s->stereoLink);
        for (int i = 0; i < 2; i++) {
            if (!s->stereo[i].sp.sinkId[0]) continue;
            char *id = dl_settings_safe_name(s->stereo[i].sp.sinkId);
            char *k = pkey(id, "delay");
            g_key_file_set_double(kf, group, k, delay[i]);
            g_free(k);
            k = pkey(id, "gain");
            g_key_file_set_double(kf, group, k, gain[i]);
            g_free(k);
            write_fx(kf, group, id, &s->stereo[i].fx);
            g_free(id);
        }
    } else {
        g_key_file_set_boolean(kf, group, "link", s->surroundLink);
        for (uint32_t i = 0; i < s->count; i++) {
            const DLCard *c = &s->cards[i];
            if (!c->sp.sinkId[0]) continue;
            char *id = dl_settings_safe_name(c->sp.sinkId);
            char *k;
            k = pkey(id, "azimuth"); g_key_file_set_double(kf, group, k, c->sp.azimuth); g_free(k);
            k = pkey(id, "distance"); g_key_file_set_double(kf, group, k, c->sp.distance); g_free(k);
            k = pkey(id, "trim"); g_key_file_set_double(kf, group, k, c->sp.trim); g_free(k);
            k = pkey(id, "delay"); g_key_file_set_double(kf, group, k, c->delayMs); g_free(k);
            write_fx(kf, group, id, &c->fx);
            g_free(id);
        }
    }
    g_free(group);
}

int dl_settings_restore_set(DLSettings *s, GKeyFile *kf)
{
    char *group = current_set_group(s);
    if (!group) return 0;
    if (!g_key_file_has_group(kf, group)) {
        g_free(group);
        return 0;
    }
    if (s->mode == DL_MODE_STEREO) {
        float delay[2] = { 0, 0 }, gain[2] = { 1, 1 };
        s->stereoExtended = get_bool(kf, group, "extended", s->stereoExtended);
        s->stereoLink = get_bool(kf, group, "link", s->stereoLink);
        for (int i = 0; i < 2; i++) {
            if (!s->stereo[i].sp.sinkId[0]) continue;
            char *id = dl_settings_safe_name(s->stereo[i].sp.sinkId);
            char *k = pkey(id, "delay");
            delay[i] = get_float(kf, group, k, 0.0f);
            g_free(k);
            k = pkey(id, "gain");
            gain[i] = get_float(kf, group, k, 1.0f);
            g_free(k);
            read_fx(kf, group, id, &s->stereo[i].fx);
            g_free(id);
        }
        s->stereoDelay = delay[1] - delay[0];
        if (gain[0] < 1.0f) s->balance = 1.0f - gain[0];
        else if (gain[1] < 1.0f) s->balance = gain[1] - 1.0f;
        else s->balance = 0.0f;
    } else {
        s->surroundLink = get_bool(kf, group, "link", s->surroundLink);
        for (uint32_t i = 0; i < s->count; i++) {
            DLCard *c = &s->cards[i];
            if (!c->sp.sinkId[0]) continue;
            char *id = dl_settings_safe_name(c->sp.sinkId);
            char *k;
            k = pkey(id, "azimuth"); c->sp.azimuth = get_float(kf, group, k, c->sp.azimuth); g_free(k);
            k = pkey(id, "distance"); c->sp.distance = get_float(kf, group, k, c->sp.distance); g_free(k);
            k = pkey(id, "trim"); c->sp.trim = get_float(kf, group, k, c->sp.trim); g_free(k);
            k = pkey(id, "delay"); c->delayMs = get_float(kf, group, k, c->delayMs); g_free(k);
            read_fx(kf, group, id, &c->fx);
            g_free(id);
        }
    }
    g_free(group);
    dl_settings_sanitize(s);
    return 1;
}

// ---- Files ----

int dl_settings_load_file(GKeyFile *kf, const char *path)
{
    char *own = path ? NULL : dl_settings_default_path();
    int ok = g_key_file_load_from_file(kf, path ? path : own, G_KEY_FILE_KEEP_COMMENTS, NULL);
    g_free(own);
    return ok ? 0 : -1;
}

int dl_settings_save_file(GKeyFile *kf, const char *path)
{
    char *own = path ? NULL : dl_settings_default_path();
    const char *file = path ? path : own;
    int rc = -1;
    char *dir = g_path_get_dirname(file);
    if (g_mkdir_with_parents(dir, 0700) == 0 && g_key_file_save_to_file(kf, file, NULL)) rc = 0;
    g_free(dir);
    g_free(own);
    return rc;
}
