// Domine for Linux: Preferences window (macOS Settings). General: closing
// behaviour, start playing at launch, launch at login (XDG autostart), volume
// keys note, setup guide. Exclusions: where excluded apps play, the excluded
// apps with +/- and per-app volume, and the volume of every playing app.
#include <glib/gstdio.h>
#include <math.h>
#include <string.h>
#include "ui_app.h"
#include "ui_logic.h"
#include "ui_widgets.h"

typedef struct {
    DLUi *ui;
    GtkWidget *win;
    GtkWidget *quit, *keep, *startPlaying, *login, *loginError;
    GtkWidget *sinkBox, *sinkDrop;
    GtkWidget *excluded, *playing, *addButton, *removeButton;
    char *signature;
} DLPrefs;

static DLPrefs *prefs_of(DLUi *ui)
{
    return ui->prefs ? g_object_get_data(G_OBJECT(ui->prefs), "dl-prefs") : NULL;
}

// ---- Autostart ----

int dl_autostart_set(int enabled)
{
    char *dir = g_build_filename(g_get_user_config_dir(), "autostart", NULL);
    char *path = g_build_filename(dir, "io.github.ethanka.Domine.desktop", NULL);
    int rc = 0;
    if (!enabled) {
        if (g_file_test(path, G_FILE_TEST_EXISTS) && g_remove(path) != 0) rc = -1;
    } else {
        char *exe = g_file_read_link("/proc/self/exe", NULL);
        if (!exe) exe = g_strdup("domine");
        char *quoted = strchr(exe, ' ') ? g_strdup_printf("\"%s\"", exe) : g_strdup(exe);
        char *body = g_strdup_printf("[Desktop Entry]\nType=Application\nName=Domine\n"
                                     "Comment=Start Domine in the background\nExec=%s --background\n"
                                     "Icon=audio-speakers\nTerminal=false\nX-GNOME-Autostart-enabled=true\n",
                                     quoted);
        if (g_mkdir_with_parents(dir, 0700) != 0 || !g_file_set_contents(path, body, -1, NULL)) rc = -1;
        g_free(body);
        g_free(quoted);
        g_free(exe);
    }
    g_free(path);
    g_free(dir);
    return rc;
}

// ---- General ----

static void on_close_mode(GtkCheckButton *b, gpointer data)
{
    DLPrefs *p = data;
    if (p->ui->syncing || !gtk_check_button_get_active(b)) return;
    p->ui->s->keepRunning = GTK_WIDGET(b) == p->keep;
    dl_ui_schedule_save(p->ui);
}

static void on_start_playing(GtkCheckButton *b, gpointer data)
{
    DLPrefs *p = data;
    if (p->ui->syncing) return;
    p->ui->s->startPlaying = gtk_check_button_get_active(b);
    dl_ui_schedule_save(p->ui);
}

static void on_login(GtkCheckButton *b, gpointer data)
{
    DLPrefs *p = data;
    if (p->ui->syncing) return;
    int on = gtk_check_button_get_active(b);
    int ok = dl_autostart_set(on) == 0;
    gtk_widget_set_visible(p->loginError, !ok);
    p->ui->s->launchAtLogin = ok ? on : !on;
    dl_ui_schedule_save(p->ui);
    dl_prefs_sync(p->ui);
}

static void on_setup(GtkButton *b, gpointer data)
{
    (void)b;
    dl_welcome_open(((DLPrefs *)data)->ui);
}

static GtkWidget *form_label(const char *text)
{
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 1);
    gtk_widget_set_valign(l, GTK_ALIGN_START);
    return l;
}

