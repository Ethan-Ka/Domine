// Domine for Linux: application state and everything that talks to the
// engine. See ui_app.h.
#include "ui_app.h"

#include <math.h>
#include <string.h>
#include "ui_geometry.h"
#include "ui_logic.h"
#include "ui_sinks.h"

#define DL_TICK_MS 33
#define DL_SAVE_DELAY_MS 400
#define DL_TEST_TONE_MS 1500

static void on_engine_change(void *ctx);
static void apply_app_prefs(DLUi *ui);

DLUi *dl_ui_new(GtkApplication *app, const char *settingsPath)
{
    DLUi *ui = g_new0(DLUi, 1);
    ui->gtkApp = app;
    ui->testCard = -1;
    ui->settingsPath = settingsPath ? g_strdup(settingsPath) : NULL;
    ui->s = g_new0(DLSettings, 1);
    dl_settings_defaults(ui->s);
    ui->kf = g_key_file_new();
    if (dl_settings_load_file(ui->kf, ui->settingsPath) == 0) dl_settings_from_keyfile(ui->s, ui->kf);
    dl_settings_sanitize(ui->s);
    ui->appsApplied = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);

    ui->engine = dl_engine_create(ui->engineError, sizeof ui->engineError);
    if (!ui->engine && !ui->engineError[0])
        g_strlcpy(ui->engineError, "Could not connect to PipeWire.", sizeof ui->engineError);
    if (ui->engine) {
        dl_engine_set_on_change(ui->engine, on_engine_change, ui);
        dl_engine_set_master(ui->engine, ui->s->master);
    }
    for (int i = 0; i < DL_MAX_SPEAKERS; i++) ui->cardToEngine[i] = -1;
    dl_ui_refresh_sinks(ui);
    return ui;
}

int dl_ui_retry_engine(DLUi *ui)
{
    if (ui->engine) return 0;
    ui->engineError[0] = '\0';
    ui->engine = dl_engine_create(ui->engineError, sizeof ui->engineError);
    if (!ui->engine) {
        if (!ui->engineError[0]) g_strlcpy(ui->engineError, "Could not connect to PipeWire.", sizeof ui->engineError);
        dl_ui_sync(ui);
        return -1;
    }
    dl_engine_set_on_change(ui->engine, on_engine_change, ui);
    dl_engine_set_master(ui->engine, ui->s->master);
    dl_ui_refresh_sinks(ui);
    dl_ui_sync(ui);
    return 0;
}

void dl_ui_free(DLUi *ui)
{
    if (!ui) return;
    if (ui->pollId) g_source_remove(ui->pollId);
    if (ui->testTimer) g_source_remove(ui->testTimer);
    if (ui->saveId) {
        g_source_remove(ui->saveId);
        ui->saveId = 0;
    }
    dl_ui_save_now(ui);
    if (ui->engine) {
        dl_engine_set_on_change(ui->engine, NULL, NULL);
        if (ui->playing) dl_engine_stop(ui->engine);
        dl_engine_destroy(ui->engine);
    }
    g_hash_table_destroy(ui->appsApplied);
    g_key_file_free(ui->kf);
    g_free(ui->settingsPath);
    g_free(ui->s);
    g_free(ui);
}

DLCard *dl_ui_cards(DLUi *ui, uint32_t *count)
{
    if (ui->s->mode == DL_MODE_SURROUND) {
        *count = ui->s->count;
        return ui->s->cards;
    }
    *count = 2;
    return ui->s->stereo;
}

int dl_ui_is_surround(const DLUi *ui)
{
    return ui->s->mode == DL_MODE_SURROUND;
}

int *dl_ui_link(DLUi *ui)
{
    return dl_ui_is_surround(ui) ? &ui->s->surroundLink : &ui->s->stereoLink;
}

// ---- Sinks and apps ----

