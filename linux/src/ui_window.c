// Domine for Linux: main window. Header bar (title and status line, Stereo /
// Surround, swap, rooms, on/off, menu), banner, stage, bottom bar.
#include <math.h>
#include <string.h>
#include "ui_app.h"
#include "ui_geometry.h"
#include "ui_logic.h"
#include "ui_stage.h"
#include "ui_widgets.h"

static const char *kCss =
    ".dl-banner { padding: 8px 12px; margin: 8px 12px 0 12px; border-radius: 8px;"
    "  border: 1px solid rgba(224, 27, 36, 0.35); }\n"
    ".dl-banner.error { background-color: rgba(224, 27, 36, 0.10); }\n"
    ".dl-warning { color: #c64600; }\n"
    ".dl-section { font-weight: bold; font-size: smaller; opacity: 0.6; }\n"
    ".dl-readout { font-feature-settings: \"tnum\"; opacity: 0.7; }\n";

// ---- Callbacks ----

static void on_mode_toggled(GtkToggleButton *b, gpointer data)
{
    DLUi *ui = data;
    if (ui->syncing || !gtk_toggle_button_get_active(b)) return;
    dl_ui_set_mode(ui, GTK_WIDGET(b) == ui->w.surroundButton ? DL_MODE_SURROUND : DL_MODE_STEREO);
}

static void on_power(GObject *sw, GParamSpec *pspec, gpointer data)
{
    (void)pspec;
    DLUi *ui = data;
    if (ui->syncing) return;
    dl_ui_set_playing(ui, gtk_switch_get_active(GTK_SWITCH(sw)));
}

static void on_swap(GtkButton *b, gpointer data)
{
    (void)b;
    dl_ui_swap(data);
}

static void on_master(GtkRange *r, gpointer data)
{
    DLUi *ui = data;
    if (ui->syncing) return;
    ui->s->master = (float)gtk_range_get_value(r) / 100.0f;
    char t[16];
    dl_percent_text(ui->s->master, t, sizeof t);
    gtk_label_set_text(GTK_LABEL(ui->w.masterText), t);
    dl_ui_params_changed(ui);
}

static void on_surround_param(GtkRange *r, gpointer data)
{
    DLUi *ui = data;
    if (ui->syncing) return;
    float v = (float)gtk_range_get_value(r);
    GtkWidget *w = GTK_WIDGET(r);
    if (w == ui->w.width) ui->s->width = v;
    else if (w == ui->w.surroundLevel) ui->s->surroundLevel = v / 100.0f;
    else if (w == ui->w.orbit) ui->s->orbit = v;
    else if (w == ui->w.rotation) ui->s->rotation = v;
    dl_ui_params_changed(ui);
}

static void on_test(GtkButton *b, gpointer data)
{
    DLUi *ui = data;
    dl_ui_test_tone(ui, GTK_WIDGET(b) == ui->w.testLeft ? 0 : 1);
    gtk_widget_queue_draw(ui->w.stage);
}

static void on_sound(GtkButton *b, gpointer data)
{
    (void)b;
    dl_sound_open(data);
}

static void on_tuning(GtkButton *b, gpointer data)
{
    (void)b;
    dl_tuning_open(data);
}

static void on_add(GtkButton *b, gpointer data)
{
    (void)b;
    dl_ui_add_speaker(data);
}

static void on_demo(GtkButton *b, gpointer data)
{
    (void)b;
    dl_ui_toggle_demo(data);
}

static void on_preset(GtkButton *b, gpointer data)
{
    DLUi *ui = data;
    GtkWidget *pop = gtk_widget_get_ancestor(GTK_WIDGET(b), GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
    dl_ui_apply_preset(ui, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "preset")));
}

static gboolean on_close_request(GtkWindow *win, gpointer data)
{
    DLUi *ui = data;
    if (!ui->s->keepRunning) return FALSE;
    // Keep routing in the background; a second launch shows the window again.
    gtk_widget_set_visible(GTK_WIDGET(win), FALSE);
    if (!ui->held) {
        g_application_hold(G_APPLICATION(ui->gtkApp));
        ui->held = 1;
    }
    dl_ui_save_now(ui);
    return TRUE;
}

static void act_prefs(GSimpleAction *a, GVariant *p, gpointer data)
{
    (void)a;
    (void)p;
    dl_prefs_open(data);
}

