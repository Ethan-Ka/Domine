// Domine for Linux: sink display labels. See ui_sinks.h.
#include "ui_sinks.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

void dl_sink_suffix(const char *id, char *buf, uint32_t len)
{
    if (len == 0) return;
    buf[0] = '\0';
    if (!id) return;
    size_t end = strlen(id);
    // Drop a trailing ".<digits>" profile number.
    size_t p = end;
    while (p > 0 && isdigit((unsigned char)id[p - 1])) p--;
    if (p > 0 && p < end && id[p - 1] == '.') end = p - 1;

    char tmp[5];
    int n = 0;
    for (size_t i = end; i > 0 && n < 4; i--) {
        unsigned char c = (unsigned char)id[i - 1];
        if (isalnum(c)) tmp[n++] = (char)toupper(c);
    }
    uint32_t out = 0;
    for (int i = n - 1; i >= 0 && out + 1 < len; i--) buf[out++] = tmp[i];
    buf[out] = '\0';
}

void dl_sink_display_label(const DLSink *sinks, uint32_t count, uint32_t index, char *buf, uint32_t len)
{
    if (len == 0) return;
    if (index >= count) {
        buf[0] = '\0';
        return;
    }
    const DLSink *s = &sinks[index];
    const char *label = s->label[0] ? s->label : s->id;
    int shared = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (i == index) continue;
        const char *other = sinks[i].label[0] ? sinks[i].label : sinks[i].id;
        if (strcmp(other, label) == 0) shared = 1;
    }
    if (shared) {
        char suffix[5];
        dl_sink_suffix(s->id, suffix, sizeof suffix);
        snprintf(buf, len, "%s (%s)", label, suffix);
    } else {
        snprintf(buf, len, "%s", label);
    }
}

int dl_sink_find(const DLSink *sinks, uint32_t count, const char *id)
{
    if (!id || !id[0]) return -1;
    for (uint32_t i = 0; i < count; i++)
        if (strcmp(sinks[i].id, id) == 0) return (int)i;
    return -1;
}
