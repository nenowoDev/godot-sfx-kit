# SFX Kit (Godot 4.7 add-on)

Procedural sound effects (shots, impacts, explosions, footsteps, servos, engine loops) and **SFX Studio** to
tweak and save them. Sounds are small JSON presets for an sfxr-style synth: a few layered voices, each an
oscillator with an envelope, pitch moves and filters. A preset is rendered to PCM once and cached as an
`AudioStreamWAV`, so playing it again costs nothing. A preset can name a recorded file instead. Uses the
Machine Assembler add-on's UI theme and keymap for the Studio; the sound classes themselves need nothing else.

## Play a sound

```gdscript
var sfx := SfxPlayer.create()                       # SfxLibrary.load_default(), 16 world + 6 UI voices
add_child(sfx)
sfx.play("fire_shell", muzzle_node)                 # at a Node3D's position, or a Vector3
sfx.play("step_heavy", foot_point, 0.8, 3.0)        # pitch x0.8 and +3 dB: a big machine (lower, louder)
sfx.play_ui("ui_click")                             # no position: interface sounds
var hum := sfx.attach("engine_loop", ship)          # a loop riding the node
hum.pitch_scale = 1.0 + speed / 20.0                # rev it with speed / thrust
sfx.stop(hum)                                       # fades out (0.08 s) and frees itself
SfxLibrary.load_default().warm([], true)            # optional, at load: render everything on a worker thread
```

