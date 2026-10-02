// Domine for Linux: entry point.
//   domine               opens the window
//   domine --background  starts without a window (used by Launch at login)
//   domine --self-test   runs the pure logic checks and exits 0 or 1
//   domine --settings=PATH  uses another settings file (for testing)
#include <gtk/gtk.h>
#include <string.h>
#include "ui_app.h"
#include "ui_selftest.h"

static DLUi *gUi;
static int gBackground;
static char *gSettingsPath;

static gboolean auto_start(gpointer data)
{
    DLUi *ui = data;
    if (ui->engine && !ui->playing) dl_ui_set_playing(ui, 1);
    return G_SOURCE_REMOVE;
}

static void on_activate(GApplication *app, gpointer data)
{
    (void)data;
    if (!gUi) {
        gUi = dl_ui_new(GTK_APPLICATION(app), gSettingsPath);
        gUi->startHidden = gBackground;
        dl_window_build(gUi);
        if (gUi->s->startPlaying || gBackground)
            // Give PipeWire a moment to list the speakers before starting.
            g_timeout_add(1500, auto_start, gUi);
        if (gBackground) {
            g_application_hold(app);
            gUi->held = 1;
            return;
        }
        dl_window_present(gUi);
        if (!gUi->s->welcomeDone) dl_welcome_open(gUi);
        return;
    }
    // A second launch brings the window back.
    dl_window_present(gUi);
}

static void on_shutdown(GApplication *app, gpointer data)
{
    (void)app;
    (void)data;
    dl_ui_free(gUi);
    gUi = NULL;
}

int main(int argc, char **argv)
{
    // Strip our own flags so GApplication does not reject them.
    int out = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--self-test") == 0) return dl_self_test();
        if (strcmp(argv[i], "--background") == 0) {
            gBackground = 1;
        } else if (g_str_has_prefix(argv[i], "--settings=")) {
            gSettingsPath = argv[i] + strlen("--settings=");
        } else {
            argv[out++] = argv[i];
        }
    }
    argc = out;
    argv[argc] = NULL;

    GtkApplication *app = gtk_application_new("io.github.ethanka.Domine", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(on_activate), NULL);
    g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return status;
}