void dl_ui_refresh_sinks(DLUi *ui)
{
    if (!ui->engine) {
        ui->sinkCount = 0;
        ui->appCount = 0;
        return;
    }
    ui->sinkCount = dl_engine_sinks(ui->engine, ui->sinks, DL_MAX_SINKS);
    ui->appCount = dl_engine_apps(ui->engine, ui->apps, DL_MAX_ENGINE_APPS);
    apply_app_prefs(ui);
}

void dl_ui_sink_label(DLUi *ui, const char *id, char *buf, uint32_t len, int *available)
{
    int idx = dl_sink_find(ui->sinks, ui->sinkCount, id);
    if (available) *available = idx >= 0 && ui->sinks[idx].available;
    if (!id || !id[0]) {
        if (len) buf[0] = '\0';
        return;
    }
    if (idx >= 0) {
        dl_sink_display_label(ui->sinks, ui->sinkCount, (uint32_t)idx, buf, len);
    } else {
        char suffix[8];
        dl_sink_suffix(id, suffix, sizeof suffix);
        g_snprintf(buf, len, "Speaker %s", suffix);
    }
}

int dl_ui_card_missing(DLUi *ui, uint32_t card)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    if (card >= n || !c[card].sp.sinkId[0]) return 0;
    int idx = dl_sink_find(ui->sinks, ui->sinkCount, c[card].sp.sinkId);
    return idx < 0 || !ui->sinks[idx].available;
}

static void on_engine_change(void *ctx)
{
    DLUi *ui = ctx;
    dl_ui_refresh_sinks(ui);
    dl_ui_sync(ui);
}

// ---- Engine plumbing ----

static uint32_t build_speakers(DLUi *ui, DLSpeaker *out)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    uint32_t k = 0;
    for (uint32_t i = 0; i < DL_MAX_SPEAKERS; i++) ui->cardToEngine[i] = -1;
    for (uint32_t i = 0; i < n; i++) {
        if (!c[i].sp.sinkId[0]) continue;
        out[k] = c[i].sp;
        if (!dl_ui_is_surround(ui)) {
            out[k].azimuth = i == 0 ? -DL_STEREO_AZIMUTH : DL_STEREO_AZIMUTH;
            out[k].distance = DL_DISTANCE_DEFAULT;
            out[k].trim = i == 0 ? dl_balance_left_gain(ui->s->balance) : dl_balance_right_gain(ui->s->balance);
        }
        ui->engineToCard[k] = i;
        ui->cardToEngine[i] = (int)k;
        k++;
    }
    ui->engineCount = k;
    return k;
}

static void push_params(DLUi *ui)
{
    if (!ui->engine) return;
    DLSettings *s = ui->s;
    dl_engine_set_master(ui->engine, s->master);
    if (dl_ui_is_surround(ui)) {
        dl_engine_set_width(ui->engine, s->width);
        dl_engine_set_surround_level(ui->engine, s->surroundLevel);
        dl_engine_set_orbit(ui->engine, s->orbit * 360.0f);
        dl_engine_set_rotation(ui->engine, s->rotation);
        dl_engine_set_spatial(ui->engine, s->spatial, s->roomMs);
    } else {
        // Two speakers at -30 and +30 with width 30 play L and R bit for bit.
        dl_engine_set_width(ui->engine, DL_STEREO_AZIMUTH);
        dl_engine_set_orbit(ui->engine, 0.0f);
        dl_engine_set_rotation(ui->engine, 0.0f);
    }
}

static void push_delays(DLUi *ui)
{
    if (!ui->engine || !ui->playing) return;
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    float split[2];
    dl_stereo_delays(ui->s->stereoDelay, &split[0], &split[1]);
    for (uint32_t k = 0; k < ui->engineCount; k++) {
        uint32_t card = ui->engineToCard[k];
        float ms = dl_ui_is_surround(ui) ? c[card].delayMs : split[card < 2 ? card : 0];
        dl_engine_set_delay_ms(ui->engine, k, ms);
    }
}

