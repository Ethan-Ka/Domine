// Domine for Linux: Sync & Balance dialog (macOS TuningSheet). Stereo: one
// signed delay offset (+-50 ms, or +-300 with Extended range) and Balance.
// Surround: a delay and a trim per speaker. Both: click test, reported
// latencies, Reset / Done, and the demo on its own row.
#include <math.h>
#include <string.h>
#include "ui_app.h"
#include "ui_geometry.h"
#include "ui_logic.h"
#include "ui_widgets.h"

typedef struct {
    DLUi *ui;
    GtkWidget *win;
    GtkWidget *body;
    DLMode builtMode;
    uint32_t builtCount;
    GtkWidget *delay, *delayValue, *extended, *balance, *balanceValue;
    GtkWidget *delays[DL_MAX_SPEAKERS], *delayValues[DL_MAX_SPEAKERS];
    GtkWidget *trims[DL_MAX_SPEAKERS], *trimValues[DL_MAX_SPEAKERS];
    GtkWidget *click, *latency, *demo, *demoCaption;
    guint timer;
} DLTuning;

static DLTuning *tuning_of(DLUi *ui)
{
    return ui->tuning ? g_object_get_data(G_OBJECT(ui->tuning), "dl-tuning") : NULL;
}

static void update_readouts(DLTuning *t)
{
    DLUi *ui = t->ui;
    char buf[64];
    if (t->builtMode == DL_MODE_STEREO) {
        dl_delay_readout(ui->s->stereoDelay, buf, sizeof buf);
        gtk_label_set_text(GTK_LABEL(t->delayValue), buf);
        dl_balance_readout(ui->s->balance, buf, sizeof buf);
        gtk_label_set_text(GTK_LABEL(t->balanceValue), buf);
    } else {
        for (uint32_t i = 0; i < t->builtCount; i++) {
            dl_delay_short(ui->s->cards[i].delayMs, buf, sizeof buf);
            gtk_label_set_text(GTK_LABEL(t->delayValues[i]), buf);
            dl_percent_text(ui->s->cards[i].sp.trim, buf, sizeof buf);
            gtk_label_set_text(GTK_LABEL(t->trimValues[i]), buf);
        }
    }
}

static void update_live(DLTuning *t)
{
    DLUi *ui = t->ui;
    gtk_button_set_label(GTK_BUTTON(t->click), ui->clickTest ? "Stop Click Test" : "Play Click Test");
    gtk_widget_set_sensitive(t->click, ui->playing);

    GString *g = g_string_new(NULL);
    if (!ui->playing) {
        g_string_append(g, "Turn Domine on to see the latency each speaker reports.");
    } else {
        g_string_append(g, "Reported latency: ");
        for (uint32_t k = 0; k < ui->engineCount; k++) {
            char name[32];
            uint32_t card = ui->engineToCard[k];
            if (dl_ui_is_surround(ui)) dl_card_name(DL_MODE_SURROUND, card, name, sizeof name);
            else g_strlcpy(name, card == 0 ? "left" : "right", sizeof name);
            float ms = dl_engine_reported_latency_ms(ui->engine, k);
            if (k) g_string_append(g, ", ");
            if (ms >= 0) g_string_append_printf(g, "%s %ld ms", name, lroundf(ms));
            else g_string_append_printf(g, "%s unknown", name);
        }
    }
    gtk_label_set_text(GTK_LABEL(t->latency), g->str);
    g_string_free(g, TRUE);

    gtk_button_set_label(GTK_BUTTON(t->demo), ui->demoOn ? "Stop Demo" : "Play Demo");
    gtk_widget_set_sensitive(t->demo, ui->engine != NULL);
    const char *section = dl_demo_section_name(ui->demoSection);
    char caption[96];
    if (ui->demoOn) g_snprintf(caption, sizeof caption, "Now playing: %s", section[0] ? section : "starting");
    else g_strlcpy(caption, "A short piece that moves around your speakers.", sizeof caption);
    gtk_label_set_text(GTK_LABEL(t->demoCaption), caption);
}

// ---- Callbacks ----