**Voice pool**: one-shots share `voices` AudioStreamPlayer3D (default 16) and `ui_voices` AudioStreamPlayer
(6). When all are busy the oldest of the lowest priority is stolen; a sound never takes a voice from a more
important one (it's skipped and `skipped` counts it), and one sound holds at most its `max_instances` voices
(a gatling can't drown out an explosion). **Jitter**: every play varies pitch and volume a little
(`pitch_jitter`, `volume_jitter`) from `rng` (seed it for repeatable runs). **Bus**: `bus` (default `SFX`, falls
back to `Master` when the project has no such bus).

**Rendering cost**: about 0.14 s of CPU per second of sound (GDScript, 44.1 kHz). The 37 built-in presets are
~19 s of audio, ~2-3 s to render all. A sound renders the first time it plays; call `warm([], true)` during a
loading screen so no first play waits. Edits in the Studio re-render only the changed sound.

## The presets (`sounds/`)

| Sound | For |
|---|---|
| `fire_round`, `fire_slug`, `fire_shell`, `fire_cannonball`, `fire_missile`, `fire_laser`, `fire_plasma`, `fire_arc`, `fire_flame` | one per ammo type (Machine Parts `stats/ammo.csv`): `"fire_" + ammo.to_lower()` |
| `impact_kinetic`, `impact_explosive`, `impact_energy`, `impact_electric`, `impact_fire` | one per ammo kind: `"impact_" + kind` |
| `explosion` | a machine or a big thing blowing up |
| `zap` | an electric jump (Tesla chain) |
| `part_break` | a part breaking off |
| `step_heavy`, `step_light` | footsteps (lower the pitch with mass) |
| `servo` | a joint or turret turning |
| `jump`, `land`, `dash` | movement |
| `slide_start`, `slide_loop`, `wallrun_start`, `wallrun_loop`, `wall_jump`, `air_jump` | a light machine's agile moves (the loops' pitch and level follow speed) |
| `tracks_loop`, `engine_loop`, `thruster_loop` | loops: attach them, raise `pitch_scale` with speed / thrust |
| `reload`, `ready` | weapon state: a reload click, a ready ping |
| `ui_click`, `ui_hover`, `part_snap` | interface and assembly |

They're starting points: tune them in SFX Studio. A project's own presets (project setting
`sfx_kit/sounds_dir`, default `res://sfx`) override built-in ones of the same name; Studio saves there.

## SFX Studio

Run `res://addons/sfx_kit/app/sfx_studio.tscn` (or Project > Tools > Open SFX Studio). Pick a sound; every
slider changes it and the wave picture follows at once (red = it would clip). With **Auto-play** it plays again
0.3 s after you let go. **Play** (Space), **Randomise** (R: a new 1-3 voice sound), **Mutate** (M: nudges every
setting by up to 15 %, settings at 0 stay off), Save writes `<sounds_dir>/<name>.json`. Keys are rebindable
(Ctrl+/). Command line (after `--`): `--sound=<name>`, `--shot=<png>`, `--test`.

## Sound format

```json
{"format": "sfx-sound", "version": 1, "name": "fire_laser", "loop": false, "loop_length": 1.0,
 "volume_db": 0.0, "pitch_jitter": 0.04, "volume_jitter": 1.5, "distance": 70, "priority": 2,
 "max_instances": 4, "sample": "",
 "voices": [{"wave": "square", "volume": 0.25, "freq": 1600, "slide": -7.0, "sustain": 0.02, "decay": 0.16,
             "duty": 0.3, "duty_sweep": 1.5, "lpf": 6000},
            {"wave": "sine", "volume": 0.2, "freq": 3200, "slide": -8.0, "decay": 0.1}]}
```

Every key is optional; readers fill in the defaults (`SfxLibrary.SOUND_DEFAULTS`, `VOICE_DEFAULTS`).

Sound keys: `loop` (plays until stopped; renders `loop_length` seconds at full level, its end cross-faded into
its start so it repeats without a click), `volume_db` (gain at play time: keep the voices under a peak of 1.0
and raise this instead), `pitch_jitter` (fraction, +-), `volume_jitter` (dB, +-), `distance` (metres it's heard
to), `priority` (0 ambience, 1 movement / UI, 2 weapons, 3 big threats), `max_instances`, `sample` (a recorded
file: an imported `res://` .wav / .ogg, or a plain .wav / .ogg / .mp3 file such as `user://`; plays instead of
the voices, which stay as the fallback when the file is missing).

Voice keys (layer 2-3 voices: a sharp **transient**, a **body** for the weight, a **tail** for the space):

| Key | Meaning |
|---|---|
| `wave` | `square` (hollow, retro; `duty` = pulse width), `saw` (buzzy, bright), `sine` (pure, for thumps and pings), `triangle` (soft), `noise` (hiss to rumble: `freq` sets how fast it changes, low = rumble) |
| `volume`, `delay` | level 0-1; start later in seconds (stack layers in time) |
| `attack`, `sustain`, `punch`, `decay`, `curve` | envelope in seconds: fade in, hold (`punch` 0-1 = louder at the start of the hold), fade out (`curve` > 1 = falls fast then lingers) |
| `freq`, `freq_min` | start pitch in Hz; the slide never goes below `freq_min` |
| `slide`, `delta_slide` | pitch change in octaves per second (- = falling, the classic "pew"), and how fast the slide itself changes |
| `vibrato_depth`, `vibrato_speed` | wobble in semitones, at Hz |
| `arp_mult`, `arp_time` | pitch jumps x`arp_mult` at `arp_time` s (a two-note ping) |
| `repeat` | restarts the pitch moves every N seconds (crackle, alarms) |
| `duty`, `duty_sweep` | square pulse width 0.05-0.95, change per second |
| `lpf`, `lpf_sweep`, `lpf_resonance` | low-pass cutoff Hz (0 = off; lower = duller, further away), sweep in octaves / s, resonance 0-0.95 (a whistle at the cutoff) |
| `hpf`, `hpf_sweep` | high-pass cutoff Hz (0 = off; thins a sound to a click or hiss), sweep |
| `flanger_ms`, `flanger_sweep` | a short echo that makes jets and whooshes swirl |
| `drive` | 0-1 soft saturation: grit for explosions and electric buzz |

Rendering is deterministic (noise is seeded from the sound's name): variety comes from the play jitter.
Square and saw are band-limited, so high notes don't alias.

## In the Machine Parts Workshop

When this add-on is installed, the Workshop plays its sounds (loaded by path, so the Machine Assembler add-on
works without it): a fire sound per ammo type, an impact per ammo kind, electric zaps on chain jumps, footsteps
from the gait's foot plants (pitch and level follow mass), jump / land while driving, every agile move of a light
machine (dash, slide scrape, wall run, wall jump, air jump: Machine Assembler `MachineAgileFx`), an engine,
thruster or tracks loop while driving, a part snapping on in Build and parts breaking off.

## Test

From the machine-parts repo root: `python tools/pipeline.py sfx-test` (headless; expects `SFXTEST problems: 0`).
Screenshot: `python tools/pipeline.py sfx-shot OUT.png -- --sound=explosion`.
