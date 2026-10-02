// Domine for Linux: pure UI logic shared by the dialogs (no GTK). Mirrors
// the macOS TuningState, SurroundControls and PairSettings helpers, and is
// covered by --self-test.
#ifndef DOMINE_UI_LOGIC_H
#define DOMINE_UI_LOGIC_H

#include <stdint.h>
#include "settings.h"
#include "DomineEQ.h"
#include "DomineBass.h"
#include "DomineCompressor.h"

/// "Right +4 ms", "Left +12 ms", "In sync" (rounded to whole ms).
void dl_delay_readout(float signedMs, char *buf, uint32_t len);
/// "+12 ms" for one surround speaker (0 gives "0 ms").
void dl_delay_short(float ms, char *buf, uint32_t len);
/// "Right 20%", "Left 5%", "Centered".
void dl_balance_readout(float balance, char *buf, uint32_t len);
/// Balance only ever attenuates the far side (macOS PairSettings).
float dl_balance_left_gain(float balance);
float dl_balance_right_gain(float balance);
/// Signed stereo offset to per-speaker delays (0...300 each).
void dl_stereo_delays(float signedMs, float *leftMs, float *rightMs);
/// "Off" below 0.005, otherwise "0.25/s".
void dl_orbit_text(float turnsPerSecond, char *buf, uint32_t len);
/// Master and app volumes are linear gains; sliders show them on the
/// desktop's cubic scale (slider 50% is gain 0.125), like PipeWire mixers.
float dl_volume_to_slider(float linear);
float dl_slider_to_volume(float position);
/// "70%".
void dl_percent_text(float unit, char *buf, uint32_t len);

/// Sound sheet presets, as on the Mac.
typedef enum {
    DL_FX_FLAT = 0,
    DL_FX_BASS_BOOST,
    DL_FX_VOCAL,
    DL_FX_LOUDNESS,
    DL_FX_NIGHT,
    DL_FX_PRESET_COUNT
} DLFxPreset;
const char *dl_fx_preset_name(DLFxPreset p);
void dl_fx_preset(DLFxPreset p, DLEffects *out);
/// Preset the effects match, or -1 (Custom).
int dl_fx_match(const DLEffects *fx);
int dl_fx_equal(const DLEffects *a, const DLEffects *b);
extern const char *const dl_eq_band_labels[DL_EQ_BANDS];

/// Kernel parameters for one speaker's effects (macOS SideEffects mapping).
void dl_fx_eq_params(const DLEffects *fx, DomineEQParams *out);
void dl_fx_bass_params(const DLEffects *fx, DomineBassParams *out);
void dl_fx_comp_params(const DLEffects *fx, DomineCompressorParams *out);

/// Card names: "Front Left", "Front Right" in Stereo, "Speaker 3" in Surround.
void dl_card_name(DLMode mode, uint32_t card, char *buf, uint32_t len);

/// Mono fallback banner, or "" when nothing is missing. missing[i] nonzero
/// for each card whose (assigned) sink is gone.
void dl_fallback_banner(DLMode mode, uint32_t count, const int *missing, char *buf, uint32_t len);

#endif
