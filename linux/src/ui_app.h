// Domine for Linux: application state shared by the window and the stage.
// Everything here runs on the GTK main thread.
#ifndef DOMINE_UI_APP_H
#define DOMINE_UI_APP_H

#include <gtk/gtk.h>
#include "engine.h"
#include "settings.h"

typedef struct {
    GtkWidget *window;
    GtkWidget *subtitle;
    GtkWidget *stereoButton;
    GtkWidget *surroundButton;
    GtkWidget *power;
    GtkWidget *banner;
    GtkWidget *bannerLabel;
    GtkWidget *stage;
    GtkWidget *bottomBar;
    GtkWidget *master;
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

typedef struct DLApp {
    GtkApplication *gtkApp;
    DLEngine *engine;
    char engineError[256];   // why dl_engine_create failed
    char errorText[256];     // last start error, shown in the subtitle

    DLSettings settings;
    DLSink sinks[DL_MAX_SINKS];
    uint32_t sinkCount;

    int playing;
    uint32_t engineCount;                 // speakers handed to the engine
    uint32_t engineToCard[DL_MAX_SPEAKERS];
    int cardToEngine[DL_MAX_SPEAKERS];    // -1 when the card is not playing

    int demoOn;              // demo requested by the user
    gint64 demoStartedUs;
    int demoPlaying;         // last dl_engine_demo_status result
    float demoAzimuth;
    int demoSection;

    guint pollId;
    guint saveId;
    int syncing;             // nonzero while widgets are being set from state

    DLWidgets w;
} DLApp;

/// Speaker cards of the current mode (2 in Stereo, settings.count in Surround).
DLSpeaker *dl_app_cards(DLApp *app, uint32_t *count);
int dl_app_is_surround(const DLApp *app);

/// Re-reads the sink list from the engine.
void dl_app_refresh_sinks(DLApp *app);
/// Display label for a sink id ("" when id is empty). *available is set to
/// nonzero when the sink currently exists. Either out may be NULL.
void dl_app_sink_label(DLApp *app, const char *id, char *buf, uint32_t len, int *available);

/// Starts or stops routing. Returns 0 on success.
int dl_app_set_playing(DLApp *app, int on);
/// A card changed. structural nonzero means sinks or the number of cards
/// changed (restart while playing); otherwise positions or trims (live).
void dl_app_cards_changed(DLApp *app, int structural);
/// Master, width, surround level, orbit or rotation changed.
void dl_app_params_changed(DLApp *app);
void dl_app_set_mode(DLApp *app, DLMode mode);

void dl_app_add_speaker(DLApp *app);
void dl_app_remove_speaker(DLApp *app, uint32_t card);
void dl_app_apply_preset(DLApp *app, int preset);
void dl_app_toggle_demo(DLApp *app);

/// Meter level for a card, 0...1 (0 when not playing).
float dl_app_card_peak(DLApp *app, uint32_t card);
/// Subtitle text for the header bar.
void dl_app_status_text(DLApp *app, char *buf, uint32_t len);

void dl_app_schedule_save(DLApp *app);
void dl_app_save_now(DLApp *app);

/// Implemented in ui_window.c: builds the window, and refreshes every widget
/// from the app state.
void dl_window_build(DLApp *app);
void dl_window_sync(DLApp *app);

#endif