static void act_setup(GSimpleAction *a, GVariant *p, gpointer data)
{
    (void)a;
    (void)p;
    dl_welcome_open(data);
}

static void act_quit(GSimpleAction *a, GVariant *p, gpointer data)
{
    (void)a;
    (void)p;
    DLUi *ui = data;
    if (ui->held) {
        g_application_release(G_APPLICATION(ui->gtkApp));
        ui->held = 0;
    }
    g_application_quit(G_APPLICATION(ui->gtkApp));
}

// ---- Construction ----

static char *fmt_degrees(GtkScale *s, double v, gpointer d)
{
    (void)s;
    (void)d;
    return g_strdup_printf("%ld°", lround(v));
}

static char *fmt_percent(GtkScale *s, double v, gpointer d)
{
    (void)s;
    (void)d;
    return g_strdup_printf("%ld%%", lround(v));
}

static char *fmt_orbit(GtkScale *s, double v, gpointer d)
{
    (void)s;
    (void)d;
    char t[32];
    dl_orbit_text((float)v, t, sizeof t);
    return g_strdup(t);
}

static GtkWidget *param_scale(DLUi *ui, GtkGrid *grid, int col, int row, const char *title, double lo, double hi,
                              double step, GtkScaleFormatValueFunc fmt)
{
    GtkWidget *label = gtk_label_new(title);
    gtk_label_set_xalign(GTK_LABEL(label), 1);
    gtk_widget_add_css_class(label, "dim-label");
    GtkWidget *scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lo, hi, step);
    gtk_scale_set_draw_value(GTK_SCALE(scale), TRUE);
    gtk_scale_set_value_pos(GTK_SCALE(scale), GTK_POS_RIGHT);
    gtk_scale_set_format_value_func(GTK_SCALE(scale), fmt, NULL, NULL);
    gtk_widget_set_hexpand(scale, TRUE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(scale), GTK_ACCESSIBLE_PROPERTY_LABEL, title, -1);
    g_signal_connect(scale, "value-changed", G_CALLBACK(on_surround_param), ui);
    gtk_grid_attach(grid, label, col * 2, row, 1, 1);
    gtk_grid_attach(grid, scale, col * 2 + 1, row, 1, 1);
    return scale;
}

static GtkWidget *presets_button(DLUi *ui)
{
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    for (int p = 0; p < DL_PRESET_COUNT; p++) {
        GtkWidget *b = gtk_button_new_with_label(dl_geom_preset_name((DLPreset)p));
        gtk_widget_add_css_class(b, "flat");
        gtk_widget_set_halign(gtk_button_get_child(GTK_BUTTON(b)), GTK_ALIGN_START);
        g_object_set_data(G_OBJECT(b), "preset", GINT_TO_POINTER(p));
        g_signal_connect(b, "clicked", G_CALLBACK(on_preset), ui);
        gtk_box_append(GTK_BOX(box), b);
    }
    GtkWidget *pop = gtk_popover_new();
    gtk_popover_set_child(GTK_POPOVER(pop), box);
    GtkWidget *mb = gtk_menu_button_new();
    gtk_menu_button_set_label(GTK_MENU_BUTTON(mb), "Presets");
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(mb), pop);
    gtk_widget_set_tooltip_text(mb, "Place the speakers in a standard layout, in order");
    return mb;
}

