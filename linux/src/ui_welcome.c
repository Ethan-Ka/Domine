// Domine for Linux: first-run checklist (macOS WelcomeView), adapted to
// Linux: PipeWire running, speakers connected and chosen, Domine started.
#include <string.h>
#include "ui_app.h"
#include "ui_widgets.h"

typedef struct {
    DLUi *ui;
    GtkWidget *win;
    GtkWidget *mark[3], *action[3];
} DLWelcome;

static DLWelcome *welcome_of(DLUi *ui)
{
    return ui->welcome ? g_object_get_data(G_OBJECT(ui->welcome), "dl-welcome") : NULL;
}

static int first_unassigned(DLUi *ui)
{
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    for (uint32_t i = 0; i < n; i++)
        if (!c[i].sp.sinkId[0]) return (int)i;
    return -1;
}

static int step_done(DLUi *ui, int step)
{
    switch (step) {
    case 0: return ui->engine != NULL;
    case 1: return ui->engine && first_unassigned(ui) < 0;
    default: return ui->playing;
    }
}

static void open_bluetooth(void)
{
    const char *cmds[] = { "gnome-control-center bluetooth", "systemsettings kcm_bluetooth", "blueman-manager" };
    for (size_t i = 0; i < G_N_ELEMENTS(cmds); i++) {
        char **argv = NULL;
        if (!g_shell_parse_argv(cmds[i], NULL, &argv, NULL)) continue;
        char *exe = g_find_program_in_path(argv[0]);
        int ok = exe && g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, NULL);
        g_free(exe);
        g_strfreev(argv);
        if (ok) return;
    }
}

static void on_action(GtkButton *b, gpointer data)
{
    DLWelcome *w = data;
    DLUi *ui = w->ui;
    int step = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "step"));
    if (step == 0) {
        dl_ui_retry_engine(ui);
    } else if (step == 1) {
        if (ui->sinkCount < 2) {
            open_bluetooth();
        } else {
            int card = first_unassigned(ui);
            dl_assign_open(ui, card < 0 ? 0 : (uint32_t)card);
        }
    } else {
        dl_ui_set_playing(ui, 1);
    }
    dl_welcome_sync(ui);
}

static void on_continue(GtkButton *b, gpointer data)
{
    (void)b;
    DLWelcome *w = data;
    w->ui->s->welcomeDone = 1;
    dl_ui_schedule_save(w->ui);
    gtk_window_close(GTK_WINDOW(w->win));
}

static void on_destroy(GtkWidget *wid, gpointer data)
{
    (void)wid;
    DLWelcome *w = data;
    w->ui->welcome = NULL;
    g_free(w);
}

void dl_welcome_sync(DLUi *ui)
{
    DLWelcome *w = welcome_of(ui);
    if (!w) return;
    for (int i = 0; i < 3; i++) {
        int done = step_done(ui, i);
        gtk_image_set_from_icon_name(GTK_IMAGE(w->mark[i]), done ? "object-select-symbolic" : "media-record-symbolic");
        gtk_widget_set_opacity(w->mark[i], done ? 1.0 : 0.35);
        gtk_widget_set_sensitive(w->action[i], !done && (i == 0 || ui->engine));
    }
    gtk_button_set_label(GTK_BUTTON(w->action[1]), ui->sinkCount < 2 ? "Bluetooth Settings" : "Choose…");
}

static GtkWidget *step_row(DLWelcome *w, int i, const char *title, const char *detail, const char *action)
{
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    char num[8];
    g_snprintf(num, sizeof num, "%d", i + 1);
    GtkWidget *n = gtk_label_new(num);
    gtk_widget_add_css_class(n, "title-3");
    gtk_widget_add_css_class(n, "dim-label");
    gtk_box_append(GTK_BOX(row), n);
    w->mark[i] = gtk_image_new();
    gtk_box_append(GTK_BOX(row), w->mark[i]);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(text, TRUE);
    GtkWidget *t = gtk_label_new(title);
    gtk_widget_add_css_class(t, "heading");
    gtk_label_set_xalign(GTK_LABEL(t), 0);
    gtk_box_append(GTK_BOX(text), t);
    gtk_box_append(GTK_BOX(text), dl_caption(detail));
    gtk_box_append(GTK_BOX(row), text);
    w->action[i] = gtk_button_new_with_label(action);
    gtk_widget_set_valign(w->action[i], GTK_ALIGN_CENTER);
    g_object_set_data(G_OBJECT(w->action[i]), "step", GINT_TO_POINTER(i));
    g_signal_connect(w->action[i], "clicked", G_CALLBACK(on_action), w);
    gtk_box_append(GTK_BOX(row), w->action[i]);
    return row;
}

void dl_welcome_open(DLUi *ui)
{
    if (ui->welcome) {
        gtk_window_present(GTK_WINDOW(ui->welcome));
        return;
    }
    DLWelcome *w = g_new0(DLWelcome, 1);
    w->ui = ui;
    GtkWidget *content;
    w->win = dl_dialog_new(ui, "Set up Domine", 600, &content);
    gtk_box_append(GTK_BOX(content), step_row(w, 0, "PipeWire is running",
        "Domine routes the desktop's audio through PipeWire (with its PulseAudio support).", "Check Again"));
    gtk_box_append(GTK_BOX(content), step_row(w, 1, "Connect and choose your speakers",
        "Pair them in the Bluetooth settings and disconnect them from your phone. "
        "For JBL speakers, turn off stereo pairing in the JBL Portable app first. Then pick one for each card.",
        "Choose…"));
    gtk_box_append(GTK_BOX(content), step_row(w, 2, "Turn Domine on",
        "Domine becomes the default output and plays each side on its own speaker.", "Start"));
    GtkWidget *cont = gtk_button_new_with_label("Continue");
    gtk_widget_add_css_class(cont, "suggested-action");
    g_signal_connect(cont, "clicked", G_CALLBACK(on_continue), w);
    gtk_box_append(GTK_BOX(content), dl_button_row(NULL, cont));
    gtk_window_set_default_widget(GTK_WINDOW(w->win), cont);
    g_object_set_data(G_OBJECT(w->win), "dl-welcome", w);
    g_signal_connect(w->win, "destroy", G_CALLBACK(on_destroy), w);
    ui->welcome = w->win;
    dl_welcome_sync(ui);
    gtk_window_present(GTK_WINDOW(w->win));
}
