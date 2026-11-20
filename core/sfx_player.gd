class_name SfxPlayer
extends Node
## Plays SfxLibrary sounds from a small pool of voices: AudioStreamPlayer3D for sounds in the world (they
## come from where they happen, PRESENTATION 6) and AudioStreamPlayer for interface sounds. When every voice
## is busy the oldest of the lowest priority is stolen; a sound never steals a voice from a more important
## one (it's skipped instead), and one sound never holds more than its `max_instances` voices (a gatling
## doesn't drown everything else). Every play gets a small seeded pitch / volume jitter so repeats don't
## sound identical.
##
##     var player := SfxPlayer.create()               # SfxLibrary.load_default(), 16 world + 6 UI voices
##     add_child(player)
##     player.play("fire_shell", muzzle_node)         # at a node's position (or a Vector3)
##     player.play("step_heavy", foot, 0.8, 3.0)      # lower and louder for a big machine (FEEL 10)
##     player.play_ui("ui_click")
##     var hum := player.attach("engine_loop", ship)  # a loop that rides the node; set hum.pitch_scale freely
##     player.stop(hum)                               # fades out, then frees it

const FADE := 0.08                     # seconds a stopped loop takes to fade out

var library: SfxLibrary
var voices := 16                       # world voices (AudioStreamPlayer3D)
var ui_voices := 6                     # interface voices (AudioStreamPlayer)
## Audio bus for every voice; falls back to Master when the project has no bus of that name.
var bus := "SFX"
var rng := RandomNumberGenerator.new()  # the per-play jitter; set rng.seed for repeatable runs
var played := 0                        # sounds started (tests and probes read it)
var skipped := 0                       # plays dropped because every voice held something more important
var counts := {}                       # sound name -> times played

var _world := []                       # [{player, name, started, priority}]
var _ui := []
var _loops := []                       # attached loop players still alive
var _clock := 0                        # play order, for "oldest"


static func create(lib: SfxLibrary = null, world_voices := 16) -> SfxPlayer:
	var p := SfxPlayer.new()
	p.name = "SfxPlayer"
	p.library = lib if lib != null else SfxLibrary.load_default()
	p.voices = world_voices
	return p


func _ready() -> void:
	if library == null:
		library = SfxLibrary.load_default()
	if AudioServer.get_bus_index(bus) < 0:
		bus = "Master"
	for i in voices:
		var p := AudioStreamPlayer3D.new()
		p.bus = bus
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		add_child(p)
		_world.append({"player": p, "name": "", "started": 0, "priority": 0})
	for i in ui_voices:
		var p := AudioStreamPlayer.new()
		p.bus = bus
		add_child(p)
		_ui.append({"player": p, "name": "", "started": 0, "priority": 0})


## Plays a one-shot at `at` (a Vector3 or a Node3D's position; null = an interface sound). `pitch` and
## `volume_db` scale the preset (a big machine: lower and louder). Returns the voice, or null when the sound
## is unknown or every voice holds something more important.
func play(sound_name: String, at = null, pitch := 1.0, volume_db := 0.0) -> Node:
	if at == null:
		return play_ui(sound_name, pitch, volume_db)
	var sound: Dictionary = library.sounds.get(sound_name, {})
	if sound.is_empty():
		return null
	var slot := _pick(_world, sound)
	if slot.is_empty():
		return null
	var p: AudioStreamPlayer3D = slot["player"]
	p.stop()
	p.global_position = at.global_position if at is Node3D else at
	_setup_3d(p, sound)
	_start(slot, p, sound, pitch, volume_db)
	return p


## An interface sound (no position): clicks, hovers, the Workshop's snap.
func play_ui(sound_name: String, pitch := 1.0, volume_db := 0.0) -> AudioStreamPlayer:
	var sound: Dictionary = library.sounds.get(sound_name, {})
	if sound.is_empty():
		return null
	var slot := _pick(_ui, sound)
	if slot.is_empty():
		return null
	var p: AudioStreamPlayer = slot["player"]
	p.stop()
	_start(slot, p, sound, pitch, volume_db)
	return p


