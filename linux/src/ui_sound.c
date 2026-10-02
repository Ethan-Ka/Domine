// Domine for Linux: Sound dialog (macOS SoundSheet). Preset, Link speakers
// (or a speaker chooser when unlinked), 5 band EQ, bass, compressor, and in
// Surround the ambience (Spatial amount, Room size).
#include <math.h>
#include <string.h>
#include "ui_app.h"
#include "ui_logic.h"
#include "ui_widgets.h"

typedef struct {
    DLUi *ui;
    GtkWidget *win;
    GtkWidget *preset, *link, *speaker;
    GtkWidget *eqOn, *eq[DL_EQ_BANDS], *eqBox;
    GtkWidget *bassOn, *bass;
    GtkWidget *compOn, *comp, *compRow;
    GtkWidget *spatialGroup, *spatial, *room;
    DLMode builtMode;
    uint32_t builtCount;
    uint32_t edited;          // card edited while unlinked
} DLSound;

static DLSound *sound_of(DLUi *ui)
{
    return ui->sound ? g_object_get_data(G_OBJECT(ui->sound), "dl-sound") : NULL;
}

static DLEffects *current_fx(DLSound *d)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(d->ui, &n);
    uint32_t i = *dl_ui_link(d->ui) ? 0 : d->edited;
    return &c[i < n ? i : 0].fx;
}

/// Copies the edited card's effects to every card while linked.
static void commit(DLSound *d)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(d->ui, &n);
    if (*dl_ui_link(d->ui))
        for (uint32_t i = 1; i < n; i++) c[i].fx = c[0].fx;
    dl_ui_effects_changed(d->ui);
    dl_sound_sync(d->ui);
}

// ---- Callbacks ----

static void on_preset(GObject *dd, GParamSpec *p, gpointer data)
{
    (void)p;
    DLSound *d = data;
    if (d->ui->syncing) return;
    guint sel = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (sel == 0 || sel == GTK_INVALID_LIST_POSITION) return;   // "Custom"
    DLEffects fx;
    dl_fx_preset((DLFxPreset)(sel - 1), &fx);
    // A preset replaces the effects of the edited speaker (all while linked).
    *current_fx(d) = fx;
    commit(d);
}

static void on_link(GtkCheckButton *b, gpointer data)
{
    DLSound *d = data;
    if (d->ui->syncing) return;
    *dl_ui_link(d->ui) = gtk_check_button_get_active(b);
    d->edited = 0;
    commit(d);
}

static void on_speaker(GObject *dd, GParamSpec *p, gpointer data)
{
    (void)p;
    DLSound *d = data;
    if (d->ui->syncing) return;
    guint sel = gtk_drop_down_get_selected(GTK_DROP_DOWN(dd));
    if (sel != GTK_INVALID_LIST_POSITION) d->edited = sel;
    dl_sound_sync(d->ui);
}

static void on_toggle(GtkCheckButton *b, gpointer data)
{
    DLSound *d = data;
    if (d->ui->syncing) return;
    DLEffects *fx = current_fx(d);
    int on = gtk_check_button_get_active(b);
    GtkWidget *w = GTK_WIDGET(b);
    if (w == d->eqOn) fx->eqOn = on;
    else if (w == d->bassOn) fx->bassOn = on;
    else if (w == d->compOn) fx->compOn = on;
    commit(d);
}

static void on_value(GtkRange *r, gpointer data)
{
    DLSound *d = data;
    if (d->ui->syncing) return;
    DLEffects *fx = current_fx(d);
    GtkWidget *w = GTK_WIDGET(r);
    double v = gtk_range_get_value(r);
    if (w == d->bass) fx->bass = (float)(v / 100.0);
    else if (w == d->comp) fx->comp = (float)(v / 100.0);
    else fx->eqDb[GPOINTER_TO_INT(g_object_get_data(G_OBJECT(r), "band"))] = (float)round(v);
    commit(d);
}

