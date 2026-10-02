// Domine for Linux: application state shared by the window, the stage and
// the dialogs. Everything here runs on the GTK main thread.
//
// (engine.h already uses the name DLApp for a playing application, so the
// UI state is DLUi.)
#ifndef DOMINE_UI_APP_H
#define DOMINE_UI_APP_H

#include <gtk/gtk.h>
#include "engine.h"
#include "settings.h"

#define DL_MAX_ENGINE_APPS 64

typedef struct {
    GtkWidget *window;
    GtkWidget *subtitle;
    GtkWidget *stereoButton;
    GtkWidget *surroundButton;
    GtkWidget *swapButton;
    GtkWidget *roomButton;
    GtkWidget *power;
    GtkWidget *banner;
    GtkWidget *bannerLabel;
    GtkWidget *stage;
    GtkWidget *bottomBar;
    GtkWidget *master;
    GtkWidget *masterText;
    GtkWidget *testLeft;
    GtkWidget *testRight;
    GtkWidget *addButton;
    GtkWidget *presetsButton;
    GtkWidget *demoButton;
    GtkWidget *surroundControls;
    GtkWidget *width;
    GtkWidget *surroundLevel;
    GtkWidget *orbit;
    GtkWidget *rotation;
    GtkWidget *warning;
} DLWidgets;

typedef struct DLUi {
    GtkApplication *gtkApp;
    DLEngine *engine;
    char engineError[256];   // why dl_engine_create failed
    char errorText[256];     // last start error, shown in the subtitle

    DLSettings *s;
    GKeyFile *kf;            // the settings file, including per-set records
    char *settingsPath;      // NULL = default location

    DLSink sinks[DL_MAX_SINKS];
    uint32_t sinkCount;
    DLApp apps[DL_MAX_ENGINE_APPS];
    uint32_t appCount;
    GHashTable *appsApplied; // app keys whose saved volume and exclusion were applied

    int playing;
    uint32_t engineCount;                 // speakers handed to the engine
    uint32_t engineToCard[DL_MAX_SPEAKERS];
    int cardToEngine[DL_MAX_SPEAKERS];    // -1 when the card is not playing

    int demoOn;              // demo requested by the user
    gint64 demoStartedUs;
    int demoPlaying;         // last dl_engine_demo_status result
    float demoAzimuth;
    int demoSection;

    int testCard;            // card playing a test tone, or -1
    guint testTimer;
    int clickTest;

    guint pollId;
    guint saveId;
    int syncing;             // nonzero while widgets are being set from state
    int held;                // g_application_hold while the window is hidden
    int startHidden;         // --background

    GtkWidget *tuning;       // open dialogs (NULL when closed)
    GtkWidget *sound;
    GtkWidget *prefs;
    GtkWidget *welcome;

    DLWidgets w;
} DLUi;

DLUi *dl_ui_new(GtkApplication *app, const char *settingsPath);
void dl_ui_free(DLUi *ui);
/// Tries to connect to PipeWire again after a failed start. Returns 0 when
/// the engine is available.
int dl_ui_retry_engine(DLUi *ui);

/// Speaker cards of the current mode (2 in Stereo, settings count in Surround).
DLCard *dl_ui_cards(DLUi *ui, uint32_t *count);
int dl_ui_is_surround(const DLUi *ui);
/// Effects are linked across the cards of the current mode.
int *dl_ui_link(DLUi *ui);

/// Re-reads sinks and apps from the engine.
void dl_ui_refresh_sinks(DLUi *ui);
/// Display label for a sink id ("" when id is empty). *available is set to
/// nonzero when the sink currently exists. Either out may be NULL.
void dl_ui_sink_label(DLUi *ui, const char *id, char *buf, uint32_t len, int *available);
/// Nonzero when the card has a sink that is not currently available.
int dl_ui_card_missing(DLUi *ui, uint32_t card);