static GtkWidget *build_header(DLUi *ui)
{
    DLWidgets *w = &ui->w;
    GtkWidget *bar = gtk_header_bar_new();

    GtkWidget *titles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_valign(titles, GTK_ALIGN_CENTER);
    GtkWidget *title = gtk_label_new("Domine");
    gtk_widget_add_css_class(title, "title");
    w->subtitle = gtk_label_new("Off");
    gtk_widget_add_css_class(w->subtitle, "subtitle");
    gtk_label_set_ellipsize(GTK_LABEL(w->subtitle), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(w->subtitle), 40);
    gtk_box_append(GTK_BOX(titles), title);
    gtk_box_append(GTK_BOX(titles), w->subtitle);
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(bar), titles);

    GtkWidget *modes = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(modes, "linked");
    w->stereoButton = gtk_toggle_button_new_with_label("Stereo");
    w->surroundButton = gtk_toggle_button_new_with_label("Surround");
    gtk_toggle_button_set_group(GTK_TOGGLE_BUTTON(w->surroundButton), GTK_TOGGLE_BUTTON(w->stereoButton));
    g_signal_connect(w->stereoButton, "toggled", G_CALLBACK(on_mode_toggled), ui);
    g_signal_connect(w->surroundButton, "toggled", G_CALLBACK(on_mode_toggled), ui);
    gtk_box_append(GTK_BOX(modes), w->stereoButton);
    gtk_box_append(GTK_BOX(modes), w->surroundButton);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), modes);

    w->swapButton = gtk_button_new_from_icon_name("object-flip-horizontal-symbolic");
    gtk_widget_set_tooltip_text(w->swapButton, "Swap left and right");
    gtk_accessible_update_property(GTK_ACCESSIBLE(w->swapButton), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   "Swap left and right", -1);
    g_signal_connect(w->swapButton, "clicked", G_CALLBACK(on_swap), ui);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(bar), w->swapButton);

    GMenu *menu = g_menu_new();
    g_menu_append(menu, "Preferences", "app.preferences");
    g_menu_append(menu, "Setup Guide", "app.setup");
    g_menu_append(menu, "Quit", "app.quit");
    GtkWidget *menuButton = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(menuButton), "open-menu-symbolic");
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(menuButton), G_MENU_MODEL(menu));
    gtk_widget_set_tooltip_text(menuButton, "Menu");
    g_object_unref(menu);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(bar), menuButton);

    w->power = gtk_switch_new();
    gtk_widget_set_valign(w->power, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(w->power, "Turn Domine on or off");
    gtk_accessible_update_property(GTK_ACCESSIBLE(w->power), GTK_ACCESSIBLE_PROPERTY_LABEL, "Domine output", -1);
    g_signal_connect(w->power, "notify::active", G_CALLBACK(on_power), ui);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(bar), w->power);

    w->roomButton = dl_rooms_button(ui);
    gtk_header_bar_pack_end(GTK_HEADER_BAR(bar), w->roomButton);
    return bar;
}

static GtkWidget *build_bottom(DLUi *ui)
{
    DLWidgets *w = &ui->w;
    GtkWidget *bottom = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(bottom, 16);
    gtk_widget_set_margin_end(bottom, 16);
    gtk_widget_set_margin_top(bottom, 10);
    gtk_widget_set_margin_bottom(bottom, 12);

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *icon = gtk_image_new_from_icon_name("audio-volume-medium-symbolic");
    gtk_box_append(GTK_BOX(row), icon);
    GtkWidget *ml = gtk_label_new("Master");
    gtk_widget_add_css_class(ml, "dim-label");
    gtk_box_append(GTK_BOX(row), ml);
    w->master = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 1);
    gtk_widget_set_hexpand(w->master, TRUE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(w->master), GTK_ACCESSIBLE_PROPERTY_LABEL, "Master volume", -1);
    g_signal_connect(w->master, "value-changed", G_CALLBACK(on_master), ui);
    gtk_box_append(GTK_BOX(row), w->master);
    w->masterText = gtk_label_new("80%");
    gtk_label_set_width_chars(GTK_LABEL(w->masterText), 4);
    gtk_label_set_xalign(GTK_LABEL(w->masterText), 1);
    gtk_widget_add_css_class(w->masterText, "dl-readout");
    gtk_box_append(GTK_BOX(row), w->masterText);

    GtkWidget *tests = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    w->testLeft = gtk_button_new_with_label("Test L");
    w->testRight = gtk_button_new_with_label("Test R");
    g_signal_connect(w->testLeft, "clicked", G_CALLBACK(on_test), ui);
    g_signal_connect(w->testRight, "clicked", G_CALLBACK(on_test), ui);
    gtk_box_append(GTK_BOX(tests), w->testLeft);
    gtk_box_append(GTK_BOX(tests), w->testRight);
    gtk_box_append(GTK_BOX(row), tests);

    GtkWidget *sound = gtk_button_new_with_label("Sound…");
    g_signal_connect(sound, "clicked", G_CALLBACK(on_sound), ui);
    gtk_box_append(GTK_BOX(row), sound);
    GtkWidget *tuning = gtk_button_new_with_label("Sync & Balance…");
    g_signal_connect(tuning, "clicked", G_CALLBACK(on_tuning), ui);
    gtk_box_append(GTK_BOX(row), tuning);
    gtk_box_append(GTK_BOX(bottom), row);

    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(grid), 8);
    gtk_grid_set_row_spacing(GTK_GRID(grid), 2);
    w->width = param_scale(ui, GTK_GRID(grid), 0, 0, "Width", 10, 90, 1, fmt_degrees);
    w->surroundLevel = param_scale(ui, GTK_GRID(grid), 1, 0, "Surround", 0, 100, 1, fmt_percent);
    w->orbit = param_scale(ui, GTK_GRID(grid), 0, 1, "Orbit", 0, 2, 0.05, fmt_orbit);
    w->rotation = param_scale(ui, GTK_GRID(grid), 1, 1, "Rotation", -180, 180, 1, fmt_degrees);
    gtk_scale_add_mark(GTK_SCALE(w->rotation), 0, GTK_POS_BOTTOM, NULL);
    w->surroundControls = grid;
    gtk_box_append(GTK_BOX(bottom), grid);

    GtkWidget *row3 = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    w->warning = gtk_label_new("More than 4 Bluetooth speakers may drop out");
    gtk_widget_add_css_class(w->warning, "dl-warning");
    gtk_label_set_xalign(GTK_LABEL(w->warning), 0);
    gtk_label_set_ellipsize(GTK_LABEL(w->warning), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(w->warning, TRUE);
    gtk_box_append(GTK_BOX(row3), w->warning);
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(row3), spacer);
    w->addButton = gtk_button_new_with_label("Add Speaker");
    g_signal_connect(w->addButton, "clicked", G_CALLBACK(on_add), ui);
    gtk_box_append(GTK_BOX(row3), w->addButton);
    w->presetsButton = presets_button(ui);
    gtk_box_append(GTK_BOX(row3), w->presetsButton);
    w->demoButton = gtk_button_new_with_label("Play Demo");
    gtk_widget_set_tooltip_text(w->demoButton, "A 32 second piece that moves around your speakers");
    g_signal_connect(w->demoButton, "clicked", G_CALLBACK(on_demo), ui);
    gtk_box_append(GTK_BOX(row3), w->demoButton);
    gtk_box_append(GTK_BOX(bottom), row3);
    return bottom;
}