static void on_spatial(GtkRange *r, gpointer data)
{
    DLSound *d = data;
    if (d->ui->syncing) return;
    if (GTK_WIDGET(r) == d->spatial) d->ui->s->spatial = (float)(gtk_range_get_value(r) / 100.0);
    else d->ui->s->roomMs = (float)gtk_range_get_value(r);
    dl_ui_params_changed(d->ui);
}

static void on_reset(GtkButton *b, gpointer data)
{
    (void)b;
    DLSound *d = data;
    uint32_t n;
    DLCard *c = dl_ui_cards(d->ui, &n);
    for (uint32_t i = 0; i < n; i++) dl_effects_defaults(&c[i].fx);
    if (dl_ui_is_surround(d->ui)) {
        d->ui->s->spatial = 0.6f;
        d->ui->s->roomMs = 15.0f;
        dl_ui_params_changed(d->ui);
    }
    commit(d);
}

static void on_done(GtkButton *b, gpointer data)
{
    (void)b;
    DLSound *d = data;
    gtk_window_close(GTK_WINDOW(d->win));
}

static void on_destroy(GtkWidget *w, gpointer data)
{
    (void)w;
    DLSound *d = data;
    d->ui->sound = NULL;
    g_free(d);
}

// ---- Building ----

static char *fmt_percent(GtkScale *s, double v, gpointer u)
{
    (void)s;
    (void)u;
    return g_strdup_printf("%ld%%", lround(v));
}

static char *fmt_ms(GtkScale *s, double v, gpointer u)
{
    (void)s;
    (void)u;
    return g_strdup_printf("%ld ms", lround(v));
}

static char *fmt_db(GtkScale *s, double v, gpointer u)
{
    (void)s;
    (void)u;
    return g_strdup_printf("%+ld", lround(v));
}

static GtkWidget *labeled_scale(DLSound *d, const char *title, double lo, double hi, double step,
                                GtkScaleFormatValueFunc fmt, GCallback cb, GtkWidget **scale)
{
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *l = gtk_label_new(title);
    gtk_label_set_width_chars(GTK_LABEL(l), 9);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_box_append(GTK_BOX(row), l);
    *scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lo, hi, step);
    gtk_scale_set_draw_value(GTK_SCALE(*scale), TRUE);
    gtk_scale_set_value_pos(GTK_SCALE(*scale), GTK_POS_RIGHT);
    gtk_scale_set_format_value_func(GTK_SCALE(*scale), fmt, NULL, NULL);
    gtk_widget_set_hexpand(*scale, TRUE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(*scale), GTK_ACCESSIBLE_PROPERTY_LABEL, title, -1);
    g_signal_connect(*scale, "value-changed", cb, d);
    gtk_box_append(GTK_BOX(row), *scale);
    return row;
}

static GtkWidget *speaker_chooser(DLSound *d)
{
    uint32_t n;
    dl_ui_cards(d->ui, &n);
    GtkStringList *list = gtk_string_list_new(NULL);
    for (uint32_t i = 0; i < n; i++) {
        char name[32];
        if (dl_ui_is_surround(d->ui)) dl_card_name(DL_MODE_SURROUND, i, name, sizeof name);
        else g_strlcpy(name, i == 0 ? "Left" : "Right", sizeof name);
        gtk_string_list_append(list, name);
    }
    GtkWidget *dd = gtk_drop_down_new(G_LIST_MODEL(list), NULL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(dd), GTK_ACCESSIBLE_PROPERTY_LABEL, "Speaker", -1);
    g_signal_connect(dd, "notify::selected", G_CALLBACK(on_speaker), d);
    return dd;
}