static void on_delay(GtkRange *r, gpointer data)
{
    DLTuning *t = data;
    if (t->ui->syncing) return;
    t->ui->s->stereoDelay = (float)round(gtk_range_get_value(r));
    update_readouts(t);
    dl_ui_tuning_changed(t->ui);
}

static void on_extended(GtkCheckButton *b, gpointer data)
{
    DLTuning *t = data;
    DLUi *ui = t->ui;
    if (ui->syncing) return;
    ui->s->stereoExtended = gtk_check_button_get_active(b);
    float lim = ui->s->stereoExtended ? DL_DELAY_LIMIT : DL_STEREO_DELAY_NORMAL;
    if (ui->s->stereoDelay > lim) ui->s->stereoDelay = lim;
    if (ui->s->stereoDelay < -lim) ui->s->stereoDelay = -lim;
    dl_ui_tuning_changed(ui);
    dl_tuning_sync(ui);
}

static void on_balance(GtkRange *r, gpointer data)
{
    DLTuning *t = data;
    if (t->ui->syncing) return;
    t->ui->s->balance = (float)(gtk_range_get_value(r) / 100.0);
    update_readouts(t);
    dl_ui_tuning_changed(t->ui);
}

static void on_card_delay(GtkRange *r, gpointer data)
{
    DLTuning *t = data;
    if (t->ui->syncing) return;
    guint i = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(r), "card"));
    if (i >= t->ui->s->count) return;
    t->ui->s->cards[i].delayMs = (float)round(gtk_range_get_value(r));
    update_readouts(t);
    dl_ui_tuning_changed(t->ui);
}

static void on_card_trim(GtkRange *r, gpointer data)
{
    DLTuning *t = data;
    if (t->ui->syncing) return;
    guint i = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(r), "card"));
    if (i >= t->ui->s->count) return;
    t->ui->s->cards[i].sp.trim = (float)(gtk_range_get_value(r) / 100.0);
    update_readouts(t);
    dl_ui_tuning_changed(t->ui);
}

static void on_click(GtkButton *b, gpointer data)
{
    (void)b;
    DLTuning *t = data;
    dl_ui_set_click_test(t->ui, !t->ui->clickTest);
    update_live(t);
}

static void on_reset(GtkButton *b, gpointer data)
{
    (void)b;
    DLTuning *t = data;
    DLSettings *s = t->ui->s;
    if (s->mode == DL_MODE_STEREO) {
        s->stereoDelay = 0;
        s->stereoExtended = 0;
        s->balance = 0;
    } else {
        for (uint32_t i = 0; i < s->count; i++) {
            s->cards[i].delayMs = 0;
            s->cards[i].sp.trim = 1.0f;
        }
    }
    dl_ui_tuning_changed(t->ui);
    dl_tuning_sync(t->ui);
}

static void on_done(GtkButton *b, gpointer data)
{
    (void)b;
    DLTuning *t = data;
    gtk_window_close(GTK_WINDOW(t->win));
}

static void on_demo(GtkButton *b, gpointer data)
{
    (void)b;
    DLTuning *t = data;
    dl_ui_toggle_demo(t->ui);
    update_live(t);
}

static gboolean on_timer(gpointer data)
{
    update_live(data);
    return G_SOURCE_CONTINUE;
}

static void on_destroy(GtkWidget *w, gpointer data)
{
    (void)w;
    DLTuning *t = data;
    if (t->timer) g_source_remove(t->timer);
    if (t->ui->clickTest) dl_ui_set_click_test(t->ui, 0);
    t->ui->tuning = NULL;
    g_free(t);
}

// ---- Building ----

static GtkWidget *hscale(double lo, double hi, double step, const char *a11y)
{
    GtkWidget *s = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lo, hi, step);
    gtk_scale_set_draw_value(GTK_SCALE(s), FALSE);
    gtk_widget_set_hexpand(s, TRUE);
    gtk_accessible_update_property(GTK_ACCESSIBLE(s), GTK_ACCESSIBLE_PROPERTY_LABEL, a11y, -1);
    return s;
}

static GtkWidget *click_row(DLTuning *t, GtkWidget *leading)
{
    t->click = gtk_button_new_with_label("Play Click Test");
    gtk_widget_set_tooltip_text(t->click, "A click on every speaker once a second. Move the slider until they line up.");
    g_signal_connect(t->click, "clicked", G_CALLBACK(on_click), t);
    return dl_button_row(leading, t->click);
}

