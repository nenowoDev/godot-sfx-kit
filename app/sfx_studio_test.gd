class_name SfxStudioTest
extends RefCounted
## SFX Studio self-test (run the studio scene with `-- --test`; headless is fine: it checks the rendered
## samples, not the speakers). Prints "SFXTEST ... problems: N". Every preset renders without clipping and
## isn't silent, bursts end quietly (no click), loops are seamless, renders repeat exactly, every ammo type
## has a fire sound and every ammo kind an impact, the voice pool keeps its limits (voices, max at once,
## priority), plays jitter, a loop rides its node and fades out, a recorded sample replaces the voices, and a
## Studio edit saves and loads back. Writes and deletes <sfx_kit/sounds_dir>/sfxtest.json and
## user://sfxtest_sample.wav.

const NEEDED := ["explosion", "zap", "servo", "step_heavy", "step_light", "tracks_loop", "engine_loop",
	"thruster_loop", "jump", "land", "reload", "ready", "dash", "ui_click", "ui_hover", "part_snap", "part_break"]
const STATS := "res://machine_parts/stats.json"


static func run(studio: SfxStudio) -> void:
	var problems := []
	var lib := studio.library
	lib.wait()
	if lib.sounds.size() < 20:
		problems.append("only %d presets" % lib.sounds.size())
	for n in NEEDED:
		if not lib.has(n):
			problems.append("missing preset %s" % n)
	# every preset: renders, no clipping, not silent, ends quietly, loops loop seamlessly
	var started := Time.get_ticks_msec()
	var audio_seconds := 0.0
	var loops := 0
	for n in lib.names():
		var sound: Dictionary = lib.sounds[n]
		var info := SfxSynth.render(sound)
		var samples: PackedFloat32Array = info["samples"]
		audio_seconds += info["length"]
		if is_nan(info["peak"]) or is_nan(info["rms"]):
			problems.append("%s: NaN samples" % n)
			continue
		if info["peak"] > 1.0:
			problems.append("%s: clips (peak %.2f): lower its voice volumes, raise volume_db" % [n, info["peak"]])
		if info["peak"] < 0.05 or info["rms"] < 0.005:
			problems.append("%s: nearly silent (peak %.3f, rms %.4f)" % [n, info["peak"], info["rms"]])
		if info["length"] < 0.03 or info["length"] > 4.0:
			problems.append("%s: %.2f s long" % [n, info["length"]])
		var wav := info["stream"] as AudioStreamWAV
		if sound["loop"]:
			loops += 1
			if wav.loop_mode != AudioStreamWAV.LOOP_FORWARD or wav.loop_end != samples.size():
				problems.append("%s: doesn't loop (mode %d, end %d of %d)" % [n, wav.loop_mode, wav.loop_end, samples.size()])
			var biggest := 0.0
			for i in range(1, samples.size()):
				biggest = maxf(biggest, absf(samples[i] - samples[i - 1]))
			var seam := absf(samples[0] - samples[samples.size() - 1])
			if seam > biggest + 0.01:
				problems.append("%s: clicks at the loop seam (jump %.3f, biggest step inside %.3f)" % [n, seam, biggest])
		else:
			if wav.loop_mode != AudioStreamWAV.LOOP_DISABLED:
				problems.append("%s: a burst that loops" % n)
			var tail := 0.0
			for i in range(maxi(samples.size() - 220, 0), samples.size()):          # the last 5 ms
				tail = maxf(tail, absf(samples[i]))
			if tail > 0.05:
				problems.append("%s: ends with a click (last 5 ms reach %.3f)" % [n, tail])
	var render_ms := Time.get_ticks_msec() - started
	# same preset, same samples (variation comes from the player's jitter, not the render)
	var a: PackedFloat32Array = SfxSynth.render(lib.sounds["impact_kinetic"])["samples"]
	var b: PackedFloat32Array = SfxSynth.render(lib.sounds["impact_kinetic"])["samples"]
	if a != b:
		problems.append("renders differ between runs")
	# the Machine Parts pack's ammo: a fire sound per type, an impact per kind
	var kinds := {}
	var types := 0
	if FileAccess.file_exists(STATS):
		var stats = JSON.parse_string(FileAccess.get_file_as_string(STATS))
		var ammo: Dictionary = stats.get("ammo", {}) if stats is Dictionary else {}
		types = ammo.size()
		for type in ammo:
			kinds[str(ammo[type].get("kind", ""))] = true
			if not lib.has("fire_" + str(type).to_lower()):
				problems.append("ammo %s has no fire_%s" % [type, str(type).to_lower()])
		for kind in kinds:
			if not lib.has("impact_" + kind):
				problems.append("ammo kind %s has no impact_%s" % [kind, kind])
	# the cache: after a background warm every sound is ready (no render on first play)
	lib.warm([], true)
	lib.wait()
	var cached_from := Time.get_ticks_msec()
	for n in lib.names():
		lib.stream(n)
	if Time.get_ticks_msec() - cached_from > 50:
		problems.append("cached streams took %d ms to fetch (re-rendering?)" % (Time.get_ticks_msec() - cached_from))
	await _check_pool(studio, lib, problems)
	_check_sample(lib, problems)
	_check_studio(studio, problems)
	print("SFXTEST %d presets (%d loops) rendered: %.1f s of audio in %d ms; ammo %d types / %d kinds covered; pool, jitter, loops, sample, edit saved"
		% [lib.sounds.size(), loops, audio_seconds, render_ms, types, kinds.size()])
	for p in problems:
		print("SFXTEST problem: ", p)
	print("SFXTEST problems: %d" % problems.size())
	for i in 5:
		await studio.get_tree().process_frame
	studio.get_tree().quit()


