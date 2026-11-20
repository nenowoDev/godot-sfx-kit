class_name SfxLibrary
extends RefCounted
## The sound presets: small JSON files, one per sound. Built-in ones ship in addons/sfx_kit/sounds; a
## project's own (project setting sfx_kit/sounds_dir, default res://sfx) override them by name, and that's
## where SFX Studio saves. A preset is rendered to PCM once (SfxSynth) and cached as an AudioStreamWAV, so
## playing it again costs nothing.
##
##     var sfx := SfxLibrary.load_default()
##     var player := SfxPlayer.create(sfx)            # a pool of 3D voices; add_child(player)
##     player.play("impact_explosive", hit_point)
##
## A sound:
##     {"format": "sfx-sound", "version": 1, "name": "fire_laser", "loop": false, "volume_db": 0.0,
##      "pitch_jitter": 0.04, "volume_jitter": 1.5, "distance": 60.0, "priority": 2, "max_instances": 4,
##      "sample": "",
##      "voices": [{"wave": "square", "volume": 0.35, "freq": 1600, "slide": -7.0, "sustain": 0.02,
##                  "decay": 0.18, "duty": 0.3, "lpf": 6000}]}
##
## Voices are layered (a transient, a body, a tail: PRESENTATION 6). Every voice key is optional (VOICE_DEFAULTS
## fills it in). `sample` names a recorded file (.wav / .ogg / any AudioStream resource) to play instead of
## the voices. README "Sound format" explains every key.

const FORMAT := "sfx-sound"
const VERSION := 1
const BUILTIN_DIR := "res://addons/sfx_kit/sounds"
const SETTING_DIR := "sfx_kit/sounds_dir"
const WAVES := ["square", "saw", "sine", "triangle", "noise"]
const SOUND_DEFAULTS := {"loop": false, "loop_length": 1.0, "volume_db": 0.0, "pitch_jitter": 0.04,
	"volume_jitter": 1.5, "distance": 40.0, "priority": 1, "max_instances": 4, "sample": ""}
const VOICE_DEFAULTS := {"wave": "square", "volume": 0.5, "delay": 0.0,
	"attack": 0.0, "sustain": 0.1, "punch": 0.0, "decay": 0.2, "curve": 1.5,
	"freq": 440.0, "freq_min": 20.0, "slide": 0.0, "delta_slide": 0.0,
	"vibrato_depth": 0.0, "vibrato_speed": 6.0, "arp_mult": 1.0, "arp_time": 0.0,
	"duty": 0.5, "duty_sweep": 0.0, "repeat": 0.0,
	"lpf": 0.0, "lpf_sweep": 0.0, "lpf_resonance": 0.0, "hpf": 0.0, "hpf_sweep": 0.0,
	"flanger_ms": 0.0, "flanger_sweep": 0.0, "drive": 0.0}
## Editor ranges per key: [min, max, step, log scale]. SFX Studio's sliders and Randomise / Mutate use them.
const RANGES := {
	"volume": [0.0, 1.0, 0.01, false], "delay": [0.0, 1.0, 0.005, false],
	"attack": [0.0, 1.0, 0.005, false], "sustain": [0.0, 2.0, 0.005, false], "punch": [0.0, 1.0, 0.01, false],
	"decay": [0.0, 3.0, 0.005, false], "curve": [0.5, 4.0, 0.05, false],
	"freq": [10.0, 8000.0, 1.0, true], "freq_min": [10.0, 2000.0, 1.0, true],
	"slide": [-12.0, 12.0, 0.05, false], "delta_slide": [-40.0, 40.0, 0.1, false],
	"vibrato_depth": [0.0, 12.0, 0.05, false], "vibrato_speed": [0.0, 80.0, 0.1, false],
	"arp_mult": [0.25, 4.0, 0.01, false], "arp_time": [0.0, 1.0, 0.005, false],
	"duty": [0.05, 0.95, 0.01, false], "duty_sweep": [-4.0, 4.0, 0.05, false], "repeat": [0.0, 1.0, 0.005, false],
	"lpf": [0.0, 16000.0, 10.0, false], "lpf_sweep": [-8.0, 8.0, 0.05, false], "lpf_resonance": [0.0, 0.95, 0.01, false],
	"hpf": [0.0, 8000.0, 10.0, false], "hpf_sweep": [-8.0, 8.0, 0.05, false],
	"flanger_ms": [0.0, 20.0, 0.05, false], "flanger_sweep": [-20.0, 20.0, 0.1, false], "drive": [0.0, 1.0, 0.01, false],
	"volume_db": [-30.0, 12.0, 0.5, false], "pitch_jitter": [0.0, 0.3, 0.005, false],
	"volume_jitter": [0.0, 6.0, 0.1, false], "distance": [2.0, 300.0, 1.0, false], "priority": [0, 3, 1, false],
	"max_instances": [1, 16, 1, false], "loop_length": [0.1, 4.0, 0.05, false]}

static var _cache := {}

var sounds := {}                       # name -> sound dictionary (defaults filled in)
var sources := {}                      # name -> file it came from
var _rendered := {}                    # name -> {"sig": hash of the sound, "stream", "peak", "rms", "length"}
var _mutex := Mutex.new()
var _task := -1


