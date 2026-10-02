// Domine for Linux: pure UI logic. See ui_logic.h.
#include "ui_logic.h"

#include <math.h>
#include <stdio.h>
#include <string.h>

const char *const dl_eq_band_labels[DL_EQ_BANDS] = { "80", "250", "1k", "4k", "10k" };
static const float kBandHz[DL_EQ_BANDS] = { 80.0f, 250.0f, 1000.0f, 4000.0f, 10000.0f };

void dl_delay_readout(float signedMs, char *buf, uint32_t len)
{
    long ms = isfinite(signedMs) ? lroundf(signedMs) : 0;
    if (ms > 0) snprintf(buf, len, "Right +%ld ms", ms);
    else if (ms < 0) snprintf(buf, len, "Left +%ld ms", -ms);
    else snprintf(buf, len, "In sync");
}

void dl_delay_short(float ms, char *buf, uint32_t len)
{
    long v = isfinite(ms) ? lroundf(ms) : 0;
    if (v > 0) snprintf(buf, len, "+%ld ms", v);
    else snprintf(buf, len, "0 ms");
}

static float clamp_unit_signed(float v)
{
    if (!isfinite(v)) return 0.0f;
    return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
}

void dl_balance_readout(float balance, char *buf, uint32_t len)
{
    long p = lroundf(clamp_unit_signed(balance) * 100.0f);
    if (p > 0) snprintf(buf, len, "Right %ld%%", p);
    else if (p < 0) snprintf(buf, len, "Left %ld%%", -p);
    else snprintf(buf, len, "Centered");
}

float dl_balance_left_gain(float balance)
{
    float b = clamp_unit_signed(balance);
    return b > 0 ? 1.0f - b : 1.0f;
}

float dl_balance_right_gain(float balance)
{
    float b = clamp_unit_signed(balance);
    return b < 0 ? 1.0f + b : 1.0f;
}

void dl_stereo_delays(float signedMs, float *leftMs, float *rightMs)
{
    float d = isfinite(signedMs) ? signedMs : 0.0f;
    if (d > DL_DELAY_LIMIT) d = DL_DELAY_LIMIT;
    if (d < -DL_DELAY_LIMIT) d = -DL_DELAY_LIMIT;
    *leftMs = d < 0 ? -d : 0.0f;
    *rightMs = d > 0 ? d : 0.0f;
}

void dl_orbit_text(float turnsPerSecond, char *buf, uint32_t len)
{
    if (!isfinite(turnsPerSecond) || turnsPerSecond < 0.005f) snprintf(buf, len, "Off");
    else snprintf(buf, len, "%.2f/s", turnsPerSecond);
}

float dl_volume_to_slider(float linear)
{
    if (!isfinite(linear) || linear <= 0.0f) return 0.0f;
    return linear >= 1.0f ? 1.0f : cbrtf(linear);
}

float dl_slider_to_volume(float position)
{
    if (!isfinite(position) || position <= 0.0f) return 0.0f;
    if (position >= 1.0f) return 1.0f;
    return position * position * position;
}

void dl_percent_text(float unit, char *buf, uint32_t len)
{
    float u = isfinite(unit) ? unit : 0.0f;
    if (u < 0) u = 0;
    if (u > 1) u = 1;
    snprintf(buf, len, "%ld%%", lroundf(u * 100.0f));
}

const char *dl_fx_preset_name(DLFxPreset p)
{
    switch (p) {
    case DL_FX_FLAT: return "Flat";
    case DL_FX_BASS_BOOST: return "Bass Boost";
    case DL_FX_VOCAL: return "Vocal";
    case DL_FX_LOUDNESS: return "Loudness";
    case DL_FX_NIGHT: return "Night";
    default: return "";
    }
}

static void set_gains(DLEffects *fx, float a, float b, float c, float d, float e)
{
    fx->eqOn = 1;
    fx->eqDb[0] = a; fx->eqDb[1] = b; fx->eqDb[2] = c; fx->eqDb[3] = d; fx->eqDb[4] = e;
}