void dl_window_build(DLUi *ui)
{
    DLWidgets *w = &ui->w;
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css, kCss);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css),
                                               GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);

    static const GActionEntry actions[] = {
        { "preferences", act_prefs, NULL, NULL, NULL, { 0 } },
        { "setup", act_setup, NULL, NULL, NULL, { 0 } },
        { "quit", act_quit, NULL, NULL, NULL, { 0 } },
    };
    g_action_map_add_action_entries(G_ACTION_MAP(ui->gtkApp), actions, G_N_ELEMENTS(actions), ui);
    const char *quitAccels[] = { "<Control>q", NULL };
    const char *prefsAccels[] = { "<Control>comma", NULL };
    const char *closeAccels[] = { "<Control>w", NULL };
    gtk_application_set_accels_for_action(ui->gtkApp, "app.quit", quitAccels);
    gtk_application_set_accels_for_action(ui->gtkApp, "app.preferences", prefsAccels);
    gtk_application_set_accels_for_action(ui->gtkApp, "window.close", closeAccels);

    w->window = gtk_application_window_new(ui->gtkApp);
    gtk_window_set_title(GTK_WINDOW(w->window), "Domine");
    gtk_window_set_default_size(GTK_WINDOW(w->window), 720, 560);
    gtk_window_set_titlebar(GTK_WINDOW(w->window), build_header(ui));
    g_signal_connect(w->window, "close-request", G_CALLBACK(on_close_request), ui);

    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    w->banner = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(w->banner, "dl-banner");
    GtkWidget *warn = gtk_image_new_from_icon_name("dialog-warning-symbolic");
    gtk_box_append(GTK_BOX(w->banner), warn);
    w->bannerLabel = gtk_label_new("");
    gtk_label_set_wrap(GTK_LABEL(w->bannerLabel), TRUE);
    gtk_label_set_xalign(GTK_LABEL(w->bannerLabel), 0);
    gtk_widget_set_hexpand(w->bannerLabel, TRUE);
    gtk_box_append(GTK_BOX(w->banner), w->bannerLabel);
    gtk_accessible_update_property(GTK_ACCESSIBLE(w->banner), GTK_ACCESSIBLE_PROPERTY_LABEL, "Warning", -1);
    gtk_box_append(GTK_BOX(content), w->banner);

    w->stage = dl_stage_new(ui);
    gtk_box_append(GTK_BOX(content), w->stage);
    gtk_box_append(GTK_BOX(content), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    w->bottomBar = build_bottom(ui);
    gtk_box_append(GTK_BOX(content), w->bottomBar);
    gtk_window_set_child(GTK_WINDOW(w->window), content);

    gtk_range_set_value(GTK_RANGE(w->width), ui->s->width);
    gtk_range_set_value(GTK_RANGE(w->surroundLevel), ui->s->surroundLevel * 100.0);
    gtk_range_set_value(GTK_RANGE(w->orbit), ui->s->orbit);
    gtk_range_set_value(GTK_RANGE(w->rotation), ui->s->rotation);
    dl_ui_sync(ui);
}