static GtkWidget *build_general(DLPrefs *p)
{
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_widget_set_margin_start(grid, 32);
    gtk_widget_set_margin_end(grid, 32);
    gtk_widget_set_margin_top(grid, 24);
    gtk_widget_set_margin_bottom(grid, 24);

    gtk_grid_attach(GTK_GRID(grid), form_label("Closing the window:"), 0, 0, 1, 1);
    GtkWidget *col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    p->quit = gtk_check_button_new_with_label("Quits Domine");
    p->keep = gtk_check_button_new_with_label("Keeps Domine playing in the background");
    gtk_check_button_set_group(GTK_CHECK_BUTTON(p->keep), GTK_CHECK_BUTTON(p->quit));
    g_signal_connect(p->quit, "toggled", G_CALLBACK(on_close_mode), p);
    g_signal_connect(p->keep, "toggled", G_CALLBACK(on_close_mode), p);
    gtk_box_append(GTK_BOX(col), p->quit);
    gtk_box_append(GTK_BOX(col), p->keep);
    gtk_box_append(GTK_BOX(col), dl_caption("Open Domine again to bring the window back. GTK 4 has no tray icon, "
                                            "so Quit is in the window menu."));
    gtk_grid_attach(GTK_GRID(grid), col, 1, 0, 1, 1);

    col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    p->startPlaying = gtk_check_button_new_with_label("Start playing when Domine opens");
    g_signal_connect(p->startPlaying, "toggled", G_CALLBACK(on_start_playing), p);
    gtk_box_append(GTK_BOX(col), p->startPlaying);
    p->login = gtk_check_button_new_with_label("Launch at login");
    g_signal_connect(p->login, "toggled", G_CALLBACK(on_login), p);
    gtk_box_append(GTK_BOX(col), p->login);
    p->loginError = dl_caption("Could not write the autostart entry in ~/.config/autostart.");
    gtk_widget_set_visible(p->loginError, FALSE);
    gtk_box_append(GTK_BOX(col), p->loginError);
    gtk_grid_attach(GTK_GRID(grid), col, 1, 1, 1, 1);

    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 2, 2, 1);
    gtk_grid_attach(GTK_GRID(grid), form_label("Volume keys:"), 0, 3, 1, 1);
    GtkWidget *keys = dl_caption("While Domine plays, the desktop volume keys and the sound settings change "
                                 "Domine's master volume. Each speaker's own volume stays where it is.");
    gtk_label_set_max_width_chars(GTK_LABEL(keys), 50);
    gtk_grid_attach(GTK_GRID(grid), keys, 1, 3, 1, 1);

    gtk_grid_attach(GTK_GRID(grid), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), 0, 4, 2, 1);
    gtk_grid_attach(GTK_GRID(grid), form_label("Setup:"), 0, 5, 1, 1);
    GtkWidget *setup = gtk_button_new_with_label("Show Setup Guide…");
    gtk_widget_set_halign(setup, GTK_ALIGN_START);
    g_signal_connect(setup, "clicked", G_CALLBACK(on_setup), p);
    gtk_grid_attach(GTK_GRID(grid), setup, 1, 5, 1, 1);
    return grid;
}

// ---- Exclusions ----

static void on_exclude_sink(GObject *dd, GParamSpec *ps, gpointer data)
{
    (void)ps;
    DLPrefs *p = data;
    if (p->ui->syncing) return;
    char **ids = g_object_get_data(dd, "ids");
    guint sel = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (ids && sel < g_strv_length(ids)) dl_ui_set_exclude_sink(p->ui, ids[sel]);
}

static void on_app_volume(GtkRange *r, gpointer data)
{
    DLPrefs *p = data;
    if (p->ui->syncing) return;
    const char *key = g_object_get_data(G_OBJECT(r), "key");
    const char *label = g_object_get_data(G_OBJECT(r), "label");
    dl_ui_set_app_volume(p->ui, key, label, dl_slider_to_volume((float)(gtk_range_get_value(r) / 100.0)));
}

static void on_add_app(GtkButton *b, gpointer data)
{
    DLPrefs *p = data;
    GtkWidget *pop = gtk_widget_get_ancestor(GTK_WIDGET(b), GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
    dl_ui_set_app_excluded(p->ui, g_object_get_data(G_OBJECT(b), "key"), g_object_get_data(G_OBJECT(b), "label"), 1);
    dl_prefs_sync(p->ui);
}

static void on_remove_app(GtkButton *b, gpointer data)
{
    (void)b;
    DLPrefs *p = data;
    GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(p->excluded));
    if (!row) return;
    const char *key = g_object_get_data(G_OBJECT(row), "key");
    if (key) {
        char *k = g_strdup(key);
        dl_ui_set_app_excluded(p->ui, k, NULL, 0);
        g_free(k);
    }
    dl_prefs_sync(p->ui);
}

