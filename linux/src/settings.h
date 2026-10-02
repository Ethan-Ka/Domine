// Domine for Linux: settings persisted with GKeyFile at
// $XDG_CONFIG_HOME/domine/settings.ini. Sinks are stored by id (node.name),
// never by label.
#ifndef DOMINE_SETTINGS_H
#define DOMINE_SETTINGS_H

#include <stdint.h>
#include "engine.h"

typedef enum { DL_MODE_STEREO = 0, DL_MODE_SURROUND = 1 } DLMode;

typedef struct {
    DLMode mode;
    float master;            // 0...1
    DLSpeaker stereo[2];     // left (-30) and right (+30); sinkId "" = none
    uint32_t count;          // surround speakers, 3...DL_MAX_SPEAKERS
    DLSpeaker speakers[DL_MAX_SPEAKERS];
    float width;             // degrees, 10...90
    float surroundLevel;     // 0...1
    float orbit;             // turns per second, 0...2
    float rotation;          // degrees, -180...180
} DLSettings;

/// Factory defaults: Stereo, 80 %, three unassigned surround speakers.
void dl_settings_defaults(DLSettings *s);
/// Clamps every field into range (used after loading).
void dl_settings_sanitize(DLSettings *s);

/// path NULL means the default location. Load keeps defaults for anything
/// missing and returns 0 if the file was read, -1 otherwise.
int dl_settings_load(DLSettings *s, const char *path);
/// Writes the file (creating the directory). Returns 0 or -1.
int dl_settings_save(const DLSettings *s, const char *path);
/// Newly allocated default path; free with g_free.
char *dl_settings_default_path(void);

#endif
