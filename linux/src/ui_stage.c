// Domine for Linux: stage widget. Cards are drawn with Cairo; dragging a card
// (Surround) moves it, snapping to 5 degrees unless Alt is held. A click (or
// right-click) opens a popover with the output chooser, Test and Remove; in
// Stereo a click opens the Choose Speaker dialog, as on the Mac.
#include "ui_stage.h"

#include <math.h>
#include <string.h>
#include "ui_geometry.h"
#include "ui_logic.h"

#define CARD_W 150.0
#define CARD_H 70.0
#define CARD_R 10.0
#define METER_SEGMENTS 16
#define DRAG_THRESHOLD 4.0

struct _DomineStage {
    GtkWidget parent;
    DLUi *ui;
    GtkWidget *popover;
    int dragCard;
    int moved;
    double cardX, cardY;    // card centre when the drag began
};

G_DECLARE_FINAL_TYPE(DomineStage, domine_stage, DOMINE, STAGE, GtkWidget)
G_DEFINE_FINAL_TYPE(DomineStage, domine_stage, GTK_TYPE_WIDGET)

static const GdkRGBA kAccent = { 0.21f, 0.52f, 0.89f, 1.0f };
static const GdkRGBA kRed = { 0.88f, 0.11f, 0.14f, 1.0f };

static DLStageFrame stage_frame(GtkWidget *w)
{
    return dl_geom_frame(gtk_widget_get_width(w), gtk_widget_get_height(w), CARD_W, CARD_H, 6.0);
}

static void card_centre(DomineStage *self, uint32_t card, double *x, double *y)
{
    DLStageFrame f = stage_frame(GTK_WIDGET(self));
    uint32_t n;
    DLCard *c = dl_ui_cards(self->ui, &n);
    dl_geom_to_point(&f, c[card].sp.azimuth, c[card].sp.distance, x, y);
}

static int hit_card(DomineStage *self, double x, double y)
{
    uint32_t n;
    dl_ui_cards(self->ui, &n);
    // The dragged card is drawn last, so it is hit first; then top-most first.
    if (self->dragCard >= 0 && (uint32_t)self->dragCard < n) {
        double cx, cy;
        card_centre(self, (uint32_t)self->dragCard, &cx, &cy);
        if (fabs(x - cx) <= CARD_W / 2 && fabs(y - cy) <= CARD_H / 2) return self->dragCard;
    }
    for (int i = (int)n - 1; i >= 0; i--) {
        double cx, cy;
        card_centre(self, (uint32_t)i, &cx, &cy);
        if (fabs(x - cx) <= CARD_W / 2 && fabs(y - cy) <= CARD_H / 2) return i;
    }
    return -1;
}

// ---- Drawing ----