static void build_stereo(DLTuning *t, GtkWidget *body)
{
    GtkWidget *inner;
    gtk_box_append(GTK_BOX(body), dl_group_new("TIMING", &inner));
    gtk_box_append(GTK_BOX(inner), dl_readout_row("Delay offset", &t->delayValue));
    t->delay = hscale(-DL_STEREO_DELAY_NORMAL, DL_STEREO_DELAY_NORMAL, 1, "Delay offset");
    gtk_scale_add_mark(GTK_SCALE(t->delay), 0, GTK_POS_BOTTOM, NULL);
    g_signal_connect(t->delay, "value-changed", G_CALLBACK(on_delay), t);
    gtk_box_append(GTK_BOX(inner), t->delay);
    gtk_box_append(GTK_BOX(inner), dl_end_labels("Delay left", "Delay right"));
    t->extended = gtk_check_button_new_with_label("Extended range (±300 ms)");
    g_signal_connect(t->extended, "toggled", G_CALLBACK(on_extended), t);
    gtk_box_append(GTK_BOX(inner), click_row(t, t->extended));
    t->latency = dl_caption("");
    gtk_box_append(GTK_BOX(inner), t->latency);

    gtk_box_append(GTK_BOX(body), dl_group_new("LEVEL", &inner));
    gtk_box_append(GTK_BOX(inner), dl_readout_row("Balance", &t->balanceValue));
    t->balance = hscale(-100, 100, 1, "Balance");
    gtk_scale_add_mark(GTK_SCALE(t->balance), 0, GTK_POS_BOTTOM, NULL);
    g_signal_connect(t->balance, "value-changed", G_CALLBACK(on_balance), t);
    gtk_box_append(GTK_BOX(inner), t->balance);
    gtk_box_append(GTK_BOX(inner), dl_end_labels("Left", "Right"));
}

static GtkWidget *speaker_grid(DLTuning *t, int trims)
{
    GtkWidget *grid = gtk_grid_new();
    gtk_grid_set_column_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_row_spacing(GTK_GRID(grid), 2);
    for (uint32_t i = 0; i < t->builtCount; i++) {
        char name[32], a11y[64];
        dl_card_name(DL_MODE_SURROUND, i, name, sizeof name);
        GtkWidget *label = gtk_label_new(name);
        gtk_label_set_xalign(GTK_LABEL(label), 0);
        gtk_grid_attach(GTK_GRID(grid), label, 0, (int)i, 1, 1);
        GtkWidget *value = gtk_label_new("");
        gtk_widget_add_css_class(value, "dl-readout");
        gtk_label_set_width_chars(GTK_LABEL(value), 7);
        gtk_label_set_xalign(GTK_LABEL(value), 1);
        GtkWidget *scale;
        if (trims) {
            g_snprintf(a11y, sizeof a11y, "%s level", name);
            scale = hscale(0, 100, 1, a11y);
            g_signal_connect(scale, "value-changed", G_CALLBACK(on_card_trim), t);
            t->trims[i] = scale;
            t->trimValues[i] = value;
        } else {
            g_snprintf(a11y, sizeof a11y, "%s delay", name);
            scale = hscale(0, DL_DELAY_LIMIT, 1, a11y);
            g_signal_connect(scale, "value-changed", G_CALLBACK(on_card_delay), t);
            t->delays[i] = scale;
            t->delayValues[i] = value;
        }
        g_object_set_data(G_OBJECT(scale), "card", GUINT_TO_POINTER(i));
        gtk_grid_attach(GTK_GRID(grid), scale, 1, (int)i, 1, 1);
        gtk_grid_attach(GTK_GRID(grid), value, 2, (int)i, 1, 1);
    }
    if (t->builtCount <= 6) return grid;
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 170);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), grid);
    return scroll;
}