static void push_effects(DLUi *ui)
{
    if (!ui->engine || !ui->playing) return;
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    for (uint32_t k = 0; k < ui->engineCount; k++) {
        const DLEffects *fx = &c[ui->engineToCard[k]].fx;
        DomineEQParams eq;
        DomineBassParams bass;
        DomineCompressorParams comp;
        dl_fx_eq_params(fx, &eq);
        dl_fx_bass_params(fx, &bass);
        dl_fx_comp_params(fx, &comp);
        dl_engine_set_eq(ui->engine, k, &eq);
        dl_engine_set_bass(ui->engine, k, &bass);
        dl_engine_set_compressor(ui->engine, k, &comp);
    }
}

static gboolean on_tick(gpointer data);

static void set_error(DLUi *ui, const char *msg)
{
    g_strlcpy(ui->errorText, msg ? msg : "", sizeof ui->errorText);
}

int dl_ui_set_playing(DLUi *ui, int on)
{
    if (!on) {
        if (ui->engine && ui->playing) {
            if (ui->demoOn) dl_engine_set_demo(ui->engine, 0);
            if (ui->clickTest) dl_engine_set_click_test(ui->engine, 0);
            dl_engine_stop(ui->engine);
        }
        ui->playing = 0;
        ui->demoOn = 0;
        ui->demoPlaying = 0;
        ui->clickTest = 0;
        ui->testCard = -1;
        ui->engineCount = 0;
        for (int i = 0; i < DL_MAX_SPEAKERS; i++) ui->cardToEngine[i] = -1;
        if (ui->pollId) {
            g_source_remove(ui->pollId);
            ui->pollId = 0;
        }
        set_error(ui, NULL);
        dl_ui_sync(ui);
        return 0;
    }
    if (!ui->engine) {
        set_error(ui, "PipeWire unavailable");
        dl_ui_sync(ui);
        return -1;
    }
    if (ui->playing) return 0;
    DLSpeaker sp[DL_MAX_SPEAKERS];
    uint32_t k = build_speakers(ui, sp);
    if (k == 0) {
        set_error(ui, "Choose a speaker first");
        dl_ui_sync(ui);
        return -1;
    }
    char err[256] = "";
    push_params(ui);
    if (dl_engine_start(ui->engine, sp, k, err, sizeof err) != 0) {
        set_error(ui, err[0] ? err : "Could not start");
        ui->playing = 0;
        dl_ui_sync(ui);
        return -1;
    }
    ui->playing = 1;
    set_error(ui, NULL);
    push_params(ui);
    push_delays(ui);
    push_effects(ui);
    if (!ui->pollId) ui->pollId = g_timeout_add(DL_TICK_MS, on_tick, ui);
    dl_ui_sync(ui);
    return 0;
}

static void restart(DLUi *ui)
{
    if (!ui->playing) return;
    dl_ui_set_playing(ui, 0);
    dl_ui_set_playing(ui, 1);
}

void dl_ui_cards_changed(DLUi *ui, int structural)
{
    if (ui->playing) {
        if (structural) {
            restart(ui);
        } else if (ui->engine) {
            DLSpeaker sp[DL_MAX_SPEAKERS];
            uint32_t k = build_speakers(ui, sp);
            dl_engine_update_speakers(ui->engine, sp, k);
        }
    }
    if (structural) dl_ui_refresh_room(ui);
    dl_ui_schedule_save(ui);
    dl_ui_sync(ui);
}

void dl_ui_assign(DLUi *ui, uint32_t card, const char *sinkId)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    if (card >= n) return;
    if (strcmp(c[card].sp.sinkId, sinkId ? sinkId : "") == 0) return;
    dl_settings_store_set(ui->s, ui->kf);
    g_strlcpy(c[card].sp.sinkId, sinkId ? sinkId : "", sizeof c[card].sp.sinkId);
    dl_settings_restore_set(ui->s, ui->kf);
    dl_ui_cards_changed(ui, 1);
}

void dl_ui_params_changed(DLUi *ui)
{
    if (ui->playing) {
        push_params(ui);
    } else if (ui->engine) {
        dl_engine_set_master(ui->engine, ui->s->master);
    }
    dl_ui_schedule_save(ui);
}