static void set_rgba(cairo_t *cr, const GdkRGBA *c, double alpha)
{
    cairo_set_source_rgba(cr, c->red, c->green, c->blue, c->alpha * alpha);
}

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r)
{
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
    cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

static void draw_text(GtkWidget *w, cairo_t *cr, const char *markup, double x, double y, int width,
                      const GdkRGBA *color, double alpha, int alignRight)
{
    PangoLayout *layout = gtk_widget_create_pango_layout(w, NULL);
    pango_layout_set_markup(layout, markup, -1);
    if (width > 0) {
        pango_layout_set_width(layout, width * PANGO_SCALE);
        pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
        pango_layout_set_alignment(layout, alignRight ? PANGO_ALIGN_RIGHT : PANGO_ALIGN_LEFT);
    }
    set_rgba(cr, color, alpha);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

static void draw_meter(cairo_t *cr, double x, double y, double width, float peak, const GdkRGBA *fg)
{
    double lit = 0;
    if (peak > 0.0f) {
        double db = 20.0 * log10(peak);
        lit = (db + 48.0) / 48.0 * METER_SEGMENTS;
    }
    double gap = 2.0, segW = (width - gap * (METER_SEGMENTS - 1)) / METER_SEGMENTS;
    for (int i = 0; i < METER_SEGMENTS; i++) {
        double sx = x + i * (segW + gap);
        cairo_rectangle(cr, sx, y, segW, 4.0);
        if (i < lit) {
            if (i >= METER_SEGMENTS - 2) cairo_set_source_rgb(cr, 0.88, 0.20, 0.18);
            else if (i >= METER_SEGMENTS - 5) cairo_set_source_rgb(cr, 0.93, 0.76, 0.15);
            else cairo_set_source_rgb(cr, 0.20, 0.70, 0.33);
        } else {
            set_rgba(cr, fg, 0.12);
        }
        cairo_fill(cr);
    }
}

static void draw_card(DomineStage *self, cairo_t *cr, uint32_t i, const GdkRGBA *fg, const GdkRGBA *bg)
{
    GtkWidget *w = GTK_WIDGET(self);
    DLUi *ui = self->ui;
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    double cx, cy;
    card_centre(self, i, &cx, &cy);
    double x = round(cx - CARD_W / 2), y = round(cy - CARD_H / 2);
    int surround = dl_ui_is_surround(ui);
    int assigned = c[i].sp.sinkId[0] != '\0';
    int missing = dl_ui_card_missing(ui, i);

    rounded_rect(cr, x + 0.5, y + 0.5, CARD_W - 1, CARD_H - 1, CARD_R);
    cairo_set_source_rgba(cr, bg->red, bg->green, bg->blue, 1.0);
    cairo_fill_preserve(cr);
    if (missing) {
        set_rgba(cr, &kRed, 0.08);
        cairo_fill_preserve(cr);
        set_rgba(cr, &kRed, 0.6);
    } else if ((int)i == self->dragCard && self->moved) {
        set_rgba(cr, &kAccent, 1.0);
    } else {
        set_rgba(cr, fg, assigned ? 0.2 : 0.35);
    }
    if (!assigned) {
        double dash[] = { 4.0, 3.0 };
        cairo_set_dash(cr, dash, 2, 0);
    }
    cairo_set_line_width(cr, assigned ? 1.0 : 1.5);
    cairo_stroke(cr);
    cairo_set_dash(cr, NULL, 0, 0);

    char name[32], tag[32], sink[256], status[128];
    dl_card_name(ui->s->mode, i, name, sizeof name);
    if (surround) dl_geom_format_angle(c[i].sp.azimuth, tag, sizeof tag);
    else g_strlcpy(tag, i == 0 ? "L" : "R", sizeof tag);
    dl_ui_sink_label(ui, c[i].sp.sinkId, sink, sizeof sink, NULL);

    if (!assigned) g_strlcpy(status, "Click to choose", sizeof status);
    else if (missing) g_strlcpy(status, "Not connected", sizeof status);
    else if (ui->testCard == (int)i) g_strlcpy(status, "Playing tone", sizeof status);
    else if (surround) g_snprintf(status, sizeof status, "%.1f m", c[i].sp.distance);
    else if (ui->playing) g_strlcpy(status, ui->cardToEngine[i] >= 0 ? "Playing" : "Not playing", sizeof status);
    else g_strlcpy(status, "Connected", sizeof status);

    double pad = 10.0, inner = CARD_W - 2 * pad;
    char *m = g_markup_printf_escaped("<b>%s</b>", name);
    draw_text(w, cr, m, x + pad, y + 5, (int)(inner - 40), fg, 1.0, 0);
    g_free(m);
    m = g_markup_printf_escaped("<b>%s</b>", tag);
    draw_text(w, cr, m, x + pad + inner - 44, y + 5, 44, missing ? &kRed : &kAccent, 1.0, 1);
    g_free(m);
    m = g_markup_printf_escaped("<small>%s</small>", assigned ? sink : "No speaker");
    draw_text(w, cr, m, x + pad, y + 23, (int)inner, fg, assigned ? 0.9 : 0.5, 0);
    g_free(m);
    m = g_markup_printf_escaped("<small>%s</small>", status);
    draw_text(w, cr, m, x + pad, y + 38, (int)inner, missing ? &kRed : fg, missing ? 1.0 : 0.55, 0);
    g_free(m);
    draw_meter(cr, x + pad, y + CARD_H - 11, inner, missing ? 0.0f : dl_ui_card_peak(ui, i), fg);
}

static void stage_snapshot(GtkWidget *widget, GtkSnapshot *snapshot)
{
    DomineStage *self = DOMINE_STAGE(widget);
    DLUi *ui = self->ui;
    double w = gtk_widget_get_width(widget), h = gtk_widget_get_height(widget);
    cairo_t *cr = gtk_snapshot_append_cairo(snapshot, &GRAPHENE_RECT_INIT(0, 0, (float)w, (float)h));
    GdkRGBA fg;
    gtk_widget_get_color(widget, &fg);
    double lum = 0.299 * fg.red + 0.587 * fg.green + 0.114 * fg.blue;
    GdkRGBA bg = lum > 0.5 ? (GdkRGBA){ 0.19f, 0.19f, 0.21f, 1.0f } : (GdkRGBA){ 1.0f, 1.0f, 1.0f, 1.0f };
    DLStageFrame f = stage_frame(widget);

    // Guide circle at the default listening distance.
    double guide = dl_geom_distance_to_radius(&f, DL_DISTANCE_DEFAULT);
    double dash[] = { 3.0, 4.0 };
    cairo_set_dash(cr, dash, 2, 0);
    cairo_set_line_width(cr, 1.0);
    set_rgba(cr, &fg, 0.18);
    cairo_arc(cr, f.cx, f.cy, guide, 0, 2 * G_PI);
    cairo_stroke(cr);
    cairo_set_dash(cr, NULL, 0, 0);

    draw_text(widget, cr, "<small><b>FRONT</b></small>", f.cx - 40, 4, 80, &fg, 0.5, 0);

    uint32_t n;
    dl_ui_cards(ui, &n);
    set_rgba(cr, &fg, 0.22);
    for (uint32_t i = 0; i < n; i++) {
        double x, y;
        card_centre(self, i, &x, &y);
        cairo_move_to(cr, f.cx, f.cy);
        cairo_line_to(cr, x, y);
    }
    cairo_stroke(cr);

    // Listener, facing FRONT.
    cairo_arc(cr, f.cx, f.cy, 14, 0, 2 * G_PI);
    cairo_set_source_rgba(cr, bg.red, bg.green, bg.blue, 1.0);
    cairo_fill_preserve(cr);
    set_rgba(cr, &fg, 0.5);
    cairo_set_line_width(cr, 1.5);
    cairo_stroke(cr);
    cairo_move_to(cr, f.cx - 6, f.cy - 12);
    cairo_line_to(cr, f.cx, f.cy - 21);
    cairo_line_to(cr, f.cx + 6, f.cy - 12);
    cairo_stroke(cr);

    if (ui->demoOn && ui->demoPlaying) {
        double a = dl_geom_wrap(ui->demoAzimuth) * G_PI / 180.0;
        double dx = f.cx + guide * sin(a), dy = f.cy - guide * cos(a);
        set_rgba(cr, &kAccent, 0.25);
        cairo_arc(cr, dx, dy, 13, 0, 2 * G_PI);
        cairo_fill(cr);
        set_rgba(cr, &kAccent, 1.0);
        cairo_arc(cr, dx, dy, 7, 0, 2 * G_PI);
        cairo_fill(cr);
    }

    for (uint32_t i = 0; i < n; i++)
        if ((int)i != self->dragCard) draw_card(self, cr, i, &fg, &bg);
    if (self->dragCard >= 0 && (uint32_t)self->dragCard < n) draw_card(self, cr, (uint32_t)self->dragCard, &fg, &bg);
    cairo_destroy(cr);
}

// ---- Popover ----

static void on_popover_sink(GObject *dropdown, GParamSpec *pspec, gpointer data)
{
    (void)pspec;
    DomineStage *self = data;
    if (self->ui->syncing) return;
    char **ids = g_object_get_data(dropdown, "ids");
    guint card = GPOINTER_TO_UINT(g_object_get_data(dropdown, "card"));
    guint sel = gtk_drop_down_get_selected(GTK_DROP_DOWN(dropdown));
    if (!ids || sel == GTK_INVALID_LIST_POSITION || sel >= g_strv_length(ids)) return;
    dl_ui_assign(self->ui, card, ids[sel]);
}

static void on_popover_choose(GtkButton *b, gpointer data)
{
    DomineStage *self = data;
    guint card = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "card"));
    gtk_popover_popdown(GTK_POPOVER(self->popover));
    dl_assign_open(self->ui, card);
}

