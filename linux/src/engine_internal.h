// Domine for Linux: engine helpers exposed for the self-test (private).
#ifndef DOMINE_LINUX_ENGINE_INTERNAL_H
#define DOMINE_LINUX_ENGINE_INTERNAL_H

#include <stddef.h>

/// Extracts the "name" string from a default-sink metadata value such as
/// { "name": "alsa_output.usb" }. Returns 1 and writes a NUL-terminated name
/// on success, 0 (out set to "") when there is no name.
int dl_json_name(const char *json, char *out, size_t len);

/// Sample rate, kernel chunk and ring sizes the engine uses (frames).
#define DL_RATE 48000
#define DL_MAX_FRAMES 1024
#define DL_RING_FRAMES 8192
#define DL_RING_TARGET 1536
#define DL_RING_HIGH 4096
#define DL_SINK_NAME "domine"

#endif
