// Domine for Linux: pure stage geometry. See ui_geometry.h.
#include "ui_geometry.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "DomineDemo.h"

#define DL_PI 3.14159265358979323846

float dl_geom_wrap(float degrees)
{
    if (!isfinite(degrees)) return 0.0f;
    double d = fmod((double)degrees, 360.0);
    if (d <= -180.0) d += 360.0;
    if (d > 180.0) d -= 360.0;
    return (float)d;
}

float dl_geom_snap(float degrees)
{
    float w = dl_geom_wrap(degrees);
    return dl_geom_wrap(roundf(w / DL_SNAP_DEGREES) * DL_SNAP_DEGREES);
}

float dl_geom_clamp_distance(float metres)
{
    if (!isfinite(metres)) return DL_DISTANCE_DEFAULT;
    if (metres < DL_DISTANCE_MIN) return DL_DISTANCE_MIN;
    if (metres > DL_DISTANCE_MAX) return DL_DISTANCE_MAX;
    return metres;
}

double dl_geom_distance_to_radius(const DLStageFrame *f, float metres)
{
    double d = dl_geom_clamp_distance(metres);
    double t = log(d / DL_DISTANCE_MIN) / log((double)DL_DISTANCE_MAX / DL_DISTANCE_MIN);
    return f->inner + t * (f->outer - f->inner);
}

float dl_geom_radius_to_distance(const DLStageFrame *f, double radius)
{
    double span = f->outer - f->inner;
    double t = span > 0 ? (radius - f->inner) / span : 0.0;
    if (t < 0) t = 0;
    if (t > 1) t = 1;
    double d = DL_DISTANCE_MIN * exp(t * log((double)DL_DISTANCE_MAX / DL_DISTANCE_MIN));
    return dl_geom_clamp_distance((float)d);
}

void dl_geom_to_point(const DLStageFrame *f, float azimuth, float metres, double *x, double *y)
{
    double r = dl_geom_distance_to_radius(f, metres);
    double a = dl_geom_wrap(azimuth) * DL_PI / 180.0;
    *x = f->cx + r * sin(a);
    *y = f->cy - r * cos(a);
}

void dl_geom_from_point(const DLStageFrame *f, double x, double y, float *azimuth, float *metres)
{
    double dx = x - f->cx, dy = y - f->cy;
    double r = sqrt(dx * dx + dy * dy);
    *azimuth = r > 0 ? dl_geom_wrap((float)(atan2(dx, -dy) * 180.0 / DL_PI)) : 0.0f;
    *metres = dl_geom_radius_to_distance(f, r);
}

DLStageFrame dl_geom_frame(double width, double height, double cardW, double cardH, double pad)
{
    DLStageFrame f;
    f.cx = width / 2.0;
    f.cy = height / 2.0;
    double rx = width / 2.0 - cardW / 2.0 - pad;
    double ry = height / 2.0 - cardH / 2.0 - pad;
    f.outer = rx < ry ? rx : ry;
    if (f.outer < 20.0) f.outer = 20.0;
    f.inner = f.outer * 0.4;
    return f;
}

void dl_geom_stereo_point(const DLStageFrame *f, double width, double cardW, uint32_t card, double *x, double *y)
{
    double dx = dl_geom_distance_to_radius(f, DL_DISTANCE_DEFAULT) + cardW / 2.0 + 12.0;
    double maxDx = width / 2.0 - cardW / 2.0 - 8.0;
    if (dx > maxDx) dx = maxDx;
    if (dx < cardW / 2.0 + 24.0) dx = cardW / 2.0 + 24.0;
    *x = card == 0 ? f->cx - dx : f->cx + dx;
    *y = f->cy;
}

static const float kQuad[] = { -45.0f, 45.0f, -135.0f, 135.0f };
static const float kFive[] = { -30.0f, 30.0f, 0.0f, -110.0f, 110.0f };
static const float kSeven[] = { -30.0f, 30.0f, 0.0f, -90.0f, 90.0f, -150.0f, 150.0f };

uint32_t dl_geom_preset(DLPreset preset, uint32_t count, float *out, uint32_t max)
{
    const float *table = NULL;
    uint32_t n = 0;
    switch (preset) {
    case DL_PRESET_QUAD: table = kQuad; n = 4; break;
    case DL_PRESET_FIVE: table = kFive; n = 5; break;
    case DL_PRESET_SEVEN: table = kSeven; n = 7; break;
    case DL_PRESET_RING:
    default:
        n = count < DL_SURROUND_MIN_SPEAKERS ? DL_SURROUND_MIN_SPEAKERS : count;
        break;
    }
    for (uint32_t i = 0; i < n && i < max; i++)
        out[i] = table ? table[i] : dl_geom_wrap(360.0f * (float)i / (float)n);
    return n;
}

const char *dl_geom_preset_name(DLPreset preset)
{
    switch (preset) {
    case DL_PRESET_QUAD: return "Quad";
    case DL_PRESET_FIVE: return "5 Speakers";
    case DL_PRESET_SEVEN: return "7 Speakers";
    case DL_PRESET_RING: return "Ring";
    default: return "";
    }
}

static int cmp_float(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

float dl_geom_gap_azimuth(uint32_t count, const float *azimuth)
{
    if (count == 0) return 0.0f;
    if (count == 1) return dl_geom_wrap(azimuth[0] + 180.0f);
    float sorted[64];
    uint32_t n = count > 64 ? 64 : count;
    for (uint32_t i = 0; i < n; i++) {
        float a = dl_geom_wrap(azimuth[i]);
        sorted[i] = a < 0 ? a + 360.0f : a;
    }
    qsort(sorted, n, sizeof(float), cmp_float);
    float bestGap = -1.0f, bestMid = 0.0f;
    for (uint32_t i = 0; i < n; i++) {
        float a = sorted[i];
        float b = (i + 1 < n) ? sorted[i + 1] : sorted[0] + 360.0f;
        float gap = b - a;
        if (gap > bestGap + 1e-3f) {
            bestGap = gap;
            bestMid = a + gap / 2.0f;
        }
    }
    return dl_geom_snap(bestMid);
}

void dl_geom_format_angle(float degrees, char *buf, uint32_t len)
{
    int v = (int)lroundf(dl_geom_wrap(degrees));
    if (v > 0 && v < 180)
        snprintf(buf, len, "+%d°", v);
    else
        snprintf(buf, len, "%d°", v);
}

const char *dl_demo_section_name(int section)
{
    switch (section) {
    case DOMINE_DEMO_SECTION_ROLL_CALL: return "Roll call";
    case DOMINE_DEMO_SECTION_PING_PONG: return "Left and right";
    case DOMINE_DEMO_SECTION_ORBIT: return "Orbit";
    case DOMINE_DEMO_SECTION_SWELL: return "Swell";
    case DOMINE_DEMO_SECTION_DROP: return "Drop";
    default: return "";
    }
}