static void on_popover_test(GtkButton *b, gpointer data)
{
    DomineStage *self = data;
    dl_ui_test_tone(self->ui, GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "card")));
    gtk_widget_queue_draw(GTK_WIDGET(self));
}

static void on_popover_remove(GtkButton *b, gpointer data)
{
    DomineStage *self = data;
    guint card = GPOINTER_TO_UINT(g_object_get_data(G_OBJECT(b), "card"));
    gtk_popover_popdown(GTK_POPOVER(self->popover));
    dl_ui_remove_speaker(self->ui, card);
}

/// A dropdown of "None" plus every sink (and the card's saved sink when it is
/// not connected). Selecting an entry assigns it.
static GtkWidget *sink_dropdown(DomineStage *self, uint32_t card)
{
    DLUi *ui = self->ui;
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    const char *current = c[card].sp.sinkId;
    GPtrArray *labels = g_ptr_array_new_with_free_func(g_free);
    GPtrArray *ids = g_ptr_array_new();
    g_ptr_array_add(labels, g_strdup("None"));
    g_ptr_array_add(ids, g_strdup(""));
    guint selected = 0, found = 0;
    for (uint32_t i = 0; i < ui->sinkCount; i++) {
        char label[300];
        dl_ui_sink_label(ui, ui->sinks[i].id, label, sizeof label, NULL);
        if (!ui->sinks[i].available) g_strlcat(label, ", not connected", sizeof label);
        if (strcmp(ui->sinks[i].id, current) == 0) {
            selected = labels->len;
            found = 1;
        }
        g_ptr_array_add(labels, g_strdup(label));
        g_ptr_array_add(ids, g_strdup(ui->sinks[i].id));
    }
    if (current[0] && !found) {
        char label[300];
        dl_ui_sink_label(ui, current, label, sizeof label, NULL);
        g_strlcat(label, ", not connected", sizeof label);
        selected = labels->len;
        g_ptr_array_add(labels, g_strdup(label));
        g_ptr_array_add(ids, g_strdup(current));
    }
    g_ptr_array_add(labels, NULL);
    g_ptr_array_add(ids, NULL);
    GtkWidget *dd = gtk_drop_down_new_from_strings((const char *const *)labels->pdata);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(dd), selected);
    g_object_set_data_full(G_OBJECT(dd), "ids", g_ptr_array_free(ids, FALSE), (GDestroyNotify)g_strfreev);
    g_object_set_data(G_OBJECT(dd), "card", GUINT_TO_POINTER(card));
    g_ptr_array_free(labels, TRUE);
    g_signal_connect(dd, "notify::selected", G_CALLBACK(on_popover_sink), self);
    gtk_accessible_update_property(GTK_ACCESSIBLE(dd), GTK_ACCESSIBLE_PROPERTY_LABEL, "Output", -1);
    return dd;
}

