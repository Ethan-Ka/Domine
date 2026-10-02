// Domine for Linux: Choose Speaker dialog (macOS AssignSheet). A radio list
// of outputs with name, the last 4 characters of the id, a status line and
// Play tone; Cancel / Use This Speaker.
#include <string.h>
#include "ui_app.h"
#include "ui_logic.h"
#include "ui_sinks.h"
#include "ui_widgets.h"

typedef struct {
    DLUi *ui;
    GtkWidget *win;
    GtkWidget *use;
    uint32_t card;
    char *selected;           // sink id
} DLAssign;

static void on_radio(GtkCheckButton *b, gpointer data)
{
    DLAssign *a = data;
    if (!gtk_check_button_get_active(b)) return;
    g_free(a->selected);
    a->selected = g_strdup(g_object_get_data(G_OBJECT(b), "sink"));
    gtk_widget_set_sensitive(a->use, TRUE);
}

static void on_row_activated(GtkListBox *box, GtkListBoxRow *row, gpointer data)
{
    (void)box;
    (void)data;
    GtkWidget *radio = g_object_get_data(G_OBJECT(row), "radio");
    if (radio) gtk_check_button_set_active(GTK_CHECK_BUTTON(radio), TRUE);
}

static void on_tone(GtkButton *b, gpointer data)
{
    DLAssign *a = data;
    const char *id = g_object_get_data(G_OBJECT(b), "sink");
    dl_ui_test_tone_engine(a->ui, dl_ui_engine_index_for_sink(a->ui, id));
}

static void on_cancel(GtkButton *b, gpointer data)
{
    (void)b;
    DLAssign *a = data;
    gtk_window_close(GTK_WINDOW(a->win));
}

static void on_use(GtkButton *b, gpointer data)
{
    (void)b;
    DLAssign *a = data;
    DLUi *ui = a->ui;
    uint32_t card = a->card;
    char *id = g_strdup(a->selected ? a->selected : "");
    gtk_window_close(GTK_WINDOW(a->win));
    dl_ui_assign(ui, card, id);
    g_free(id);
}

static void on_destroy(GtkWidget *w, gpointer data)
{
    (void)w;
    DLAssign *a = data;
    g_free(a->selected);
    g_free(a);
}

/// "In use as Front Right", "Not connected" or "2 channels".
static void row_status(DLUi *ui, const DLSink *sink, uint32_t ownCard, char *buf, uint32_t len)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    for (uint32_t i = 0; i < n; i++) {
        if (i != ownCard && strcmp(c[i].sp.sinkId, sink->id) == 0) {
            char name[32];
            dl_card_name(ui->s->mode, i, name, sizeof name);
            g_snprintf(buf, len, "In use as %s", name);
            return;
        }
    }
    if (!sink->available) g_strlcpy(buf, "Not connected", len);
    else if (g_str_has_prefix(sink->id, "bluez_")) g_snprintf(buf, len, "Bluetooth, %u channels", sink->channels);
    else g_snprintf(buf, len, "%u channels", sink->channels);
}

static GtkWidget *build_row(DLAssign *a, const DLSink *sink, GtkWidget **group, int selected)
{
    DLUi *ui = a->ui;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_set_margin_start(box, 10);
    gtk_widget_set_margin_end(box, 10);
    gtk_widget_set_margin_top(box, 8);
    gtk_widget_set_margin_bottom(box, 8);

    GtkWidget *radio = gtk_check_button_new();
    if (*group) gtk_check_button_set_group(GTK_CHECK_BUTTON(radio), GTK_CHECK_BUTTON(*group));
    else *group = radio;
    g_object_set_data_full(G_OBJECT(radio), "sink", g_strdup(sink->id), g_free);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(radio), selected);
    g_signal_connect(radio, "toggled", G_CALLBACK(on_radio), a);
    gtk_box_append(GTK_BOX(box), radio);

    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(text, TRUE);
    char suffix[8], status[128];
    dl_sink_suffix(sink->id, suffix, sizeof suffix);
    char *markup = g_markup_printf_escaped("%s  <span alpha=\"60%%\">%s</span>",
                                           sink->label[0] ? sink->label : sink->id, suffix);
    GtkWidget *name = gtk_label_new(NULL);
    gtk_label_set_markup(GTK_LABEL(name), markup);
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    g_free(markup);
    gtk_box_append(GTK_BOX(text), name);
    row_status(ui, sink, a->card, status, sizeof status);
    gtk_box_append(GTK_BOX(text), dl_caption(status));
    gtk_box_append(GTK_BOX(box), text);

    GtkWidget *tone = gtk_button_new_with_label("Play tone");
    g_object_set_data_full(G_OBJECT(tone), "sink", g_strdup(sink->id), g_free);
    int canTone = dl_ui_engine_index_for_sink(ui, sink->id) >= 0;
    gtk_widget_set_sensitive(tone, canTone);
    gtk_widget_set_tooltip_text(tone, canTone ? "Plays a chime on this speaker"
                                              : "Available once Domine plays through this speaker");
    gtk_widget_set_valign(tone, GTK_ALIGN_CENTER);
    g_signal_connect(tone, "clicked", G_CALLBACK(on_tone), a);
    gtk_box_append(GTK_BOX(box), tone);

    char a11y[300];
    g_snprintf(a11y, sizeof a11y, "%s %s", sink->label, suffix);
    gtk_accessible_update_property(GTK_ACCESSIBLE(radio), GTK_ACCESSIBLE_PROPERTY_LABEL, a11y, -1);

    GtkWidget *row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), box);
    g_object_set_data(G_OBJECT(row), "radio", radio);
    return row;
}

