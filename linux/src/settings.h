// Domine for Linux: settings persisted with GKeyFile at
// $XDG_CONFIG_HOME/domine/settings.ini. Sinks are stored by id (node.name),
// never by label.
//
// Like the macOS app's per-pair records, tuning (delay, balance or trim,
// effects, and in Surround the positions) is also kept per speaker set in a
// group named after the sorted sink ids ("set stereo a|b",
// "set surround a|b|c"), so assigning the same speakers again, or switching
// to a saved room, brings their tuning back.
#ifndef DOMINE_SETTINGS_H
#define DOMINE_SETTINGS_H

#include <glib.h>
#include <stdint.h>
#include "engine.h"

typedef enum { DL_MODE_STEREO = 0, DL_MODE_SURROUND = 1 } DLMode;

#define DL_EQ_BANDS 5
#define DL_MAX_ROOMS 32
#define DL_MAX_APP_PREFS 64
#define DL_STEREO_DELAY_NORMAL 50.0f
#define DL_DELAY_LIMIT 300.0f

/// One speaker's effects chain, as the macOS Sound sheet stores it.
typedef struct {
    int eqOn;
    float eqDb[DL_EQ_BANDS];   // -12...12
    int bassOn;
    float bass;                // 0...1
    int compOn;
    float comp;                // 0...1
} DLEffects;

/// One speaker card: routing (sink, position, trim) plus its tuning.
typedef struct {
    DLSpeaker sp;
    float delayMs;             // Surround: 0...300. Stereo: unused (see stereoDelay)
    DLEffects fx;
} DLCard;

typedef struct {
    char name[128];
    DLMode mode;
    char stereo[2][256];
    uint32_t count;
    char sinks[DL_MAX_SPEAKERS][256];
} DLRoom;

typedef struct {
    char key[256];
    char label[256];
    int excluded;
    int hasVolume;
    float volume;
} DLAppPref;

typedef struct {
    DLMode mode;
    float master;                       // linear gain 0...1 (slider shows its cube root)

    // Stereo: card 0 is Front Left (-30), card 1 Front Right (+30).
    DLCard stereo[2];
    float stereoDelay;                  // signed ms; positive delays the right speaker
    int stereoExtended;                 // slider shows +-300 instead of +-50
    float balance;                      // -1 (left) ... 1 (right)
    int stereoLink;                     // effects linked

    // Surround.
    uint32_t count;                     // 3...DL_MAX_SPEAKERS
    DLCard cards[DL_MAX_SPEAKERS];
    int surroundLink;
    float width;                        // degrees, 10...90
    float surroundLevel;                // 0...1
    float orbit;                        // turns per second, 0...2
    float rotation;                     // degrees, -180...180
    float spatial;                      // ambience amount 0...1
    float roomMs;                       // 5...30

    // Preferences.
    int startPlaying;
    int keepRunning;
    int launchAtLogin;
    int welcomeDone;
    char excludeSinkId[256];            // "" = previous output

    uint32_t roomCount;
    DLRoom rooms[DL_MAX_ROOMS];
    int currentRoom;                    // index or -1

    uint32_t appCount;
    DLAppPref apps[DL_MAX_APP_PREFS];
} DLSettings;

void dl_effects_defaults(DLEffects *fx);
/// Factory defaults: Stereo, 80 %, three unassigned surround speakers.
void dl_settings_defaults(DLSettings *s);
/// Clamps every field into range (used after loading).
void dl_settings_sanitize(DLSettings *s);

/// Reads everything from kf into s (missing keys keep their current value).
void dl_settings_from_keyfile(DLSettings *s, GKeyFile *kf);
/// Writes s into kf. Per-set groups already in kf are kept; the current
/// set's group is rewritten.
void dl_settings_to_keyfile(const DLSettings *s, GKeyFile *kf);

/// path NULL means the default location. Load returns 0 if the file was
/// read, -1 otherwise (kf is then left empty). Save creates the directory.
int dl_settings_load_file(GKeyFile *kf, const char *path);
int dl_settings_save_file(GKeyFile *kf, const char *path);
/// Newly allocated default path; free with g_free.
char *dl_settings_default_path(void);

/// Group name for a speaker set: "set stereo " or "set surround " plus the
/// non-empty ids sorted and joined by '|', with characters GKeyFile cannot
/// hold replaced by '_'. NULL when every id is empty. Free with g_free.
char *dl_settings_set_group(DLMode mode, const char *const *ids, uint32_t n);
/// A key or group name made safe for GKeyFile ('[', ']', '=', control
/// characters become '_'). Free with g_free.
char *dl_settings_safe_name(const char *raw);

/// Saves the tuning of the current mode's speaker set into its group.
void dl_settings_store_set(const DLSettings *s, GKeyFile *kf);
/// Restores the current mode's speaker set tuning if kf has a group for it.
/// Returns 1 if something was restored.
int dl_settings_restore_set(DLSettings *s, GKeyFile *kf);

#endif