static void on_selection(GtkListBox *box, GtkListBoxRow *row, gpointer data)
{
    (void)box;
    DLPrefs *p = data;
    gtk_widget_set_sensitive(p->removeButton, row != NULL);
}

static const DLApp *running_app(DLUi *ui, const char *key)
{
    for (uint32_t i = 0; i < ui->appCount; i++)
        if (strcmp(ui->apps[i].key, key) == 0) return &ui->apps[i];
    return NULL;
}

static GtkWidget *app_row(DLPrefs *p, const char *key, const char *label, const DLApp *running)
{
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_margin_start(box, 8);
    gtk_widget_set_margin_end(box, 8);
    gtk_widget_set_margin_top(box, 4);
    gtk_widget_set_margin_bottom(box, 4);
    GtkWidget *icon = gtk_image_new_from_icon_name("application-x-executable-symbolic");
    gtk_box_append(GTK_BOX(box), icon);
    GtkWidget *name = gtk_label_new(label[0] ? label : key);
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(name, TRUE);
    gtk_box_append(GTK_BOX(box), name);
    if (running) {
        GtkWidget *scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 1);
        gtk_scale_set_draw_value(GTK_SCALE(scale), FALSE);
        gtk_widget_set_size_request(scale, 140, -1);
        gtk_range_set_value(GTK_RANGE(scale), round(dl_volume_to_slider(running->volume) * 100.0));
        g_object_set_data_full(G_OBJECT(scale), "key", g_strdup(key), g_free);
        g_object_set_data_full(G_OBJECT(scale), "label", g_strdup(label), g_free);
        char a11y[300];
        g_snprintf(a11y, sizeof a11y, "Volume of %s", label);
        gtk_accessible_update_property(GTK_ACCESSIBLE(scale), GTK_ACCESSIBLE_PROPERTY_LABEL, a11y, -1);
        g_signal_connect(scale, "value-changed", G_CALLBACK(on_app_volume), p);
        gtk_box_append(GTK_BOX(box), scale);
    } else {
        gtk_box_append(GTK_BOX(box), dl_caption("Not playing"));
    }
    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data_full(G_OBJECT(row), "key", g_strdup(key), g_free);
    return row;
}

static void clear_list(GtkWidget *list)
{
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(list)) != NULL) gtk_list_box_remove(GTK_LIST_BOX(list), child);
}

static GtkWidget *bordered_list(GtkWidget **list, GtkSelectionMode mode, const char *empty, int height)
{
    *list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(*list), mode);
    GtkWidget *placeholder = gtk_label_new(empty);
    gtk_widget_add_css_class(placeholder, "dim-label");
    gtk_widget_set_margin_top(placeholder, 12);
    gtk_widget_set_margin_bottom(placeholder, 12);
    gtk_list_box_set_placeholder(GTK_LIST_BOX(*list), placeholder);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), height);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), *list);
    GtkWidget *frame = gtk_frame_new(NULL);
    gtk_frame_set_child(GTK_FRAME(frame), scroll);
    return frame;
}