## Voice limit, max at once, priority, jitter, interface voices, attached loops.
static func _check_pool(studio: SfxStudio, lib: SfxLibrary, problems: Array) -> void:
	var player := SfxPlayer.create(lib, 4)
	player.rng.seed = 7
	studio.add_child(player)
	for i in 8:
		player.play("fire_round", Vector3(i, 0, 0))
	if player.playing_count("fire_round") != 4:
		problems.append("pool: 8 rounds on 4 voices hold %d" % player.playing_count("fire_round"))
	player.stop_all()
	for i in 3:
		player.play("ready", Vector3.ZERO)
	if player.playing_count("ready") != int(lib.sounds["ready"]["max_instances"]):
		problems.append("pool: ready holds %d voices (max %d)" % [player.playing_count("ready"), lib.sounds["ready"]["max_instances"]])
	player.stop_all()
	for i in 4:
		player.play("impact_explosive", Vector3(0, 0, i))
	var hover = player.play("ui_hover", Vector3.ZERO)
	var boom = player.play("explosion", Vector3.ZERO)
	if hover != null or player.skipped != 1:
		problems.append("pool: a hover stole a voice from an explosion")
	if boom == null or player.playing_count("impact_explosive") != 3:
		problems.append("pool: an explosion didn't take the oldest equal-priority voice")
	if player.play("no_such_sound", Vector3.ZERO) != null:
		problems.append("pool: an unknown sound played")
	player.stop_all()
	var p1: AudioStreamPlayer3D = player.play("step_heavy", Vector3.ZERO, 0.8)
	var pitch1 := p1.pitch_scale
	var p2: AudioStreamPlayer3D = player.play("step_heavy", Vector3.ZERO, 0.8)
	if is_equal_approx(pitch1, p2.pitch_scale) or absf(pitch1 - 0.8) > 0.8 * 0.071:
		problems.append("jitter: two steps at %.3f and %.3f (want different, within 7 %% of 0.8)" % [pitch1, p2.pitch_scale])
	var ui := player.play_ui("ui_click")
	if ui == null or not ui.playing or not ui is AudioStreamPlayer:
		problems.append("interface voice didn't play")
	var holder := Node3D.new()
	studio.add_child(holder)
	var hum := player.attach("engine_loop", holder, 1.2)
	holder.position = Vector3(5, 2, 0)
	if hum == null or hum.global_position.distance_to(Vector3(5, 2, 0)) > 0.001 or not hum.playing \
			or (hum.stream as AudioStreamWAV).loop_mode != AudioStreamWAV.LOOP_FORWARD:
		problems.append("attached loop didn't ride its node or doesn't loop")
	player.stop(hum)
	var waited := 0.0
	while waited < SfxPlayer.FADE + 0.25:
		await studio.get_tree().process_frame
		waited += studio.get_process_delta_time()
	if is_instance_valid(hum):
		problems.append("stopped loop still alive after its fade")
	holder.queue_free()
	player.queue_free()


## A preset that names a recorded file plays the file; a missing file falls back to the voices.
static func _check_sample(lib: SfxLibrary, problems: Array) -> void:
	var path := "user://sfxtest_sample.wav"
	var source: AudioStreamWAV = lib.stream("ready")
	source.save_to_wav(path)
	var sound := SfxLibrary.normalized({"name": "sfxtest_sample", "sample": path, "voices": lib.sounds["zap"]["voices"]})
	var info := SfxLibrary.render(sound)
	if not info.has("sample") or absf(float(info["length"]) - source.get_length()) > 0.02:
		problems.append("sample: %s didn't replace the voices (length %.2f, want %.2f)" % [path, info.get("length", 0.0),
			source.get_length()])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	sound["sample"] = "user://sfxtest_missing.wav"
	if not SfxLibrary.render(sound).has("samples"):
		problems.append("sample: a missing file didn't fall back to the voices")


## Studio: an edit round-trips through a saved file; Mutate stays in range; Randomise makes a playable sound.
static func _check_studio(studio: SfxStudio, problems: Array) -> void:
	studio.select("fire_laser")
	studio.rows["0/freq"].call(900.0)
	studio.rows["sound/priority"].call(3)
	studio.rows["1/wave"].call(SfxLibrary.WAVES.find("triangle"))
	studio.name_edit.text = "sfxtest"
	studio.save()
	var path := "%s/sfxtest.json" % SfxLibrary.project_dir()
	var reloaded := SfxLibrary.load_default()
	var saved: Dictionary = reloaded.sounds.get("sfxtest", {})
	if saved.is_empty() or float(saved["voices"][0]["freq"]) != 900.0 or saved["priority"] != 3 \
			or saved["voices"][1]["wave"] != "triangle":
		problems.append("save -> load lost the edit")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	SfxLibrary.clear_cache()
	studio.library = SfxLibrary.load_default()
	studio.select("servo")
	var before := JSON.stringify(studio.sound)
	studio.rng.seed = 3
	studio.mutate()
	if JSON.stringify(studio.sound) == before:
		problems.append("mutate changed nothing")
	for v in studio.sound["voices"]:
		for key in SfxLibrary.RANGES:
			if v.has(key) and (float(v[key]) < SfxLibrary.RANGES[key][0] or float(v[key]) > SfxLibrary.RANGES[key][1]):
				problems.append("mutate: %s = %s out of range" % [key, v[key]])
	var silent := 0
	for i in 6:
		studio.randomise()
		if studio.sound["voices"].is_empty() or studio.sound["voices"].size() > 3 or is_nan(studio.info["peak"]):
			problems.append("randomise: %d voices, peak %s" % [studio.sound["voices"].size(), studio.info["peak"]])
		elif studio.info["peak"] < 0.01:
			silent += 1
	if silent > 1:
		problems.append("randomise: %d of 6 sounds silent" % silent)
	studio.audio.stop()