void dl_window_present(DLUi *ui)
{
    if (!ui->w.window) return;
    gtk_window_present(GTK_WINDOW(ui->w.window));
    if (ui->held) {
        g_application_release(G_APPLICATION(ui->gtkApp));
        ui->held = 0;
    }
}

// ---- Sync ----

static void set_range(GtkWidget *r, double v)
{
    if (fabs(gtk_range_get_value(GTK_RANGE(r)) - v) > 1e-6) gtk_range_set_value(GTK_RANGE(r), v);
}

static void sync_status(DLUi *ui)
{
    DLWidgets *w = &ui->w;
    char status[300];
    dl_ui_status_text(ui, status, sizeof status);
    gtk_label_set_text(GTK_LABEL(w->subtitle), status);
    gtk_widget_set_tooltip_text(w->subtitle, status);
    gtk_button_set_label(GTK_BUTTON(w->demoButton), ui->demoOn ? "Stop Demo" : "Play Demo");
    set_range(w->master, round(ui->s->master * 100.0));
    char t[16];
    dl_percent_text(ui->s->master, t, sizeof t);
    gtk_label_set_text(GTK_LABEL(w->masterText), t);
}

void dl_window_tick(DLUi *ui)
{
    if (!ui->w.window) return;
    ui->syncing++;
    sync_status(ui);
    ui->syncing--;
    gtk_widget_queue_draw(ui->w.stage);
}

void dl_window_sync(DLUi *ui)
{
    DLWidgets *w = &ui->w;
    if (!w->window) return;
    DLSettings *s = ui->s;
    int surround = dl_ui_is_surround(ui);
    int haveEngine = ui->engine != NULL;
    ui->syncing++;

    sync_status(ui);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(surround ? w->surroundButton : w->stereoButton), TRUE);
    gtk_widget_set_visible(w->swapButton, !surround);
    gtk_widget_set_sensitive(w->swapButton, s->stereo[0].sp.sinkId[0] || s->stereo[1].sp.sinkId[0]);
    gtk_switch_set_active(GTK_SWITCH(w->power), ui->playing);
    gtk_widget_set_sensitive(w->power, haveEngine);

    char banner[512];
    int isError = 0;
    dl_ui_banner_text(ui, banner, sizeof banner, &isError);
    gtk_label_set_text(GTK_LABEL(w->bannerLabel), banner);
    gtk_widget_set_visible(w->banner, banner[0] != '\0');
    if (isError) gtk_widget_add_css_class(w->banner, "error");
    else gtk_widget_remove_css_class(w->banner, "error");

    gtk_widget_set_sensitive(w->bottomBar, haveEngine);
    gtk_widget_set_sensitive(w->stage, haveEngine);
    gtk_widget_set_visible(w->testLeft, !surround);
    gtk_widget_set_visible(w->testRight, !surround);
    gtk_widget_set_sensitive(w->testLeft, ui->playing && ui->cardToEngine[0] >= 0);
    gtk_widget_set_sensitive(w->testRight, ui->playing && ui->cardToEngine[1] >= 0);
    gtk_widget_set_visible(w->surroundControls, surround);
    set_range(w->width, s->width);
    set_range(w->surroundLevel, round(s->surroundLevel * 100.0));
    set_range(w->orbit, s->orbit);
    set_range(w->rotation, s->rotation);
    gtk_widget_set_visible(w->addButton, surround);
    gtk_widget_set_sensitive(w->addButton, s->count < DL_MAX_SPEAKERS);
    gtk_widget_set_visible(w->presetsButton, surround);
    gtk_widget_set_visible(w->warning, surround && s->count > 4);

    ui->syncing--;
    gtk_widget_queue_draw(w->stage);
}