static GtkWidget *build_exclusions(DLPrefs *p)
{
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_start(box, 32);
    gtk_widget_set_margin_end(box, 32);
    gtk_widget_set_margin_top(box, 20);
    gtk_widget_set_margin_bottom(box, 20);

    p->sinkBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(p->sinkBox), gtk_label_new("Excluded apps play through:"));
    gtk_box_append(GTK_BOX(box), p->sinkBox);

    GtkWidget *col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_append(GTK_BOX(col), bordered_list(&p->excluded, GTK_SELECTION_SINGLE,
                                               "No excluded apps. They all play through Domine.", 110));
    g_signal_connect(p->excluded, "row-selected", G_CALLBACK(on_selection), p);
    GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(bar, "linked");
    p->addButton = gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(p->addButton), "list-add-symbolic");
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(p->addButton), gtk_popover_new());
    gtk_widget_set_tooltip_text(p->addButton, "Exclude a playing app");
    p->removeButton = gtk_button_new_from_icon_name("list-remove-symbolic");
    gtk_widget_set_tooltip_text(p->removeButton, "Stop excluding the selected app");
    gtk_widget_set_sensitive(p->removeButton, FALSE);
    g_signal_connect(p->removeButton, "clicked", G_CALLBACK(on_remove_app), p);
    gtk_box_append(GTK_BOX(bar), p->addButton);
    gtk_box_append(GTK_BOX(bar), p->removeButton);
    gtk_widget_set_margin_top(bar, 4);
    gtk_box_append(GTK_BOX(col), bar);
    gtk_box_append(GTK_BOX(box), col);

    GtkWidget *title = gtk_label_new("PLAYING APPS");
    gtk_widget_add_css_class(title, "dl-section");
    gtk_label_set_xalign(GTK_LABEL(title), 0);
    gtk_box_append(GTK_BOX(box), title);
    gtk_box_append(GTK_BOX(box), bordered_list(&p->playing, GTK_SELECTION_NONE, "No apps are playing", 110));
    return box;
}

static void rebuild_exclusions(DLPrefs *p)
{
    DLUi *ui = p->ui;
    // Output chooser.
    if (p->sinkDrop) gtk_box_remove(GTK_BOX(p->sinkBox), p->sinkDrop);
    GPtrArray *labels = g_ptr_array_new_with_free_func(g_free);
    GPtrArray *ids = g_ptr_array_new();
    g_ptr_array_add(labels, g_strdup("Previous output"));
    g_ptr_array_add(ids, g_strdup(""));
    guint selected = 0, found = ui->s->excludeSinkId[0] == '\0';
    for (uint32_t i = 0; i < ui->sinkCount; i++) {
        char label[300];
        dl_ui_sink_label(ui, ui->sinks[i].id, label, sizeof label, NULL);
        if (strcmp(ui->sinks[i].id, ui->s->excludeSinkId) == 0) {
            selected = labels->len;
            found = 1;
        }
        g_ptr_array_add(labels, g_strdup(label));
        g_ptr_array_add(ids, g_strdup(ui->sinks[i].id));
    }
    if (!found) {
        // Keep a saved choice that is not connected, marked as such.
        char label[300];
        dl_ui_sink_label(ui, ui->s->excludeSinkId, label, sizeof label, NULL);
        g_strlcat(label, ", not connected", sizeof label);
        selected = labels->len;
        g_ptr_array_add(labels, g_strdup(label));
        g_ptr_array_add(ids, g_strdup(ui->s->excludeSinkId));
    }
    g_ptr_array_add(labels, NULL);
    g_ptr_array_add(ids, NULL);
    p->sinkDrop = gtk_drop_down_new_from_strings((const char *const *)labels->pdata);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(p->sinkDrop), selected);
    g_object_set_data_full(G_OBJECT(p->sinkDrop), "ids", g_ptr_array_free(ids, FALSE), (GDestroyNotify)g_strfreev);
    g_ptr_array_free(labels, TRUE);
    g_signal_connect(p->sinkDrop, "notify::selected", G_CALLBACK(on_exclude_sink), p);
    gtk_box_append(GTK_BOX(p->sinkBox), p->sinkDrop);

    // Excluded apps (saved), then every playing app that is not excluded.
    clear_list(p->excluded);
    clear_list(p->playing);
    GtkWidget *menu = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    for (uint32_t i = 0; i < ui->s->appCount; i++) {
        const DLAppPref *a = &ui->s->apps[i];
        if (a->excluded)
            gtk_list_box_append(GTK_LIST_BOX(p->excluded), app_row(p, a->key, a->label, running_app(ui, a->key)));
    }
    int addable = 0;
    for (uint32_t i = 0; i < ui->appCount; i++) {
        const DLApp *app = &ui->apps[i];
        const DLAppPref *a = dl_ui_app_pref(ui, app->key, NULL, 0);
        if (a && a->excluded) continue;
        gtk_list_box_append(GTK_LIST_BOX(p->playing), app_row(p, app->key, app->label, app));
        GtkWidget *b = gtk_button_new_with_label(app->label[0] ? app->label : app->key);
        gtk_widget_add_css_class(b, "flat");
        g_object_set_data_full(G_OBJECT(b), "key", g_strdup(app->key), g_free);
        g_object_set_data_full(G_OBJECT(b), "label", g_strdup(app->label), g_free);
        g_signal_connect(b, "clicked", G_CALLBACK(on_add_app), p);
        gtk_box_append(GTK_BOX(menu), b);
        addable = 1;
    }
    if (!addable) gtk_box_append(GTK_BOX(menu), dl_caption("No other apps are playing"));
    gtk_popover_set_child(gtk_menu_button_get_popover(GTK_MENU_BUTTON(p->addButton)), menu);
    gtk_widget_set_sensitive(p->removeButton, FALSE);
}

