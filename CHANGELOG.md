# Changelog

## 0.1.0

- First version (SFX builder stage 1 of the Machine Parts project, ROADMAP 8): `SfxLibrary` (JSON sound
  presets, built-in + project folder, rendered once and cached; a background `warm()`; recorded samples by
  path), `SfxSynth` (an sfxr-style synth: square / saw / sine / triangle / noise voices, envelope with punch
  and curve, slide, vibrato, arpeggio, repeat, duty sweep, resonant low-pass and high-pass with sweeps,
  flanger, drive; band-limited square and saw; seamless loops), `SfxPlayer` (a pool of 3D and UI voices with
  priority, max-at-once and oldest-stolen, per-play pitch / volume jitter, attached loops that fade out).
- 31 presets: a fire sound per Machine Parts ammo type, an impact per ammo kind, explosion, zap, part break,
  heavy and light footsteps, servo, jump, land, dash, tracks / engine / thruster loops, reload, ready, UI
  click and hover, part snap.
- SFX Studio: sound list, a slider and number box for every setting, a wave picture, Play / Auto-play,
  Randomise, Mutate, Save; rebindable keys. Headless self-test (`SFXTEST problems: 0`).
