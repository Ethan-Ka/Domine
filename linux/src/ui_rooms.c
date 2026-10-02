// Domine for Linux: Rooms (macOS RoomMenu, SaveRoomSheet, ManageRoomsSheet).
// A room stores the mode and the speaker ids; their tuning comes back from
// the per-set records in the settings file.
#include <string.h>
#include "ui_app.h"
#include "ui_widgets.h"

static GtkWidget *gRoomButton;   // one main window per process

static void close_popover(GtkWidget *w)
{
    GtkWidget *pop = gtk_widget_get_ancestor(w, GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
}

static void on_select(GtkButton *b, gpointer data)
{
    close_popover(GTK_WIDGET(b));
    dl_ui_select_room(data, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "room")));
}

// ---- Save Current Setup ----

static void on_save_entry_changed(GtkEditable *e, gpointer data)
{
    char *t = g_strstrip(g_strdup(gtk_editable_get_text(e)));
    gtk_widget_set_sensitive(GTK_WIDGET(data), t[0] != '\0');
    g_free(t);
}

static void on_save_commit(GtkWidget *w, gpointer data)
{
    DLUi *ui = data;
    GtkWidget *win = GTK_WIDGET(gtk_widget_get_root(w));
    GtkWidget *entry = g_object_get_data(G_OBJECT(win), "entry");
    char *name = g_strstrip(g_strdup(gtk_editable_get_text(GTK_EDITABLE(entry))));
    if (name[0]) {
        dl_ui_save_room(ui, name);
        gtk_window_close(GTK_WINDOW(win));
    }
    g_free(name);
}

static void on_close_clicked(GtkButton *b, gpointer data)
{
    (void)data;
    gtk_window_close(GTK_WINDOW(gtk_widget_get_root(GTK_WIDGET(b))));
}

static void open_save(DLUi *ui)
{
    GtkWidget *content;
    GtkWidget *win = dl_dialog_new(ui, "Save Current Setup", 320, &content);
    GtkWidget *entry = gtk_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), "Name");
    gtk_accessible_update_property(GTK_ACCESSIBLE(entry), GTK_ACCESSIBLE_PROPERTY_LABEL, "Room name", -1);
    g_object_set_data(G_OBJECT(win), "entry", entry);
    gtk_box_append(GTK_BOX(content), entry);
    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(buttons, GTK_ALIGN_END);
    GtkWidget *cancel = gtk_button_new_with_label("Cancel");
    g_signal_connect(cancel, "clicked", G_CALLBACK(on_close_clicked), NULL);
    GtkWidget *save = gtk_button_new_with_label("Save");
    gtk_widget_add_css_class(save, "suggested-action");
    gtk_widget_set_sensitive(save, FALSE);
    g_signal_connect(save, "clicked", G_CALLBACK(on_save_commit), ui);
    g_signal_connect(entry, "activate", G_CALLBACK(on_save_commit), ui);
    g_signal_connect(entry, "changed", G_CALLBACK(on_save_entry_changed), save);
    gtk_box_append(GTK_BOX(buttons), cancel);
    gtk_box_append(GTK_BOX(buttons), save);
    gtk_box_append(GTK_BOX(content), buttons);
    gtk_window_present(GTK_WINDOW(win));
}

static void on_save(GtkButton *b, gpointer data)
{
    close_popover(GTK_WIDGET(b));
    open_save(data);
}

// ---- Manage Rooms ----

static void fill_manage(DLUi *ui, GtkWidget *list);

static void on_rename(GtkEditable *e, gpointer data)
{
    DLUi *ui = data;
    int idx = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(e), "room"));
    dl_ui_rename_room(ui, idx, gtk_editable_get_text(e));
}

static void on_delete(GtkButton *b, gpointer data)
{
    DLUi *ui = data;
    GtkWidget *list = g_object_get_data(G_OBJECT(b), "list");
    dl_ui_delete_room(ui, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "room")));
    fill_manage(ui, list);
}