void dl_ui_tuning_changed(DLUi *ui)
{
    if (ui->playing && ui->engine) {
        DLSpeaker sp[DL_MAX_SPEAKERS];
        uint32_t k = build_speakers(ui, sp);
        dl_engine_update_speakers(ui->engine, sp, k);
        push_delays(ui);
    }
    dl_ui_schedule_save(ui);
}

void dl_ui_effects_changed(DLUi *ui)
{
    push_effects(ui);
    dl_ui_schedule_save(ui);
}

void dl_ui_set_mode(DLUi *ui, DLMode mode)
{
    if (ui->s->mode == mode) return;
    dl_settings_store_set(ui->s, ui->kf);
    int was = ui->playing;
    if (was) dl_ui_set_playing(ui, 0);
    ui->s->mode = mode;
    dl_settings_sanitize(ui->s);
    dl_ui_refresh_room(ui);
    if (was) dl_ui_set_playing(ui, 1);
    dl_ui_schedule_save(ui);
    dl_ui_sync(ui);
}

void dl_ui_swap(DLUi *ui)
{
    DLSettings *s = ui->s;
    DLCard tmp = s->stereo[0];
    s->stereo[0] = s->stereo[1];
    s->stereo[1] = tmp;
    s->stereo[0].sp.azimuth = -DL_STEREO_AZIMUTH;
    s->stereo[1].sp.azimuth = DL_STEREO_AZIMUTH;
    // The same physical speaker stays delayed and attenuated.
    s->stereoDelay = -s->stereoDelay;
    s->balance = -s->balance;
    dl_ui_cards_changed(ui, 1);
}

// ---- Surround layout ----

static const char *unused_sink(DLUi *ui)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    for (uint32_t i = 0; i < ui->sinkCount; i++) {
        if (!ui->sinks[i].available) continue;
        int used = 0;
        for (uint32_t j = 0; j < n; j++)
            if (strcmp(c[j].sp.sinkId, ui->sinks[i].id) == 0) used = 1;
        if (!used) return ui->sinks[i].id;
    }
    return "";
}

static void append_card(DLUi *ui, float azimuth)
{
    DLSettings *s = ui->s;
    if (s->count >= DL_MAX_SPEAKERS) return;
    DLCard *c = &s->cards[s->count];
    memset(c, 0, sizeof *c);
    c->sp.azimuth = azimuth;
    c->sp.distance = DL_DISTANCE_DEFAULT;
    c->sp.trim = 1.0f;
    if (s->surroundLink && s->count > 0) c->fx = s->cards[0].fx;
    g_strlcpy(c->sp.sinkId, unused_sink(ui), sizeof c->sp.sinkId);
    s->count++;
}

void dl_ui_add_speaker(DLUi *ui)
{
    DLSettings *s = ui->s;
    if (s->count >= DL_MAX_SPEAKERS) return;
    float az[DL_MAX_SPEAKERS];
    for (uint32_t i = 0; i < s->count; i++) az[i] = s->cards[i].sp.azimuth;
    dl_settings_store_set(s, ui->kf);
    append_card(ui, dl_geom_gap_azimuth(s->count, az));
    dl_ui_cards_changed(ui, 1);
}

void dl_ui_remove_speaker(DLUi *ui, uint32_t card)
{
    DLSettings *s = ui->s;
    if (s->count <= DL_SURROUND_MIN_SPEAKERS || card >= s->count) return;
    dl_settings_store_set(s, ui->kf);
    memmove(&s->cards[card], &s->cards[card + 1], (s->count - card - 1) * sizeof s->cards[0]);
    s->count--;
    dl_ui_cards_changed(ui, 1);
}