## A looping sound (engine hum, tracks, thrusters) that rides `node` until stop(). Not pooled: one voice
## each. Change its pitch_scale / volume_db as the machine speeds up.
func attach(sound_name: String, node: Node3D, pitch := 1.0, volume_db := 0.0) -> AudioStreamPlayer3D:
	var sound: Dictionary = library.sounds.get(sound_name, {})
	if sound.is_empty() or node == null:
		return null
	var p := AudioStreamPlayer3D.new()
	p.name = "Sfx_" + sound_name
	p.bus = bus
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	_setup_3d(p, sound)
	p.stream = library.stream(sound_name)
	p.pitch_scale = maxf(pitch, 0.01)
	p.volume_db = float(sound["volume_db"]) + volume_db
	p.set_meta("sfx_base_db", p.volume_db)
	node.add_child(p)
	p.play(rng.randf() * SfxLibrary.duration(sound))        # start anywhere in the loop: two engines don't phase
	_loops.append(p)
	_count(sound_name)
	return p


## Stops a voice from play() or attach(): an attached loop fades out over FADE seconds and frees itself.
func stop(voice: Node) -> void:
	if voice == null or not is_instance_valid(voice):
		return
	if _loops.has(voice):
		_loops.erase(voice)
		if not voice.is_inside_tree():
			voice.queue_free()
			return
		var tween := voice.create_tween()
		tween.tween_property(voice, "volume_db", -60.0, FADE)
		tween.tween_callback(voice.queue_free)
	elif voice.has_method("stop"):
		voice.stop()


func stop_all() -> void:
	for loop in _loops.duplicate():
		stop(loop)
	for slot in _world + _ui:
		slot["player"].stop()


## Voices playing right now (world + interface; loops not counted).
func active() -> int:
	var n := 0
	for slot in _world + _ui:
		if slot["player"].playing:
			n += 1
	return n


## How many voices `sound_name` holds right now.
func playing_count(sound_name: String) -> int:
	var n := 0
	for slot in _world + _ui:
		if slot["name"] == sound_name and slot["player"].playing:
			n += 1
	return n


func _setup_3d(p: AudioStreamPlayer3D, sound: Dictionary) -> void:
	var reach := maxf(float(sound["distance"]), 1.0)
	p.max_distance = reach
	p.unit_size = reach * 0.12                     # full level up close, fading out toward `distance`
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE


func _start(slot: Dictionary, p: Node, sound: Dictionary, pitch: float, volume_db: float) -> void:
	var jitter := float(sound["pitch_jitter"])
	var vol_jitter := float(sound["volume_jitter"])
	p.stream = library.stream(sound["name"])
	p.pitch_scale = maxf(pitch * (1.0 + rng.randf_range(-jitter, jitter)), 0.01)
	p.volume_db = float(sound["volume_db"]) + volume_db + rng.randf_range(-vol_jitter, vol_jitter)
	p.play()
	_clock += 1
	slot["name"] = sound["name"]
	slot["started"] = _clock
	slot["priority"] = int(sound["priority"])
	_count(sound["name"])


func _count(sound_name: String) -> void:
	played += 1
	counts[sound_name] = int(counts.get(sound_name, 0)) + 1


## A free voice; else the oldest of this sound past its max_instances; else the oldest of the lowest priority
## (never one more important than this sound: then {} and the play is skipped).
func _pick(pool: Array, sound: Dictionary) -> Dictionary:
	var same := pool.filter(func(s): return s["name"] == sound["name"] and s["player"].playing)
	if same.size() >= int(sound["max_instances"]):
		return _oldest(same)
	for slot in pool:
		if not slot["player"].playing:
			return slot
	var lowest := 99
	for slot in pool:
		lowest = mini(lowest, slot["priority"])
	if lowest > int(sound["priority"]):
		skipped += 1
		return {}
	return _oldest(pool.filter(func(s): return s["priority"] == lowest))


static func _oldest(slots: Array) -> Dictionary:
	var best: Dictionary = slots[0]
	for slot in slots:
		if slot["started"] < best["started"]:
			best = slot
	return best