static void fill_manage(DLUi *ui, GtkWidget *list)
{
    dl_box_clear(list);
    if (ui->s->roomCount == 0) {
        GtkWidget *empty = gtk_label_new("No saved rooms");
        gtk_widget_add_css_class(empty, "dim-label");
        gtk_widget_set_margin_top(empty, 20);
        gtk_widget_set_margin_bottom(empty, 20);
        gtk_box_append(GTK_BOX(list), empty);
        return;
    }
    for (uint32_t i = 0; i < ui->s->roomCount; i++) {
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        GtkWidget *entry = gtk_entry_new();
        gtk_editable_set_text(GTK_EDITABLE(entry), ui->s->rooms[i].name);
        gtk_widget_set_hexpand(entry, TRUE);
        gtk_accessible_update_property(GTK_ACCESSIBLE(entry), GTK_ACCESSIBLE_PROPERTY_LABEL, "Name", -1);
        g_object_set_data(G_OBJECT(entry), "room", GINT_TO_POINTER((int)i));
        // Blank names are ignored by dl_ui_rename_room, so the old name stays.
        g_signal_connect(entry, "changed", G_CALLBACK(on_rename), ui);
        gtk_box_append(GTK_BOX(row), entry);
        GtkWidget *del = gtk_button_new_with_label("Delete");
        gtk_widget_add_css_class(del, "destructive-action");
        g_object_set_data(G_OBJECT(del), "room", GINT_TO_POINTER((int)i));
        g_object_set_data(G_OBJECT(del), "list", list);
        g_signal_connect(del, "clicked", G_CALLBACK(on_delete), ui);
        gtk_box_append(GTK_BOX(row), del);
        gtk_box_append(GTK_BOX(list), row);
    }
}

static void open_manage(DLUi *ui)
{
    GtkWidget *content;
    GtkWidget *win = dl_dialog_new(ui, "Manage Rooms", 360, &content);
    GtkWidget *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    fill_manage(ui, list);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(scroll), TRUE);
    gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(scroll), 240);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
    gtk_box_append(GTK_BOX(content), scroll);
    GtkWidget *done = gtk_button_new_with_label("Done");
    gtk_widget_add_css_class(done, "suggested-action");
    g_signal_connect(done, "clicked", G_CALLBACK(on_close_clicked), NULL);
    gtk_box_append(GTK_BOX(content), dl_button_row(NULL, done));
    gtk_window_present(GTK_WINDOW(win));
}

static void on_manage(GtkButton *b, gpointer data)
{
    close_popover(GTK_WIDGET(b));
    open_manage(data);
}

// ---- Menu button ----

static GtkWidget *menu_item(const char *label, GCallback cb, gpointer data)
{
    GtkWidget *b = gtk_button_new_with_label(label);
    gtk_widget_add_css_class(b, "flat");
    gtk_widget_set_halign(gtk_button_get_child(GTK_BUTTON(b)), GTK_ALIGN_START);
    g_signal_connect(b, "clicked", cb, data);
    return b;
}

void dl_rooms_sync(DLUi *ui)
{
    if (!gRoomButton || !ui->w.window) return;
    DLSettings *s = ui->s;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    for (uint32_t i = 0; i < s->roomCount; i++) {
        char label[160];
        g_snprintf(label, sizeof label, "%s%s", (int)i == s->currentRoom ? "✓ " : "    ", s->rooms[i].name);
        GtkWidget *b = menu_item(label, G_CALLBACK(on_select), ui);
        g_object_set_data(G_OBJECT(b), "room", GINT_TO_POINTER((int)i));
        gtk_box_append(GTK_BOX(box), b);
    }
    if (s->roomCount) gtk_box_append(GTK_BOX(box), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
    gtk_box_append(GTK_BOX(box), menu_item("Save Current Setup…", G_CALLBACK(on_save), ui));
    GtkWidget *manage = menu_item("Manage Rooms…", G_CALLBACK(on_manage), ui);
    gtk_widget_set_sensitive(manage, s->roomCount > 0);
    gtk_box_append(GTK_BOX(box), manage);
    GtkPopover *pop = gtk_menu_button_get_popover(GTK_MENU_BUTTON(gRoomButton));
    gtk_popover_set_child(pop, box);
    const char *name = s->currentRoom >= 0 && s->currentRoom < (int)s->roomCount ? s->rooms[s->currentRoom].name : "Room";
    gtk_menu_button_set_label(GTK_MENU_BUTTON(gRoomButton), name);
}

GtkWidget *dl_rooms_button(DLUi *ui)
{
    (void)ui;
    gRoomButton = gtk_menu_button_new();
    gtk_menu_button_set_popover(GTK_MENU_BUTTON(gRoomButton), gtk_popover_new());
    gtk_menu_button_set_label(GTK_MENU_BUTTON(gRoomButton), "Room");
    gtk_widget_set_tooltip_text(gRoomButton, "Saved speaker setups");
    gtk_accessible_update_property(GTK_ACCESSIBLE(gRoomButton), GTK_ACCESSIBLE_PROPERTY_LABEL, "Room", -1);
    return gRoomButton;
}
