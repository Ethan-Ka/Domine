// Domine for Linux: pure stage geometry (no GTK). Shared by the stage widget
// and the --self-test checks.
//
// Azimuth follows DomineSurround.h: degrees, 0 is straight ahead (top of the
// stage, "FRONT"), positive is clockwise seen from above (to the right),
// range (-180, 180].
#ifndef DOMINE_UI_GEOMETRY_H
#define DOMINE_UI_GEOMETRY_H

#include <stdint.h>

#define DL_DISTANCE_MIN 0.5f
#define DL_DISTANCE_MAX 10.0f
#define DL_DISTANCE_DEFAULT 2.0f
#define DL_SNAP_DEGREES 5.0f
#define DL_SURROUND_MIN_SPEAKERS 3
#define DL_STEREO_AZIMUTH 30.0f

/// Stage circle in widget coordinates: centre (cx, cy), the radius used for
/// DL_DISTANCE_MIN (inner) and for DL_DISTANCE_MAX (outer).
typedef struct {
    double cx, cy;
    double inner, outer;
} DLStageFrame;

typedef enum {
    DL_PRESET_QUAD = 0,
    DL_PRESET_FIVE,
    DL_PRESET_SEVEN,
    DL_PRESET_RING,
    DL_PRESET_COUNT
} DLPreset;

/// Wraps any finite angle into (-180, 180]. Non-finite gives 0.
float dl_geom_wrap(float degrees);
/// Rounds to the nearest DL_SNAP_DEGREES step, then wraps.
float dl_geom_snap(float degrees);
float dl_geom_clamp_distance(float metres);

/// Distance (clamped) to stage radius. Logarithmic so 1 to 4 m, where most
/// speakers sit, gets most of the room.
double dl_geom_distance_to_radius(const DLStageFrame *f, float metres);
float dl_geom_radius_to_distance(const DLStageFrame *f, double radius);

/// Polar to widget coordinates and back.
void dl_geom_to_point(const DLStageFrame *f, float azimuth, float metres, double *x, double *y);
void dl_geom_from_point(const DLStageFrame *f, double x, double y, float *azimuth, float *metres);

/// Fits the stage circle into a width x height area, keeping a margin of
/// half a card (cardW x cardH) plus pad on every side.
DLStageFrame dl_geom_frame(double width, double height, double cardW, double cardH, double pad);

/// Stereo card centre (card 0 left, 1 right): level with the listener,
/// a little outside the guide circle, kept inside a widget `width` wide.
void dl_geom_stereo_point(const DLStageFrame *f, double width, double cardW, uint32_t card, double *x, double *y);

/// Writes the azimuths of a preset for `count` speakers (count is needed for
/// the ring). Returns how many positions the preset defines (Quad 4,
/// 5 Speakers 5, 7 Speakers 7, Ring max(count, 3)); at most `max` are written.
uint32_t dl_geom_preset(DLPreset preset, uint32_t count, float *out, uint32_t max);
const char *dl_geom_preset_name(DLPreset preset);

/// Azimuth in the middle of the widest empty arc between the given speakers
/// (snapped). 0 when count is 0, 180 when count is 1.
float dl_geom_gap_azimuth(uint32_t count, const float *azimuth);

/// "-30°", "0°", "+45°". buf needs 16 bytes.
void dl_geom_format_angle(float degrees, char *buf, uint32_t len);

/// UI name of a DOMINE_DEMO_SECTION_* value ("" for idle/finished).
const char *dl_demo_section_name(int section);

#endif