void dl_fx_preset(DLFxPreset p, DLEffects *fx)
{
    dl_effects_defaults(fx);
    switch (p) {
    case DL_FX_BASS_BOOST:
        set_gains(fx, 6, 2, 0, 0, 0);
        fx->bassOn = 1;
        fx->bass = 0.5f;
        break;
    case DL_FX_VOCAL: set_gains(fx, -3, -2, 2, 3, 0); break;
    case DL_FX_LOUDNESS: set_gains(fx, 5, 1, -1, 1, 4); break;
    case DL_FX_NIGHT:
        set_gains(fx, -4, 0, 0, 0, -2);
        fx->compOn = 1;
        fx->comp = 0.7f;
        break;
    case DL_FX_FLAT:
    default:
        break;
    }
}

int dl_fx_equal(const DLEffects *a, const DLEffects *b)
{
    if (a->eqOn != b->eqOn || a->bassOn != b->bassOn || a->compOn != b->compOn) return 0;
    if (fabsf(a->bass - b->bass) > 1e-4f || fabsf(a->comp - b->comp) > 1e-4f) return 0;
    for (int i = 0; i < DL_EQ_BANDS; i++)
        if (fabsf(a->eqDb[i] - b->eqDb[i]) > 1e-4f) return 0;
    return 1;
}

int dl_fx_match(const DLEffects *fx)
{
    for (int p = 0; p < DL_FX_PRESET_COUNT; p++) {
        DLEffects ref;
        dl_fx_preset((DLFxPreset)p, &ref);
        if (dl_fx_equal(fx, &ref)) return p;
    }
    return -1;
}

void dl_fx_eq_params(const DLEffects *fx, DomineEQParams *out)
{
    memset(out, 0, sizeof *out);
    out->enabled = fx->eqOn ? 1 : 0;
    for (int i = 0; i < DL_EQ_BANDS && i < DOMINE_EQ_BANDS; i++) {
        out->bands[i].freqHz = kBandHz[i];
        out->bands[i].gainDb = fx->eqDb[i];
        out->bands[i].q = 1.0f;
    }
}

void dl_fx_bass_params(const DLEffects *fx, DomineBassParams *out)
{
    out->enabled = fx->bassOn ? 1 : 0;
    out->amount = fx->bass;
    out->cutoffHz = 120.0f;
}

void dl_fx_comp_params(const DLEffects *fx, DomineCompressorParams *out)
{
    float a = fx->comp;
    out->enabled = fx->compOn ? 1 : 0;
    out->thresholdDb = -6.0f - 24.0f * a;
    out->ratio = 1.5f + 2.5f * a;
    out->attackMs = 10.0f;
    out->releaseMs = 100.0f;
    // Makeup restores half of the gain reduction a 0 dB peak would get.
    out->makeupDb = -out->thresholdDb * (1.0f - 1.0f / out->ratio) * 0.5f;
    out->limiterCeilingDb = -1.0f;
}

void dl_card_name(DLMode mode, uint32_t card, char *buf, uint32_t len)
{
    if (mode == DL_MODE_STEREO) snprintf(buf, len, "%s", card == 0 ? "Front Left" : "Front Right");
    else snprintf(buf, len, "Speaker %u", card + 1);
}

void dl_fallback_banner(DLMode mode, uint32_t count, const int *missing, char *buf, uint32_t len)
{
    buf[0] = '\0';
    uint32_t n = 0, first = 0;
    for (uint32_t i = 0; i < count; i++)
        if (missing[i]) {
            if (n == 0) first = i;
            n++;
        }
    if (n == 0) return;
    if (mode == DL_MODE_STEREO && count == 2) {
        if (n == 2) {
            snprintf(buf, len, "Both speakers disconnected.");
        } else {
            char gone[32], other[32];
            dl_card_name(mode, first, gone, sizeof gone);
            dl_card_name(mode, 1 - first, other, sizeof other);
            snprintf(buf, len, "%s disconnected. %s plays both sides until it reconnects.", gone, other);
        }
        return;
    }
    if (n == count) {
        snprintf(buf, len, "All speakers disconnected.");
    } else if (n == 1) {
        char gone[32];
        dl_card_name(mode, first, gone, sizeof gone);
        snprintf(buf, len, "%s disconnected. The speakers next to it cover its position until it reconnects.", gone);
    } else {
        snprintf(buf, len, "%u speakers disconnected. The others cover their positions until they reconnect.", n);
    }
}