static func project_dir() -> String:
	return ProjectSettings.get_setting(SETTING_DIR, "res://sfx")


## Built-in presets plus the project's, cached (clear_cache() after saving new ones).
static func load_default() -> SfxLibrary:
	var key := project_dir()
	if not _cache.has(key):
		var lib := SfxLibrary.new()
		lib.load_dir(BUILTIN_DIR)
		lib.load_dir(key)
		_cache[key] = lib
	return _cache[key]


static func clear_cache() -> void:
	for lib in _cache.values():
		(lib as SfxLibrary).wait()
	_cache.clear()


func load_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		var path := dir_path + "/" + f
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if data is Dictionary and data.get("format", "") == FORMAT:
			var sound := normalized(data)
			if sound["name"] == "":
				sound["name"] = f.get_basename()
			sounds[sound["name"]] = sound
			sources[sound["name"]] = path


func has(sound_name: String) -> bool:
	return sounds.has(sound_name)


func names() -> Array:
	var out := sounds.keys()
	out.sort()
	return out


## A copy with every missing key filled in (so editors and the synth can rely on them).
static func normalized(data: Dictionary) -> Dictionary:
	var s := {"format": FORMAT, "version": VERSION, "name": str(data.get("name", ""))}
	for key in SOUND_DEFAULTS:
		s[key] = data.get(key, SOUND_DEFAULTS[key])
	s["loop"] = bool(s["loop"])
	s["priority"] = int(s["priority"])
	s["max_instances"] = int(s["max_instances"])
	s["sample"] = str(s["sample"])
	for key in ["loop_length", "volume_db", "pitch_jitter", "volume_jitter", "distance"]:
		s[key] = float(s[key])
	s["voices"] = []
	for voice in data.get("voices", []):
		s["voices"].append(normalized_voice(voice))
	return s


static func normalized_voice(voice: Dictionary) -> Dictionary:
	var v := VOICE_DEFAULTS.duplicate(true)
	for key in voice:
		if key == "wave":
			v["wave"] = str(voice["wave"]) if WAVES.has(str(voice["wave"])) else "square"
		elif v.has(key):
			v[key] = float(voice[key])
		else:
			v[key] = voice[key]                 # unknown keys survive a save (readers ignore them)
	return v


static func save(sound: Dictionary, dir_path := "") -> Error:
	var target := dir_path if dir_path != "" else project_dir()
	DirAccess.make_dir_recursive_absolute(target)
	var f := FileAccess.open("%s/%s.json" % [target, sound["name"]], FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(normalized(sound), "\t"))
	return OK


## The sound ready to play (rendered once, then cached; a recorded `sample` is loaded instead). null if unknown.
func stream(sound_name: String) -> AudioStream:
	var info := rendered(sound_name)
	return info.get("stream")


## {"stream", "peak", "rms", "length", "sample"} for a sound, rendering it if it changed since last time.
func rendered(sound_name: String) -> Dictionary:
	if not sounds.has(sound_name):
		return {}
	var sound: Dictionary = sounds[sound_name]
	var sig := hash(sound)
	_mutex.lock()
	var info: Dictionary = _rendered.get(sound_name, {})
	_mutex.unlock()
	if info.get("sig", 0) == sig:
		return info
	info = render(sound)
	info["sig"] = sig
	_mutex.lock()
	_rendered[sound_name] = info
	_mutex.unlock()
	return info


## Renders (or loads) one sound dictionary, uncached. See SfxSynth.render.
static func render(sound: Dictionary) -> Dictionary:
	var path: String = sound.get("sample", "")
	if path != "":
		var sample := load_sample(path)
		if sample != null:
			return {"stream": sample, "peak": -1.0, "rms": -1.0, "length": sample.get_length(), "sample": path}
		push_warning("SfxLibrary: sample %s not found for %s; using its voices" % [path, sound.get("name", "")])
	return SfxSynth.render(sound)


## A recorded sound from a project resource (imported .wav / .ogg) or a plain file (user://, a mod folder).
static func load_sample(path: String) -> AudioStream:
	if ResourceLoader.exists(path):
		return load(path) as AudioStream
	if not FileAccess.file_exists(path):
		return null
	match path.get_extension().to_lower():
		"wav":
			return AudioStreamWAV.load_from_file(path)
		"ogg":
			return AudioStreamOggVorbis.load_from_file(path)
		"mp3":
			return AudioStreamMP3.load_from_file(path)
	return null


## Renders every sound (or `only`) now, so the first play of each doesn't wait. With `background` it runs on a
## worker thread and returns at once (wait() blocks until it's done; plays meanwhile render what they need).
func warm(only := [], background := false) -> void:
	var list: Array = only if not only.is_empty() else names()
	if not background:
		for n in list:
			rendered(n)
		return
	wait()
	_task = WorkerThreadPool.add_task(func():
		for n in list:
			rendered(n), false, "SfxLibrary.warm")


## Blocks until a background warm() is done.
func wait() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


## Longest a sound lasts in seconds (a loop: its loop length).
static func duration(sound: Dictionary) -> float:
	if sound.get("loop", false):
		return float(sound.get("loop_length", 1.0))
	var longest := 0.0
	for v in sound.get("voices", []):
		longest = maxf(longest, SfxSynth.voice_length(v))
	return longest