static void build(DLSound *d, GtkWidget *content)
{
    // Preset.
    GtkStringList *presets = gtk_string_list_new(NULL);
    gtk_string_list_append(presets, "Custom");
    for (int p = 0; p < DL_FX_PRESET_COUNT; p++) gtk_string_list_append(presets, dl_fx_preset_name((DLFxPreset)p));
    d->preset = gtk_drop_down_new(G_LIST_MODEL(presets), NULL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(d->preset), GTK_ACCESSIBLE_PROPERTY_LABEL, "Preset", -1);
    g_signal_connect(d->preset, "notify::selected", G_CALLBACK(on_preset), d);
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(row), gtk_label_new("Preset"));
    gtk_box_append(GTK_BOX(row), d->preset);
    gtk_box_append(GTK_BOX(content), row);

    // Link.
    d->link = gtk_check_button_new_with_label("Link speakers");
    g_signal_connect(d->link, "toggled", G_CALLBACK(on_link), d);
    d->speaker = speaker_chooser(d);
    row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_box_append(GTK_BOX(row), d->link);
    gtk_box_append(GTK_BOX(row), d->speaker);
    gtk_box_append(GTK_BOX(content), row);

    // EQ.
    GtkWidget *inner;
    gtk_box_append(GTK_BOX(content), dl_group_new(NULL, &inner));
    d->eqOn = gtk_check_button_new_with_label("EQ");
    g_signal_connect(d->eqOn, "toggled", G_CALLBACK(on_toggle), d);
    gtk_box_append(GTK_BOX(inner), d->eqOn);
    d->eqBox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_box_set_homogeneous(GTK_BOX(d->eqBox), TRUE);
    for (int i = 0; i < DL_EQ_BANDS; i++) {
        GtkWidget *col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
        GtkWidget *s = gtk_scale_new_with_range(GTK_ORIENTATION_VERTICAL, -12, 12, 1);
        gtk_range_set_inverted(GTK_RANGE(s), TRUE);
        gtk_scale_set_draw_value(GTK_SCALE(s), TRUE);
        gtk_scale_set_value_pos(GTK_SCALE(s), GTK_POS_TOP);
        gtk_scale_set_format_value_func(GTK_SCALE(s), fmt_db, NULL, NULL);
        gtk_scale_add_mark(GTK_SCALE(s), 0, GTK_POS_RIGHT, NULL);
        gtk_widget_set_size_request(s, -1, 120);
        gtk_widget_set_halign(s, GTK_ALIGN_CENTER);
        char a11y[32];
        g_snprintf(a11y, sizeof a11y, "%s gain", dl_eq_band_labels[i]);
        gtk_accessible_update_property(GTK_ACCESSIBLE(s), GTK_ACCESSIBLE_PROPERTY_LABEL, a11y, -1);
        g_object_set_data(G_OBJECT(s), "band", GINT_TO_POINTER(i));
        g_signal_connect(s, "value-changed", G_CALLBACK(on_value), d);
        d->eq[i] = s;
        gtk_box_append(GTK_BOX(col), s);
        GtkWidget *l = dl_caption(dl_eq_band_labels[i]);
        gtk_label_set_xalign(GTK_LABEL(l), 0.5f);
        gtk_box_append(GTK_BOX(col), l);
        gtk_box_append(GTK_BOX(d->eqBox), col);
    }
    gtk_box_append(GTK_BOX(inner), d->eqBox);

    // Bass.
    gtk_box_append(GTK_BOX(content), dl_group_new(NULL, &inner));
    d->bassOn = gtk_check_button_new_with_label("Bass");
    g_signal_connect(d->bassOn, "toggled", G_CALLBACK(on_toggle), d);
    gtk_box_append(GTK_BOX(inner), d->bassOn);
    gtk_box_append(GTK_BOX(inner), labeled_scale(d, "Amount", 0, 100, 1, fmt_percent, G_CALLBACK(on_value), &d->bass));

    // Compressor.
    gtk_box_append(GTK_BOX(content), dl_group_new(NULL, &inner));
    d->compOn = gtk_check_button_new_with_label("Compressor");
    g_signal_connect(d->compOn, "toggled", G_CALLBACK(on_toggle), d);
    gtk_box_append(GTK_BOX(inner), d->compOn);
    d->compRow = labeled_scale(d, "Amount", 0, 100, 1, fmt_percent, G_CALLBACK(on_value), &d->comp);
    gtk_box_append(GTK_BOX(inner), d->compRow);

    // Surround ambience.
    d->spatialGroup = dl_group_new("AMBIENCE", &inner);
    gtk_box_append(GTK_BOX(inner), labeled_scale(d, "Spatial", 0, 100, 1, fmt_percent, G_CALLBACK(on_spatial), &d->spatial));
    gtk_box_append(GTK_BOX(inner), labeled_scale(d, "Room size", 5, 30, 1, fmt_ms, G_CALLBACK(on_spatial), &d->room));
    gtk_box_append(GTK_BOX(content), d->spatialGroup);

    GtkWidget *reset = gtk_button_new_with_label("Reset");
    g_signal_connect(reset, "clicked", G_CALLBACK(on_reset), d);
    GtkWidget *done = gtk_button_new_with_label("Done");
    gtk_widget_add_css_class(done, "suggested-action");
    g_signal_connect(done, "clicked", G_CALLBACK(on_done), d);
    gtk_box_append(GTK_BOX(content), dl_button_row(reset, done));
    gtk_window_set_default_widget(GTK_WINDOW(d->win), done);
}

