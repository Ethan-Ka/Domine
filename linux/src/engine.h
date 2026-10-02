// Domine for Linux: audio engine (PipeWire). The GTK UI talks to the audio
// side only through this header. All functions are called from the GTK main
// thread unless noted; the engine runs its own PipeWire thread loop and the
// DomineSurround kernel on the PipeWire real-time thread.
#ifndef DOMINE_LINUX_ENGINE_H
#define DOMINE_LINUX_ENGINE_H

#include <stdint.h>

#define DL_MAX_SPEAKERS 16
#define DL_MAX_SINKS 64

typedef struct {
    char id[256];        // stable key: the sink's node.name (never the numeric id)
    char label[256];     // node.description, for display
    uint32_t channels;
    int available;       // nonzero while the sink exists
} DLSink;

typedef struct {
    char sinkId[256];    // DLSink.id
    float azimuth;       // degrees, DomineSurround.h convention
    float distance;      // metres
    float trim;          // 0...1
} DLSpeaker;

typedef enum { DL_IDLE = 0, DL_STARTING, DL_PLAYING, DL_DEGRADED, DL_ERROR } DLState;

typedef struct DLEngine DLEngine;

/// Connects to PipeWire. Returns NULL (and writes a message to err) on failure.
DLEngine *dl_engine_create(char *err, uint32_t errLen);
void dl_engine_destroy(DLEngine *e);

/// Copies up to max known output sinks (Domine's own virtual sink excluded).
/// Returns the count. Safe to call any time; the list updates as devices come
/// and go. on_change (may be NULL) is invoked on the GTK main thread
/// (via g_idle_add) whenever the sink list or engine state changes.
uint32_t dl_engine_sinks(DLEngine *e, DLSink *out, uint32_t max);
void dl_engine_set_on_change(DLEngine *e, void (*on_change)(void *ctx), void *ctx);

/// Starts routing: creates a virtual sink "Domine" (made the default sink,
/// previous default remembered and restored on stop), captures its monitor,
/// runs the surround kernel, and plays one stream per speaker to its sink.
/// Returns 0 on success, -1 with a message in err.
int dl_engine_start(DLEngine *e, const DLSpeaker *speakers, uint32_t count, char *err, uint32_t errLen);
void dl_engine_stop(DLEngine *e);
DLState dl_engine_state(DLEngine *e);

/// Live changes while playing (no restart): positions, trims, master volume
/// (0...1, applied in the kernel as a gain on every speaker), stage width,
/// surround level, orbit rate (deg/s), rotation (deg).
void dl_engine_update_speakers(DLEngine *e, const DLSpeaker *speakers, uint32_t count);
void dl_engine_set_master(DLEngine *e, float volume);
void dl_engine_set_width(DLEngine *e, float degrees);
void dl_engine_set_surround_level(DLEngine *e, float level);
void dl_engine_set_orbit(DLEngine *e, float degreesPerSecond);
void dl_engine_set_rotation(DLEngine *e, float degrees);

/// Showcase demo (SPEC 14). Status as in domine_surround_demo_status.
void dl_engine_set_demo(DLEngine *e, int on);
int dl_engine_demo_status(DLEngine *e, float *seconds, float *azimuth, int *section);

/// Peak level per speaker from the last cycle (0...1), for meters.
float dl_engine_peak(DLEngine *e, uint32_t speaker);

// ---- Parity with the macOS app (added after the first draft) ----

/// Sync & Balance. Per-speaker manual delay offset in ms (0...300, the
/// engine adds distance compensation on top) and trim (as DLSpeaker.trim).
void dl_engine_set_delay_ms(DLEngine *e, uint32_t speaker, float ms);
/// Reported output latency of a speaker's sink in ms (from the stream's
/// pw_time), or -1 when unknown. Shown as "reported latencies" in the sheet.
float dl_engine_reported_latency_ms(DLEngine *e, uint32_t speaker);
/// Test tone (the shared chime, DomineChime.h) on one speaker; -1 is off.
void dl_engine_set_test_tone(DLEngine *e, int speaker);
/// Click test: a 2 ms 2 kHz click on every speaker once a second (same
/// signal as the macOS kernel's click test, DomineDSP.h), 0 off, 1 on.
void dl_engine_set_click_test(DLEngine *e, int on);

/// Sound sheet: effects per speaker (params as in DomineEQ.h, DomineBass.h,
/// DomineCompressor.h). Spatial ambience as DomineSpatial.h.
struct DomineEQParams; struct DomineBassParams; struct DomineCompressorParams; struct DomineSpatialParams;
void dl_engine_set_eq(DLEngine *e, uint32_t speaker, const void *eqParams);
void dl_engine_set_bass(DLEngine *e, uint32_t speaker, const void *bassParams);
void dl_engine_set_compressor(DLEngine *e, uint32_t speaker, const void *compressorParams);
void dl_engine_set_spatial(DLEngine *e, float amount, float roomMs);

/// Playing apps (PipeWire Stream/Output/Audio nodes) for per-app volume and
/// exclusions. Keyed by application.process.binary (fallback application.name).
typedef struct {
    char key[256];
    char label[256];     // application.name
    float volume;        // 0...1
    int excluded;        // plays through excludeSinkId instead of Domine
} DLApp;
uint32_t dl_engine_apps(DLEngine *e, DLApp *out, uint32_t max);
void dl_engine_set_app_volume(DLEngine *e, const char *key, float volume);
/// Excluded apps are moved (target.object metadata) to excludeSinkId, or to
/// the previous default sink when excludeSinkId is NULL or empty.
void dl_engine_set_app_excluded(DLEngine *e, const char *key, int excluded, const char *excludeSinkId);

/// Volume keys: the Domine virtual sink's own volume (what the desktop's
/// volume keys and sliders change) drives the master volume. The engine keeps
/// the sink at 100% internally and reports the requested level here; the UI
/// shows it and dl_engine_set_master updates the sink volume too.
float dl_engine_master(DLEngine *e);

#endif
