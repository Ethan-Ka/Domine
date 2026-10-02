// Domine for Linux: display labels for output sinks (no GTK). Two JBL Grips
// report the same description, so a label that is shared by more than one
// sink gets a short suffix taken from the sink id, like "JBL Grip (EEFF)".
#ifndef DOMINE_UI_SINKS_H
#define DOMINE_UI_SINKS_H

#include <stdint.h>
#include "engine.h"

/// Up to 4 letters or digits from the end of a sink id, ignoring a trailing
/// ".<digits>" profile number ("bluez_output.AA_BB_CC_DD_EE_FF.1" gives
/// "EEFF"). buf needs 5 bytes.
void dl_sink_suffix(const char *id, char *buf, uint32_t len);

/// Label for sinks[index]: its label, plus " (suffix)" when another sink in
/// the list has the same label. An empty label falls back to the id.
void dl_sink_display_label(const DLSink *sinks, uint32_t count, uint32_t index, char *buf, uint32_t len);

/// Index of the sink with this id, or -1.
int dl_sink_find(const DLSink *sinks, uint32_t count, const char *id);

#endif
