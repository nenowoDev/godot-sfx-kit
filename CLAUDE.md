# SFX Kit (Godot 4.7 add-on)

Reusable add-on: lives at `addons/sfx_kit/` in any Godot project. Developed inside the machine-parts
repo's Workshop project (`godot/`, meant to become the submodule `godot-sfx-kit`), which is also where it's
tested. Edit it there and push it before the machine-parts project. Owner is a software engineer, not a
sound designer: explain sound choices in plain terms (transient / body / tail, pitch, filters).

## Rules

- Global class names are prefixed `Sfx` (`SfxLibrary`, `SfxSynth`, `SfxPlayer`, `SfxStudio`).
- `core/` must work alone (games use it at runtime). Only `app/` (SFX Studio) uses the Machine
  Assembler add-on (its UI theme and keymap).
- Sounds are data: JSON presets (README "Sound format"). Readers fill defaults for missing keys; bump
  `version` for breaking changes. Never hard-code a sound in GDScript.
- Keep every preset's rendered peak at or under 1.0 (the self-test fails on clipping): lower the voice
  volumes and raise the sound's `volume_db` instead.
- Rendering is deterministic (seeded by the sound's name); per-play variety is the player's jitter.
- Naming the Machine Parts Workshop relies on: `fire_<ammo type lower case>`, `impact_<ammo kind>`,
  `step_heavy`, `step_light`, `jump`, `land`, `dash`, the agile moves `slide_start`, `slide_loop`, `wallrun_start`,
  `wallrun_loop`, `wall_jump`, `air_jump` (MachineAgileFx falls back to older ones when missing), `zap`, `part_snap`, `part_break`, `explosion`, and the
  loops `engine_loop`, `thruster_loop`, `tracks_loop`. The self-test checks fire / impact coverage against
  `res://machine_parts/stats.json` when it exists.
- The Machine Assembler add-on loads this one by path (optional). Keep `SfxLibrary.load_default()`,
  `SfxPlayer.create()` / `play()` / `play_ui()` / `attach()` / `stop()` stable.
- A background `warm()` runs on WorkerThreadPool: call `wait()` before the library goes away (the Studio
  does it in `_exit_tree`; `clear_cache()` does it too).

## Test

From the machine-parts repo root: `python tools/pipeline.py sfx-test` (headless; expects `SFXTEST problems: 0`).

## Release

Bump `plugin.cfg` version, add a CHANGELOG entry, commit, `git tag -a vX.Y.Z -m vX.Y.Z` (annotated: `push --follow-tags` only sends annotated tags), push with `--follow-tags`.