static void open_popover(DomineStage *self, uint32_t card)
{
    DLUi *ui = self->ui;
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    if (card >= n) return;
    int surround = dl_ui_is_surround(ui);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_margin_start(box, 6);
    gtk_widget_set_margin_end(box, 6);
    gtk_widget_set_margin_top(box, 6);
    gtk_widget_set_margin_bottom(box, 6);

    char name[32], title[96];
    dl_card_name(ui->s->mode, card, name, sizeof name);
    if (surround) {
        char angle[16];
        dl_geom_format_angle(c[card].sp.azimuth, angle, sizeof angle);
        g_snprintf(title, sizeof title, "%s  %s, %.1f m", name, angle, c[card].sp.distance);
    } else {
        g_strlcpy(title, name, sizeof title);
    }
    GtkWidget *label = gtk_label_new(title);
    gtk_widget_add_css_class(label, "heading");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_box_append(GTK_BOX(box), label);

    gtk_box_append(GTK_BOX(box), sink_dropdown(self, card));

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *choose = gtk_button_new_with_label("Choose Speaker…");
    g_object_set_data(G_OBJECT(choose), "card", GUINT_TO_POINTER(card));
    g_signal_connect(choose, "clicked", G_CALLBACK(on_popover_choose), self);
    gtk_box_append(GTK_BOX(row), choose);
    GtkWidget *test = gtk_button_new_with_label("Test");
    g_object_set_data(G_OBJECT(test), "card", GUINT_TO_POINTER(card));
    gtk_widget_set_sensitive(test, ui->playing && ui->cardToEngine[card] >= 0);
    gtk_widget_set_tooltip_text(test, "Plays a chime on this speaker (Domine must be on)");
    g_signal_connect(test, "clicked", G_CALLBACK(on_popover_test), self);
    gtk_box_append(GTK_BOX(row), test);
    if (surround) {
        GtkWidget *remove = gtk_button_new_with_label("Remove");
        gtk_widget_add_css_class(remove, "destructive-action");
        g_object_set_data(G_OBJECT(remove), "card", GUINT_TO_POINTER(card));
        gtk_widget_set_sensitive(remove, ui->s->count > DL_SURROUND_MIN_SPEAKERS);
        g_signal_connect(remove, "clicked", G_CALLBACK(on_popover_remove), self);
        gtk_box_append(GTK_BOX(row), remove);
    }
    gtk_box_append(GTK_BOX(box), row);

    gtk_popover_set_child(GTK_POPOVER(self->popover), box);
    double cx, cy;
    card_centre(self, card, &cx, &cy);
    GdkRectangle rect = { (int)(cx - CARD_W / 2), (int)(cy - CARD_H / 2), (int)CARD_W, (int)CARD_H };
    gtk_popover_set_pointing_to(GTK_POPOVER(self->popover), &rect);
    gtk_popover_popup(GTK_POPOVER(self->popover));
}