void dl_ui_apply_preset(DLUi *ui, int preset)
{
    DLSettings *s = ui->s;
    float az[DL_MAX_SPEAKERS];
    uint32_t n = dl_geom_preset((DLPreset)preset, s->count, az, DL_MAX_SPEAKERS);
    if (n > DL_MAX_SPEAKERS) n = DL_MAX_SPEAKERS;
    int structural = 0;
    while (s->count < n) {
        append_card(ui, az[s->count]);
        structural = 1;
    }
    for (uint32_t i = 0; i < n; i++) s->cards[i].sp.azimuth = az[i];
    dl_ui_cards_changed(ui, structural);
}

// ---- Demo, test tone, click test ----

void dl_ui_toggle_demo(DLUi *ui)
{
    if (!ui->engine) return;
    if (ui->demoOn) {
        dl_engine_set_demo(ui->engine, 0);
        ui->demoOn = 0;
        ui->demoPlaying = 0;
        dl_ui_sync(ui);
        return;
    }
    if (!ui->playing && dl_ui_set_playing(ui, 1) != 0) return;
    dl_engine_set_demo(ui->engine, 1);
    ui->demoOn = 1;
    ui->demoSection = 0;
    ui->demoStartedUs = g_get_monotonic_time();
    dl_ui_sync(ui);
}

static gboolean on_test_done(gpointer data)
{
    DLUi *ui = data;
    ui->testTimer = 0;
    ui->testCard = -1;
    if (ui->engine && ui->playing) dl_engine_set_test_tone(ui->engine, -1);
    return G_SOURCE_REMOVE;
}

void dl_ui_test_tone_engine(DLUi *ui, int engineIndex)
{
    if (!ui->engine || !ui->playing || engineIndex < 0 || (uint32_t)engineIndex >= ui->engineCount) return;
    dl_engine_set_test_tone(ui->engine, engineIndex);
    ui->testCard = (int)ui->engineToCard[engineIndex];
    if (ui->testTimer) g_source_remove(ui->testTimer);
    ui->testTimer = g_timeout_add(DL_TEST_TONE_MS, on_test_done, ui);
}

void dl_ui_test_tone(DLUi *ui, uint32_t card)
{
    if (card < DL_MAX_SPEAKERS) dl_ui_test_tone_engine(ui, ui->cardToEngine[card]);
}

int dl_ui_engine_index_for_sink(DLUi *ui, const char *sinkId)
{
    if (!ui->playing || !sinkId || !sinkId[0]) return -1;
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    for (uint32_t i = 0; i < n; i++)
        if (strcmp(c[i].sp.sinkId, sinkId) == 0 && ui->cardToEngine[i] >= 0) return ui->cardToEngine[i];
    return -1;
}

void dl_ui_set_click_test(DLUi *ui, int on)
{
    if (!ui->engine || !ui->playing) on = 0;
    if (ui->engine && ui->playing) dl_engine_set_click_test(ui->engine, on);
    ui->clickTest = on;
}

// ---- Rooms ----

static void room_from_current(DLUi *ui, DLRoom *r)
{
    DLSettings *s = ui->s;
    r->mode = s->mode;
    g_strlcpy(r->stereo[0], s->stereo[0].sp.sinkId, sizeof r->stereo[0]);
    g_strlcpy(r->stereo[1], s->stereo[1].sp.sinkId, sizeof r->stereo[1]);
    r->count = s->count;
    for (uint32_t i = 0; i < s->count; i++) g_strlcpy(r->sinks[i], s->cards[i].sp.sinkId, sizeof r->sinks[i]);
}

void dl_ui_save_room(DLUi *ui, const char *name)
{
    DLSettings *s = ui->s;
    char *trimmed = g_strstrip(g_strdup(name ? name : ""));
    if (trimmed[0] && s->roomCount < DL_MAX_ROOMS) {
        DLRoom *r = &s->rooms[s->roomCount];
        memset(r, 0, sizeof *r);
        g_strlcpy(r->name, trimmed, sizeof r->name);
        room_from_current(ui, r);
        s->currentRoom = (int)s->roomCount;
        s->roomCount++;
        dl_ui_schedule_save(ui);
        dl_ui_sync(ui);
    }
    g_free(trimmed);
}

