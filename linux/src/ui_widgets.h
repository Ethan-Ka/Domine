// Domine for Linux: small widget helpers shared by the dialogs.
#ifndef DOMINE_UI_WIDGETS_H
#define DOMINE_UI_WIDGETS_H

#include <gtk/gtk.h>
#include "ui_app.h"

/// A modal dialog window transient for the main window, destroyed on close
/// (Escape closes it). *content receives the vertical box to fill; the
/// heading label is already in it.
GtkWidget *dl_dialog_new(DLUi *ui, const char *title, int width, GtkWidget **content);
/// A framed group with a vertical box inside (returned in *inner).
GtkWidget *dl_group_new(const char *sectionTitle, GtkWidget **inner);
/// "Title ........ value" row; *value receives the value label.
GtkWidget *dl_readout_row(const char *title, GtkWidget **value);
/// Small dim labels at both ends of a slider.
GtkWidget *dl_end_labels(const char *leading, const char *trailing);
/// A horizontal box with `left` at the start and `right` at the end.
GtkWidget *dl_button_row(GtkWidget *left, GtkWidget *right);
/// Small dim label.
GtkWidget *dl_caption(const char *text);
/// Removes every child of a GtkBox.
void dl_box_clear(GtkWidget *box);

#endif
