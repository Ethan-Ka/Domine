// Domine for Linux: the top-down stage (listener in the centre, FRONT at
// the top, one card per speaker at its azimuth and distance).
#ifndef DOMINE_UI_STAGE_H
#define DOMINE_UI_STAGE_H

#include <gtk/gtk.h>
#include "ui_app.h"

GtkWidget *dl_stage_new(DLUi *ui);

#endif