void dl_ui_select_room(DLUi *ui, int index)
{
    DLSettings *s = ui->s;
    if (index < 0 || index >= (int)s->roomCount) return;
    const DLRoom *r = &s->rooms[index];
    int was = ui->playing;
    if (was) dl_ui_set_playing(ui, 0);
    dl_settings_store_set(s, ui->kf);
    s->mode = r->mode;
    if (r->mode == DL_MODE_STEREO) {
        for (int i = 0; i < 2; i++) g_strlcpy(s->stereo[i].sp.sinkId, r->stereo[i], sizeof s->stereo[i].sp.sinkId);
    } else {
        uint32_t n = r->count < DL_SURROUND_MIN_SPEAKERS ? DL_SURROUND_MIN_SPEAKERS : r->count;
        float az[DL_MAX_SPEAKERS];
        dl_geom_preset(DL_PRESET_RING, n, az, DL_MAX_SPEAKERS);
        for (uint32_t i = 0; i < n; i++) {
            DLCard *c = &s->cards[i];
            memset(c, 0, sizeof *c);
            c->sp.azimuth = az[i];
            c->sp.distance = DL_DISTANCE_DEFAULT;
            c->sp.trim = 1.0f;
            if (i < r->count) g_strlcpy(c->sp.sinkId, r->sinks[i], sizeof c->sp.sinkId);
        }
        s->count = n;
    }
    dl_settings_restore_set(s, ui->kf);
    s->currentRoom = index;
    if (was) dl_ui_set_playing(ui, 1);
    dl_ui_schedule_save(ui);
    dl_ui_sync(ui);
}

void dl_ui_rename_room(DLUi *ui, int index, const char *name)
{
    DLSettings *s = ui->s;
    if (index < 0 || index >= (int)s->roomCount) return;
    char *trimmed = g_strstrip(g_strdup(name ? name : ""));
    if (trimmed[0]) {
        g_strlcpy(s->rooms[index].name, trimmed, sizeof s->rooms[index].name);
        dl_ui_schedule_save(ui);
        dl_rooms_sync(ui);
    }
    g_free(trimmed);
}

void dl_ui_delete_room(DLUi *ui, int index)
{
    DLSettings *s = ui->s;
    if (index < 0 || index >= (int)s->roomCount) return;
    memmove(&s->rooms[index], &s->rooms[index + 1], (s->roomCount - (uint32_t)index - 1) * sizeof s->rooms[0]);
    s->roomCount--;
    if (s->currentRoom == index) s->currentRoom = -1;
    else if (s->currentRoom > index) s->currentRoom--;
    dl_ui_schedule_save(ui);
    dl_ui_sync(ui);
}

void dl_ui_refresh_room(DLUi *ui)
{
    DLSettings *s = ui->s;
    if (s->currentRoom < 0 || s->currentRoom >= (int)s->roomCount) {
        s->currentRoom = -1;
        return;
    }
    DLRoom now;
    memset(&now, 0, sizeof now);
    room_from_current(ui, &now);
    const DLRoom *r = &s->rooms[s->currentRoom];
    int match = r->mode == now.mode;
    if (match && r->mode == DL_MODE_STEREO) {
        match = strcmp(r->stereo[0], now.stereo[0]) == 0 && strcmp(r->stereo[1], now.stereo[1]) == 0;
    } else if (match) {
        for (uint32_t i = 0; i < now.count && match; i++) {
            const char *want = i < r->count ? r->sinks[i] : "";
            if (strcmp(want, now.sinks[i]) != 0) match = 0;
        }
        if (r->count > now.count) match = 0;
    }
    if (!match) s->currentRoom = -1;
}

// ---- Apps ----