// ---- Gestures ----

static void on_drag_begin(GtkGestureDrag *g, double x, double y, gpointer data)
{
    DomineStage *self = data;
    self->dragCard = hit_card(self, x, y);
    self->moved = 0;
    if (self->dragCard < 0) {
        gtk_gesture_set_state(GTK_GESTURE(g), GTK_EVENT_SEQUENCE_DENIED);
        return;
    }
    card_centre(self, (uint32_t)self->dragCard, &self->cardX, &self->cardY);
}

static void on_drag_update(GtkGestureDrag *g, double ox, double oy, gpointer data)
{
    DomineStage *self = data;
    DLUi *ui = self->ui;
    if (self->dragCard < 0) return;
    if (!self->moved && hypot(ox, oy) < DRAG_THRESHOLD) return;
    if (!dl_ui_is_surround(ui)) return;
    self->moved = 1;
    DLStageFrame f = stage_frame(GTK_WIDGET(self));
    float az, dist;
    dl_geom_from_point(&f, self->cardX + ox, self->cardY + oy, &az, &dist);
    GdkModifierType mods = gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(g));
    if (!(mods & GDK_ALT_MASK)) az = dl_geom_snap(az);
    uint32_t n;
    DLCard *c = dl_ui_cards(ui, &n);
    if ((uint32_t)self->dragCard >= n) return;
    c[self->dragCard].sp.azimuth = az;
    c[self->dragCard].sp.distance = roundf(dist * 10.0f) / 10.0f;
    dl_ui_cards_changed(ui, 0);
}