void dl_sound_sync(DLUi *ui)
{
    DLSound *d = sound_of(ui);
    if (!d) return;
    uint32_t n;
    dl_ui_cards(ui, &n);
    if (d->builtMode != ui->s->mode || d->builtCount != n) {
        // The speaker list changed: rebuild the chooser.
        GtkWidget *parent = gtk_widget_get_parent(d->speaker);
        gtk_box_remove(GTK_BOX(parent), d->speaker);
        d->speaker = speaker_chooser(d);
        gtk_box_append(GTK_BOX(parent), d->speaker);
        d->builtMode = ui->s->mode;
        d->builtCount = n;
        if (d->edited >= n) d->edited = 0;
    }
    int linked = *dl_ui_link(ui);
    const DLEffects *fx = current_fx(d);
    int match = dl_fx_match(fx);
    ui->syncing++;
    gtk_drop_down_set_selected(GTK_DROP_DOWN(d->preset), match < 0 ? 0 : (guint)match + 1);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(d->link), linked);
    gtk_widget_set_visible(d->speaker, !linked);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(d->speaker), d->edited);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(d->eqOn), fx->eqOn);
    for (int i = 0; i < DL_EQ_BANDS; i++) gtk_range_set_value(GTK_RANGE(d->eq[i]), fx->eqDb[i]);
    gtk_widget_set_sensitive(d->eqBox, fx->eqOn);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(d->bassOn), fx->bassOn);
    gtk_range_set_value(GTK_RANGE(d->bass), fx->bass * 100.0);
    gtk_widget_set_sensitive(d->bass, fx->bassOn);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(d->compOn), fx->compOn);
    gtk_range_set_value(GTK_RANGE(d->comp), fx->comp * 100.0);
    gtk_widget_set_sensitive(d->compRow, fx->compOn);
    gtk_widget_set_visible(d->spatialGroup, dl_ui_is_surround(ui));
    gtk_range_set_value(GTK_RANGE(d->spatial), ui->s->spatial * 100.0);
    gtk_range_set_value(GTK_RANGE(d->room), ui->s->roomMs);
    ui->syncing--;
}

void dl_sound_open(DLUi *ui)
{
    if (ui->sound) {
        gtk_window_present(GTK_WINDOW(ui->sound));
        return;
    }
    DLSound *d = g_new0(DLSound, 1);
    d->ui = ui;
    GtkWidget *content;
    d->win = dl_dialog_new(ui, "Sound", 420, &content);
    uint32_t n;
    dl_ui_cards(ui, &n);
    d->builtMode = ui->s->mode;
    d->builtCount = n;
    build(d, content);
    g_object_set_data(G_OBJECT(d->win), "dl-sound", d);
    g_signal_connect(d->win, "destroy", G_CALLBACK(on_destroy), d);
    ui->sound = d->win;
    dl_sound_sync(ui);
    gtk_window_present(GTK_WINDOW(d->win));
}