DLAppPref *dl_ui_app_pref(DLUi *ui, const char *key, const char *label, int create)
{
    DLSettings *s = ui->s;
    for (uint32_t i = 0; i < s->appCount; i++)
        if (strcmp(s->apps[i].key, key) == 0) {
            if (label && label[0]) g_strlcpy(s->apps[i].label, label, sizeof s->apps[i].label);
            return &s->apps[i];
        }
    if (!create || s->appCount >= DL_MAX_APP_PREFS) return NULL;
    DLAppPref *a = &s->apps[s->appCount++];
    memset(a, 0, sizeof *a);
    g_strlcpy(a->key, key, sizeof a->key);
    g_strlcpy(a->label, label && label[0] ? label : key, sizeof a->label);
    a->volume = 1.0f;
    return a;
}

static void drop_pref_if_empty(DLUi *ui, DLAppPref *a)
{
    if (a->excluded || a->hasVolume) return;
    DLSettings *s = ui->s;
    uint32_t idx = (uint32_t)(a - s->apps);
    memmove(&s->apps[idx], &s->apps[idx + 1], (s->appCount - idx - 1) * sizeof s->apps[0]);
    s->appCount--;
}

void dl_ui_set_app_excluded(DLUi *ui, const char *key, const char *label, int excluded)
{
    DLAppPref *a = dl_ui_app_pref(ui, key, label, excluded);
    if (!a) return;
    a->excluded = excluded ? 1 : 0;
    if (ui->engine) dl_engine_set_app_excluded(ui->engine, key, a->excluded, ui->s->excludeSinkId);
    drop_pref_if_empty(ui, a);
    dl_ui_schedule_save(ui);
}

void dl_ui_set_app_volume(DLUi *ui, const char *key, const char *label, float volume)
{
    DLAppPref *a = dl_ui_app_pref(ui, key, label, 1);
    if (!a) return;
    a->hasVolume = fabsf(volume - 1.0f) > 0.004f;
    a->volume = volume;
    if (ui->engine) dl_engine_set_app_volume(ui->engine, key, volume);
    drop_pref_if_empty(ui, a);
    dl_ui_schedule_save(ui);
}

void dl_ui_set_exclude_sink(DLUi *ui, const char *sinkId)
{
    g_strlcpy(ui->s->excludeSinkId, sinkId ? sinkId : "", sizeof ui->s->excludeSinkId);
    for (uint32_t i = 0; i < ui->s->appCount && ui->engine; i++)
        if (ui->s->apps[i].excluded)
            dl_engine_set_app_excluded(ui->engine, ui->s->apps[i].key, 1, ui->s->excludeSinkId);
    dl_ui_schedule_save(ui);
}

/// Applies saved exclusions and volumes once to each app as it appears.
static void apply_app_prefs(DLUi *ui)
{
    GHashTable *present = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    for (uint32_t i = 0; i < ui->appCount; i++) {
        const DLApp *app = &ui->apps[i];
        g_hash_table_add(present, g_strdup(app->key));
        if (g_hash_table_contains(ui->appsApplied, app->key)) continue;
        DLAppPref *a = dl_ui_app_pref(ui, app->key, NULL, 0);
        if (a && ui->engine) {
            if (a->excluded && !app->excluded)
                dl_engine_set_app_excluded(ui->engine, app->key, 1, ui->s->excludeSinkId);
            if (a->hasVolume) dl_engine_set_app_volume(ui->engine, app->key, a->volume);
        }
    }
    g_hash_table_destroy(ui->appsApplied);
    ui->appsApplied = present;
}

// ---- Status ----

float dl_ui_card_peak(DLUi *ui, uint32_t card)
{
    if (!ui->engine || !ui->playing || card >= DL_MAX_SPEAKERS || ui->cardToEngine[card] < 0) return 0.0f;
    float p = dl_engine_peak(ui->engine, (uint32_t)ui->cardToEngine[card]);
    return isfinite(p) ? p : 0.0f;
}

static int any_missing(DLUi *ui, int *missing)
{
    uint32_t n;
    dl_ui_cards(ui, &n);
    int any = 0;
    for (uint32_t i = 0; i < n; i++) {
        missing[i] = dl_ui_card_missing(ui, i);
        any |= missing[i];
    }
    return any;
}