static void on_drag_end(GtkGestureDrag *g, double ox, double oy, gpointer data)
{
    (void)g;
    (void)ox;
    (void)oy;
    DomineStage *self = data;
    int card = self->dragCard;
    int moved = self->moved;
    self->dragCard = -1;
    self->moved = 0;
    gtk_widget_queue_draw(GTK_WIDGET(self));
    if (card < 0 || moved) return;
    if (dl_ui_is_surround(self->ui)) open_popover(self, (uint32_t)card);
    else dl_assign_open(self->ui, (uint32_t)card);
}

static void on_secondary(GtkGestureClick *g, int npress, double x, double y, gpointer data)
{
    (void)g;
    (void)npress;
    DomineStage *self = data;
    int card = hit_card(self, x, y);
    if (card >= 0) open_popover(self, (uint32_t)card);
}

// ---- Widget plumbing ----

static void stage_measure(GtkWidget *w, GtkOrientation o, int forSize, int *min, int *nat, int *minB, int *natB)
{
    (void)w;
    (void)forSize;
    *min = o == GTK_ORIENTATION_HORIZONTAL ? 480 : 300;
    *nat = o == GTK_ORIENTATION_HORIZONTAL ? 720 : 360;
    *minB = *natB = -1;
}

static void stage_size_allocate(GtkWidget *w, int width, int height, int baseline)
{
    (void)width;
    (void)height;
    (void)baseline;
    DomineStage *self = DOMINE_STAGE(w);
    if (self->popover) gtk_popover_present(GTK_POPOVER(self->popover));
}

static void stage_dispose(GObject *obj)
{
    DomineStage *self = DOMINE_STAGE(obj);
    g_clear_pointer(&self->popover, gtk_widget_unparent);
    G_OBJECT_CLASS(domine_stage_parent_class)->dispose(obj);
}

static void domine_stage_class_init(DomineStageClass *klass)
{
    GtkWidgetClass *wc = GTK_WIDGET_CLASS(klass);
    wc->snapshot = stage_snapshot;
    wc->measure = stage_measure;
    wc->size_allocate = stage_size_allocate;
    G_OBJECT_CLASS(klass)->dispose = stage_dispose;
    gtk_widget_class_set_accessible_role(wc, GTK_ACCESSIBLE_ROLE_GROUP);
}

static void domine_stage_init(DomineStage *self)
{
    self->dragCard = -1;
    GtkWidget *w = GTK_WIDGET(self);
    gtk_widget_set_hexpand(w, TRUE);
    gtk_widget_set_vexpand(w, TRUE);

    GtkGesture *drag = gtk_gesture_drag_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(drag), GDK_BUTTON_PRIMARY);
    g_signal_connect(drag, "drag-begin", G_CALLBACK(on_drag_begin), self);
    g_signal_connect(drag, "drag-update", G_CALLBACK(on_drag_update), self);
    g_signal_connect(drag, "drag-end", G_CALLBACK(on_drag_end), self);
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(drag));

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), GDK_BUTTON_SECONDARY);
    g_signal_connect(click, "pressed", G_CALLBACK(on_secondary), self);
    gtk_widget_add_controller(w, GTK_EVENT_CONTROLLER(click));

    self->popover = gtk_popover_new();
    gtk_widget_set_parent(self->popover, w);
}

GtkWidget *dl_stage_new(DLUi *ui)
{
    DomineStage *self = g_object_new(domine_stage_get_type(), NULL);
    self->ui = ui;
    gtk_accessible_update_property(GTK_ACCESSIBLE(self), GTK_ACCESSIBLE_PROPERTY_LABEL,
                                   "Speaker stage. Drag a speaker to move it; click it for options.", -1);
    return GTK_WIDGET(self);
}