void dl_assign_open(DLUi *ui, uint32_t card)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    if (card >= n) return;
    DLAssign *a = g_new0(DLAssign, 1);
    a->ui = ui;
    a->card = card;
    char name[32], title[64];
    dl_card_name(ui->s->mode, card, name, sizeof name);
    g_snprintf(title, sizeof title, "Choose the %s speaker", name);
    GtkWidget *content;
    a->win = dl_dialog_new(ui, title, 440, &content);
    g_signal_connect(a->win, "destroy", G_CALLBACK(on_destroy), a);

    GtkWidget *list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_NONE);
    gtk_widget_add_css_class(list, "boxed-list");
    gtk_widget_add_css_class(list, "frame");
    g_signal_connect(list, "row-activated", G_CALLBACK(on_row_activated), a);
    GtkWidget *group = NULL;
    int sharedNames = 0;
    for (uint32_t i = 0; i < ui->sinkCount; i++) {
        int sel = strcmp(ui->sinks[i].id, c[card].sp.sinkId) == 0;
        if (sel) a->selected = g_strdup(ui->sinks[i].id);
        gtk_list_box_append(GTK_LIST_BOX(list), build_row(a, &ui->sinks[i], &group, sel));
        for (uint32_t j = 0; j < i; j++)
            if (strcmp(ui->sinks[i].label, ui->sinks[j].label) == 0) sharedNames = 1;
    }
    if (ui->sinkCount == 0) {
        GtkWidget *empty = gtk_label_new(ui->engine ? "No outputs found. Connect a speaker first."
                                                    : "PipeWire is not available.");
        gtk_widget_add_css_class(empty, "dim-label");
        gtk_widget_set_margin_top(empty, 20);
        gtk_widget_set_margin_bottom(empty, 20);
        gtk_list_box_set_placeholder(GTK_LIST_BOX(list), empty);
    }
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 320);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
    gtk_box_append(GTK_BOX(content), scroll);

    if (sharedNames)
        gtk_box_append(GTK_BOX(content),
                       dl_caption("Speakers with the same name are told apart by the last 4 characters of their id. "
                                  "If two JBL speakers play the same sound, turn off stereo pairing in the JBL "
                                  "Portable app."));

    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(buttons, GTK_ALIGN_END);
    GtkWidget *cancel = gtk_button_new_with_label("Cancel");
    g_signal_connect(cancel, "clicked", G_CALLBACK(on_cancel), a);
    a->use = gtk_button_new_with_label("Use This Speaker");
    gtk_widget_add_css_class(a->use, "suggested-action");
    gtk_widget_set_sensitive(a->use, a->selected != NULL);
    g_signal_connect(a->use, "clicked", G_CALLBACK(on_use), a);
    gtk_box_append(GTK_BOX(buttons), cancel);
    gtk_box_append(GTK_BOX(buttons), a->use);
    gtk_box_append(GTK_BOX(content), buttons);
    gtk_window_set_default_widget(GTK_WINDOW(a->win), a->use);
    gtk_window_present(GTK_WINDOW(a->win));
}