void dl_ui_status_text(DLUi *ui, char *buf, uint32_t len)
{
    int missing[DL_MAX_SPEAKERS];
    if (!ui->engine) {
        g_strlcpy(buf, "PipeWire unavailable", len);
    } else if (ui->errorText[0]) {
        g_strlcpy(buf, ui->errorText, len);
    } else if (!ui->playing) {
        g_strlcpy(buf, "Off", len);
    } else if (ui->demoOn) {
        const char *name = dl_demo_section_name(ui->demoSection);
        g_snprintf(buf, len, "Demo: %s", name[0] ? name : "Playing");
    } else {
        DLState st = dl_engine_state(ui->engine);
        if (st == DL_STARTING) g_strlcpy(buf, "Starting", len);
        else if (st == DL_ERROR) {
            char err[256] = "";
            dl_engine_error(ui->engine, err, sizeof err);
            g_strlcpy(buf, err[0] ? err : "Audio error", len);
        }
        else if (any_missing(ui, missing) || st == DL_DEGRADED)
            g_strlcpy(buf, dl_ui_is_surround(ui) ? "Speaker disconnected" : "Mono fallback", len);
        else g_strlcpy(buf, "Playing", len);
    }
}

void dl_ui_banner_text(DLUi *ui, char *buf, uint32_t len, int *isError)
{
    *isError = 0;
    buf[0] = '\0';
    if (!ui->engine) {
        *isError = 1;
        g_snprintf(buf, len, "PipeWire is not available: %s", ui->engineError);
        return;
    }
    if (!ui->playing) return;
    int missing[DL_MAX_SPEAKERS];
    uint32_t n;
    dl_ui_cards(ui, &n);
    if (any_missing(ui, missing)) {
        dl_fallback_banner(ui->s->mode, n, missing, buf, len);
    } else if (dl_engine_state(ui->engine) == DL_DEGRADED) {
        dl_engine_error(ui->engine, buf, len);
    }
}

static gboolean on_tick(gpointer data)
{
    DLUi *ui = data;
    if (!ui->playing || !ui->engine) {
        ui->pollId = 0;
        return G_SOURCE_REMOVE;
    }
    float sec = 0, az = 0;
    int section = 0;
    ui->demoPlaying = dl_engine_demo_status(ui->engine, &sec, &az, &section);
    if (ui->demoPlaying) {
        ui->demoAzimuth = az;
        ui->demoSection = section;
    } else if (ui->demoOn && g_get_monotonic_time() - ui->demoStartedUs > 500000) {
        // Finished on its own (status reports idle once the 32 s are over).
        ui->demoOn = 0;
        dl_engine_set_demo(ui->engine, 0);
        dl_ui_sync(ui);
    }
    float m = dl_engine_master(ui->engine);
    if (isfinite(m) && m >= 0.0f && m <= 1.0f &&
        fabsf(dl_volume_to_slider(m) - dl_volume_to_slider(ui->s->master)) > 0.004f) {
        ui->s->master = m;   // desktop volume keys moved the Domine sink
        dl_ui_schedule_save(ui);
    }
    dl_window_tick(ui);
    return G_SOURCE_CONTINUE;
}

// ---- Saving and syncing ----

void dl_ui_save_now(DLUi *ui)
{
    dl_settings_to_keyfile(ui->s, ui->kf);
    dl_settings_save_file(ui->kf, ui->settingsPath);
}

static gboolean on_save(gpointer data)
{
    DLUi *ui = data;
    ui->saveId = 0;
    dl_ui_save_now(ui);
    return G_SOURCE_REMOVE;
}

void dl_ui_schedule_save(DLUi *ui)
{
    if (!ui->saveId) ui->saveId = g_timeout_add(DL_SAVE_DELAY_MS, on_save, ui);
}

void dl_ui_sync(DLUi *ui)
{
    dl_window_sync(ui);
    dl_rooms_sync(ui);
    dl_tuning_sync(ui);
    dl_sound_sync(ui);
    dl_prefs_sync(ui);
    dl_welcome_sync(ui);
}