/// Starts or stops routing. Returns 0 on success.
int dl_ui_set_playing(DLUi *ui, int on);
/// A card changed. structural nonzero means sinks or the number of cards
/// changed (restart while playing); otherwise positions or trims (live).
void dl_ui_cards_changed(DLUi *ui, int structural);
/// Assigns a sink to a card (restoring that speaker set's saved tuning).
void dl_ui_assign(DLUi *ui, uint32_t card, const char *sinkId);
/// Master, width, surround level, orbit, rotation or spatial changed.
void dl_ui_params_changed(DLUi *ui);
/// Delay, balance or trim changed (Sync & Balance).
void dl_ui_tuning_changed(DLUi *ui);
/// Effects changed (Sound).
void dl_ui_effects_changed(DLUi *ui);
void dl_ui_set_mode(DLUi *ui, DLMode mode);
void dl_ui_swap(DLUi *ui);

void dl_ui_add_speaker(DLUi *ui);
void dl_ui_remove_speaker(DLUi *ui, uint32_t card);
void dl_ui_apply_preset(DLUi *ui, int preset);
void dl_ui_toggle_demo(DLUi *ui);
/// One test chime on a card (needs routing on).
void dl_ui_test_tone(DLUi *ui, uint32_t card);
/// Engine index of the card playing the sink, or -1.
int dl_ui_engine_index_for_sink(DLUi *ui, const char *sinkId);
void dl_ui_test_tone_engine(DLUi *ui, int engineIndex);
void dl_ui_set_click_test(DLUi *ui, int on);

/// Rooms.
void dl_ui_save_room(DLUi *ui, const char *name);
void dl_ui_select_room(DLUi *ui, int index);
void dl_ui_rename_room(DLUi *ui, int index, const char *name);
void dl_ui_delete_room(DLUi *ui, int index);
/// Clears the current room if the speakers no longer match it.
void dl_ui_refresh_room(DLUi *ui);

/// Apps (exclusions and per-app volume).
DLAppPref *dl_ui_app_pref(DLUi *ui, const char *key, const char *label, int create);
void dl_ui_set_app_excluded(DLUi *ui, const char *key, const char *label, int excluded);
void dl_ui_set_app_volume(DLUi *ui, const char *key, const char *label, float volume);
void dl_ui_set_exclude_sink(DLUi *ui, const char *sinkId);

/// Meter level for a card, 0...1 (0 when not playing).
float dl_ui_card_peak(DLUi *ui, uint32_t card);
/// Subtitle text for the header bar.
void dl_ui_status_text(DLUi *ui, char *buf, uint32_t len);
/// Banner text ("" for none): engine error or mono fallback.
void dl_ui_banner_text(DLUi *ui, char *buf, uint32_t len, int *isError);

void dl_ui_schedule_save(DLUi *ui);
void dl_ui_save_now(DLUi *ui);
/// Refreshes the window and every open dialog from the state.
void dl_ui_sync(DLUi *ui);

/// ui_window.c
void dl_window_build(DLUi *ui);
void dl_window_sync(DLUi *ui);
void dl_window_present(DLUi *ui);
/// ~30 Hz while playing: meters, demo dot, subtitle, master slider.
void dl_window_tick(DLUi *ui);
/// ui_tuning.c, ui_sound.c, ui_prefs.c, ui_welcome.c, ui_rooms.c, ui_assign.c
void dl_tuning_open(DLUi *ui);
void dl_tuning_sync(DLUi *ui);
void dl_sound_open(DLUi *ui);
void dl_sound_sync(DLUi *ui);
void dl_prefs_open(DLUi *ui);
void dl_prefs_sync(DLUi *ui);
void dl_welcome_open(DLUi *ui);
void dl_welcome_sync(DLUi *ui);
GtkWidget *dl_rooms_button(DLUi *ui);
void dl_rooms_sync(DLUi *ui);
void dl_assign_open(DLUi *ui, uint32_t card);
/// ui_prefs.c: writes or removes the XDG autostart entry.
int dl_autostart_set(int enabled);

#endif