static char *exclusions_signature(DLUi *ui)
{
    GString *g = g_string_new(ui->s->excludeSinkId);
    for (uint32_t i = 0; i < ui->sinkCount; i++) g_string_append_printf(g, "|s%s%d", ui->sinks[i].id, ui->sinks[i].available);
    for (uint32_t i = 0; i < ui->s->appCount; i++)
        g_string_append_printf(g, "|p%s%d", ui->s->apps[i].key, ui->s->apps[i].excluded);
    for (uint32_t i = 0; i < ui->appCount; i++) g_string_append_printf(g, "|a%s", ui->apps[i].key);
    return g_string_free(g, FALSE);
}

// ---- Window ----

static void on_destroy(GtkWidget *w, gpointer data)
{
    (void)w;
    DLPrefs *p = data;
    p->ui->prefs = NULL;
    g_free(p->signature);
    g_free(p);
}

void dl_prefs_sync(DLUi *ui)
{
    DLPrefs *p = prefs_of(ui);
    if (!p) return;
    ui->syncing++;
    gtk_check_button_set_active(GTK_CHECK_BUTTON(ui->s->keepRunning ? p->keep : p->quit), TRUE);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(p->startPlaying), ui->s->startPlaying);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(p->login), ui->s->launchAtLogin);
    char *sig = exclusions_signature(ui);
    if (!p->signature || strcmp(sig, p->signature) != 0) {
        rebuild_exclusions(p);
        g_free(p->signature);
        p->signature = sig;
    } else {
        g_free(sig);
    }
    ui->syncing--;
}

void dl_prefs_open(DLUi *ui)
{
    if (ui->prefs) {
        gtk_window_present(GTK_WINDOW(ui->prefs));
        return;
    }
    DLPrefs *p = g_new0(DLPrefs, 1);
    p->ui = ui;
    p->win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(p->win), "Preferences");
    gtk_window_set_default_size(GTK_WINDOW(p->win), 560, 420);
    if (ui->w.window) gtk_window_set_transient_for(GTK_WINDOW(p->win), GTK_WINDOW(ui->w.window));
    gtk_window_set_destroy_with_parent(GTK_WINDOW(p->win), TRUE);

    GtkWidget *stack = gtk_stack_new();
    gtk_stack_add_titled(GTK_STACK(stack), build_general(p), "general", "General");
    gtk_stack_add_titled(GTK_STACK(stack), build_exclusions(p), "exclusions", "Exclusions");
    GtkWidget *switcher = gtk_stack_switcher_new();
    gtk_stack_switcher_set_stack(GTK_STACK_SWITCHER(switcher), GTK_STACK(stack));
    GtkWidget *bar = gtk_header_bar_new();
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(bar), switcher);
    gtk_window_set_titlebar(GTK_WINDOW(p->win), bar);
    gtk_window_set_child(GTK_WINDOW(p->win), stack);

    GtkEventController *keys = gtk_shortcut_controller_new();
    gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(keys),
        gtk_shortcut_new(gtk_shortcut_trigger_parse_string("Escape"), gtk_named_action_new("window.close")));
    gtk_widget_add_controller(p->win, keys);

    g_object_set_data(G_OBJECT(p->win), "dl-prefs", p);
    g_signal_connect(p->win, "destroy", G_CALLBACK(on_destroy), p);
    ui->prefs = p->win;
    dl_prefs_sync(ui);
    gtk_window_present(GTK_WINDOW(p->win));
}
