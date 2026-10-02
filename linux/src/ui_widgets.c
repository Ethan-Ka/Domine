// Domine for Linux: widget helpers. See ui_widgets.h.
#include "ui_widgets.h"

GtkWidget *dl_dialog_new(DLUi *ui, const char *title, int width, GtkWidget **content)
{
    GtkWidget *win = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(win), title);
    gtk_window_set_modal(GTK_WINDOW(win), TRUE);
    gtk_window_set_resizable(GTK_WINDOW(win), FALSE);
    if (ui->w.window) gtk_window_set_transient_for(GTK_WINDOW(win), GTK_WINDOW(ui->w.window));
    gtk_window_set_destroy_with_parent(GTK_WINDOW(win), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(win), width, -1);

    GtkEventController *keys = gtk_shortcut_controller_new();
    gtk_shortcut_controller_add_shortcut(GTK_SHORTCUT_CONTROLLER(keys),
        gtk_shortcut_new(gtk_shortcut_trigger_parse_string("Escape"), gtk_named_action_new("window.close")));
    gtk_widget_add_controller(win, keys);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(box, 20);
    gtk_widget_set_margin_end(box, 20);
    gtk_widget_set_margin_top(box, 18);
    gtk_widget_set_margin_bottom(box, 18);
    gtk_widget_set_size_request(box, width - 40, -1);
    GtkWidget *heading = gtk_label_new(title);
    gtk_widget_add_css_class(heading, "heading");
    gtk_label_set_xalign(GTK_LABEL(heading), 0);
    gtk_box_append(GTK_BOX(box), heading);
    gtk_window_set_child(GTK_WINDOW(win), box);
    *content = box;
    return win;
}

GtkWidget *dl_group_new(const char *sectionTitle, GtkWidget **inner)
{
    GtkWidget *frame = gtk_frame_new(NULL);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(box, 12);
    gtk_widget_set_margin_end(box, 12);
    gtk_widget_set_margin_top(box, 10);
    gtk_widget_set_margin_bottom(box, 10);
    if (sectionTitle) {
        GtkWidget *t = gtk_label_new(sectionTitle);
        gtk_widget_add_css_class(t, "dl-section");
        gtk_label_set_xalign(GTK_LABEL(t), 0);
        gtk_box_append(GTK_BOX(box), t);
    }
    gtk_frame_set_child(GTK_FRAME(frame), box);
    *inner = box;
    return frame;
}

GtkWidget *dl_readout_row(const char *title, GtkWidget **value)
{
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *t = gtk_label_new(title);
    gtk_label_set_xalign(GTK_LABEL(t), 0);
    gtk_widget_set_hexpand(t, TRUE);
    gtk_box_append(GTK_BOX(row), t);
    *value = gtk_label_new("");
    gtk_widget_add_css_class(*value, "dl-readout");
    gtk_box_append(GTK_BOX(row), *value);
    return row;
}

GtkWidget *dl_end_labels(const char *leading, const char *trailing)
{
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *a = dl_caption(leading);
    gtk_widget_set_hexpand(a, TRUE);
    gtk_box_append(GTK_BOX(row), a);
    gtk_box_append(GTK_BOX(row), dl_caption(trailing));
    return row;
}

GtkWidget *dl_button_row(GtkWidget *left, GtkWidget *right)
{
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    if (left) gtk_box_append(GTK_BOX(row), left);
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(row), spacer);
    if (right) gtk_box_append(GTK_BOX(row), right);
    return row;
}

GtkWidget *dl_caption(const char *text)
{
    GtkWidget *l = gtk_label_new(text);
    gtk_widget_add_css_class(l, "caption");
    gtk_widget_add_css_class(l, "dim-label");
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    return l;
}

void dl_box_clear(GtkWidget *box)
{
    GtkWidget *child;
    while ((child = gtk_widget_get_first_child(box)) != NULL) gtk_box_remove(GTK_BOX(box), child);
}