static void build_surround(DLTuning *t, GtkWidget *body)
{
    GtkWidget *inner;
    gtk_box_append(GTK_BOX(body), dl_group_new("TIMING", &inner));
    gtk_box_append(GTK_BOX(inner), dl_caption("Delay a speaker that plays early. Distance compensation is added on top."));
    gtk_box_append(GTK_BOX(inner), speaker_grid(t, 0));
    gtk_box_append(GTK_BOX(inner), click_row(t, NULL));
    t->latency = dl_caption("");
    gtk_box_append(GTK_BOX(inner), t->latency);

    gtk_box_append(GTK_BOX(body), dl_group_new("LEVEL", &inner));
    gtk_box_append(GTK_BOX(inner), speaker_grid(t, 1));
}

static void build_body(DLTuning *t)
{
    DLUi *ui = t->ui;
    dl_box_clear(t->body);
    memset(t->delays, 0, sizeof t->delays);
    memset(t->trims, 0, sizeof t->trims);
    t->builtMode = ui->s->mode;
    t->builtCount = ui->s->mode == DL_MODE_SURROUND ? ui->s->count : 2;
    if (t->builtMode == DL_MODE_STEREO) build_stereo(t, t->body);
    else build_surround(t, t->body);

    GtkWidget *reset = gtk_button_new_with_label("Reset");
    g_signal_connect(reset, "clicked", G_CALLBACK(on_reset), t);
    GtkWidget *done = gtk_button_new_with_label("Done");
    gtk_widget_add_css_class(done, "suggested-action");
    g_signal_connect(done, "clicked", G_CALLBACK(on_done), t);
    gtk_box_append(GTK_BOX(t->body), dl_button_row(reset, done));
    gtk_window_set_default_widget(GTK_WINDOW(t->win), done);

    gtk_box_append(GTK_BOX(t->body), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    GtkWidget *demoRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    t->demo = gtk_button_new_with_label("Play Demo");
    g_signal_connect(t->demo, "clicked", G_CALLBACK(on_demo), t);
    gtk_box_append(GTK_BOX(demoRow), t->demo);
    t->demoCaption = dl_caption("");
    gtk_widget_set_valign(t->demoCaption, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(demoRow), t->demoCaption);
    gtk_box_append(GTK_BOX(t->body), demoRow);
}

void dl_tuning_sync(DLUi *ui)
{
    DLTuning *t = tuning_of(ui);
    if (!t) return;
    uint32_t count = ui->s->mode == DL_MODE_SURROUND ? ui->s->count : 2;
    if (t->builtMode != ui->s->mode || t->builtCount != count) build_body(t);
    ui->syncing++;
    if (t->builtMode == DL_MODE_STEREO) {
        double lim = ui->s->stereoExtended ? DL_DELAY_LIMIT : DL_STEREO_DELAY_NORMAL;
        gtk_range_set_range(GTK_RANGE(t->delay), -lim, lim);
        gtk_range_set_value(GTK_RANGE(t->delay), ui->s->stereoDelay);
        gtk_check_button_set_active(GTK_CHECK_BUTTON(t->extended), ui->s->stereoExtended);
        gtk_range_set_value(GTK_RANGE(t->balance), ui->s->balance * 100.0);
    } else {
        for (uint32_t i = 0; i < t->builtCount; i++) {
            gtk_range_set_value(GTK_RANGE(t->delays[i]), ui->s->cards[i].delayMs);
            gtk_range_set_value(GTK_RANGE(t->trims[i]), ui->s->cards[i].sp.trim * 100.0);
        }
    }
    ui->syncing--;
    update_readouts(t);
    update_live(t);
}

void dl_tuning_open(DLUi *ui)
{
    if (ui->tuning) {
        gtk_window_present(GTK_WINDOW(ui->tuning));
        return;
    }
    DLTuning *t = g_new0(DLTuning, 1);
    t->ui = ui;
    GtkWidget *content;
    t->win = dl_dialog_new(ui, "Sync & Balance", 480, &content);
    t->body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_box_append(GTK_BOX(content), t->body);
    t->builtMode = (DLMode)-1;
    g_object_set_data(G_OBJECT(t->win), "dl-tuning", t);
    g_signal_connect(t->win, "destroy", G_CALLBACK(on_destroy), t);
    ui->tuning = t->win;
    dl_tuning_sync(ui);
    t->timer = g_timeout_add(250, on_timer, t);
    gtk_window_present(GTK_WINDOW(t->win));
}
