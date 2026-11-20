class_name SfxStudio
extends Control
## SFX Studio: tweak a sound preset and hear it. Pick a sound on the left; every slider on the right
## changes it, and with Auto-play on it plays again a moment after you let go. The middle shows the
## rendered wave (red = it would clip). Randomise makes a new sound, Mutate nudges this one. Save writes
## it to the project's sounds folder (project setting sfx_kit/sounds_dir, default res://sfx), which
## overrides the built-in preset of the same name.
##
## Command line (after --): --sound=<name> --shot=<png> --test

const LEFT_W := 240
const RIGHT_W := 420
const TOP_H := 48
const STATUS_H := 30
const AUTO_DELAY := 0.3                # seconds after the last change before Auto-play plays it
const LABELS := {"wave": "Wave", "volume": "Volume", "delay": "Delay s",
	"attack": "Attack s", "sustain": "Sustain s", "punch": "Punch", "decay": "Decay s", "curve": "Decay curve",
	"freq": "Pitch Hz", "freq_min": "Lowest Hz", "slide": "Slide oct/s", "delta_slide": "Slide change",
	"vibrato_depth": "Vibrato st", "vibrato_speed": "Vibrato Hz", "arp_mult": "Jump x", "arp_time": "Jump at s",
	"repeat": "Repeat s", "duty": "Duty", "duty_sweep": "Duty sweep", "drive": "Drive",
	"lpf": "Low-pass Hz", "lpf_sweep": "LP sweep", "lpf_resonance": "LP reso", "hpf": "High-pass Hz",
	"hpf_sweep": "HP sweep", "flanger_ms": "Flanger ms", "flanger_sweep": "Flanger sweep",
	"loop_length": "Loop s", "volume_db": "Volume dB", "pitch_jitter": "Pitch jitter",
	"volume_jitter": "Vol jitter dB", "distance": "Heard to m", "priority": "Priority", "max_instances": "Max at once"}
## Voice keys grouped under captions, in the order they show.
const GROUPS := [["LEVEL", ["volume", "delay", "attack", "sustain", "punch", "decay", "curve"]],
	["PITCH", ["freq", "freq_min", "slide", "delta_slide", "vibrato_depth", "vibrato_speed", "arp_mult", "arp_time",
		"repeat"]],
	["TONE", ["duty", "duty_sweep", "drive", "lpf", "lpf_sweep", "lpf_resonance", "hpf", "hpf_sweep", "flanger_ms",
		"flanger_sweep"]]]
const SOUND_KEYS := ["volume_db", "pitch_jitter", "volume_jitter", "distance", "priority", "max_instances"]

var library: SfxLibrary
var sound := {}                        # the sound being edited (a copy; Save writes it)
var info := {}                         # its latest render (SfxSynth.render)
var audio: AudioStreamPlayer
var sound_list: ItemList
var props: VBoxContainer
var wave_view: SfxWaveView
var info_label: Label
var status_label: Label
var name_edit: LineEdit
var auto_box: CheckBox
var play_button: Button
var keys_panel: MachineKeymapPanel     # Ctrl+/ shortcut list (rebindable keys, the Machine Assembler's MachineKeymap)
var rows := {}                         # "sound/key" or "<voice index>/key" -> setter Callable (the self-test uses them)
var rng := RandomNumberGenerator.new()
var _changed_at := -1.0                # seconds (engine time) of the last edit not yet played
var _clock := 0.0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	library = SfxLibrary.load_default()
	library.warm([], true)
	MachineKeymap.define_common()
	MachineKeymap.define("sfx_play", "Play the sound", "SFX Studio", [MachineKeymap.key(KEY_SPACE)])
	MachineKeymap.define("sfx_mutate", "Mutate (nudge every setting)", "SFX Studio", [MachineKeymap.key(KEY_M)])
	MachineKeymap.define("sfx_randomise", "Randomise (a new sound)", "SFX Studio", [MachineKeymap.key(KEY_R)])
	audio = AudioStreamPlayer.new()
	add_child(audio)
	_build_ui()
	_refresh_list()
	var args := _user_args()
	var first: String = args.get("sound", library.names()[0] if not library.sounds.is_empty() else "")
	if first != "":
		select(first)
	if args.has("test"):
		await SfxStudioTest.run(self)
	if args.has("shot"):
		await _screenshot(args["shot"])


func _exit_tree() -> void:
	library.wait()


# --- sound ----------------------------------------------------------------------------------------
func select(sound_name: String) -> void:
	if not library.has(sound_name):
		return
	sound = library.sounds[sound_name].duplicate(true)
	name_edit.text = sound["name"]
	for i in sound_list.item_count:
		if sound_list.get_item_text(i) == sound_name:
			sound_list.select(i)
	_build_props()
	_render()
	play()


## Plays the edited sound now (a loop: starts or stops it).
func play() -> void:
	if info.is_empty():
		_render()
	if sound["loop"] and audio.playing:
		audio.stop()
		return
	audio.stream = info["stream"]
	audio.volume_db = float(sound["volume_db"])
	audio.play()


func save() -> void:
	var sound_name := name_edit.text.strip_edges().replace(" ", "_")
	if sound_name == "":
		_status("Name the sound first.")
		return
	sound["name"] = sound_name
	var err := SfxLibrary.save(sound)
	SfxLibrary.clear_cache()
	library = SfxLibrary.load_default()
	_refresh_list()
	_status("Saved %s/%s.json." % [SfxLibrary.project_dir(), sound_name] if err == OK else "Could not save (%s)." % error_string(err))


## A new random sound (1-3 voices) in sane ranges; keeps the name field so Save doesn't overwrite by accident.
func randomise() -> void:
	var voices := []
	for i in rng.randi_range(1, 3):
		voices.append(random_voice(rng, i))
	sound = SfxLibrary.normalized({"name": "random", "voices": voices, "distance": 50.0})
	name_edit.text = "random"
	_build_props()
	_changed(true)
	_status("A new random sound: Mutate to vary it, Save to keep it.")


## Every setting of every voice nudged by up to 15 % (settings at 0 stay off).
func mutate() -> void:
	for v in sound["voices"]:
		for key in SfxLibrary.RANGES:
			if not v.has(key) or float(v[key]) == 0.0:
				continue
			var r: Array = SfxLibrary.RANGES[key]
			v[key] = clampf(float(v[key]) * (1.0 + rng.randf_range(-0.15, 0.15)), r[0], r[1])
	_build_props()
	_changed(true)


static func random_voice(r: RandomNumberGenerator, index: int) -> Dictionary:
	var v := {"wave": SfxLibrary.WAVES[r.randi() % SfxLibrary.WAVES.size()],
		"volume": r.randf_range(0.15, 0.35), "freq": exp(r.randf_range(log(60.0), log(3000.0))),
		"attack": r.randf_range(0.0, 0.05) if r.randf() < 0.3 else 0.0, "sustain": r.randf_range(0.0, 0.2),
		"punch": r.randf_range(0.0, 0.8), "decay": r.randf_range(0.05, 0.6), "duty": r.randf_range(0.2, 0.8),
		"delay": r.randf_range(0.0, 0.08) if index > 0 and r.randf() < 0.3 else 0.0}
	if r.randf() < 0.5:
		v["slide"] = r.randf_range(-6.0, 6.0)
	if r.randf() < 0.3:
		v["vibrato_depth"] = r.randf_range(0.2, 6.0)
		v["vibrato_speed"] = r.randf_range(3.0, 40.0)
	if r.randf() < 0.25:
		v["arp_mult"] = r.randf_range(0.5, 2.0)
		v["arp_time"] = r.randf_range(0.02, 0.15)
	if r.randf() < 0.5:
		v["lpf"] = exp(r.randf_range(log(400.0), log(8000.0)))
		v["lpf_resonance"] = r.randf_range(0.0, 0.6)
	if r.randf() < 0.3:
		v["hpf"] = exp(r.randf_range(log(100.0), log(2000.0)))
	if r.randf() < 0.2:
		v["drive"] = r.randf_range(0.1, 0.7)
	if r.randf() < 0.15:
		v["repeat"] = r.randf_range(0.03, 0.2)
	return SfxLibrary.normalized_voice(v)


func _render() -> void:
	info = SfxLibrary.render(sound)
	var samples: PackedFloat32Array = info.get("samples", PackedFloat32Array())
	wave_view.show_samples(samples, info["length"], sound["loop"])
	if info.has("samples"):
		info_label.text = "%.2f s   peak %.2f%s   loudness (rms) %.3f   %d voices" % [info["length"], info["peak"],
			"  CLIPS: lower the volumes" if info["peak"] > 1.0 else "", info["rms"], sound["voices"].size()]
	else:
		info_label.text = "%.2f s   recorded sample %s" % [info["length"], sound["sample"]]


## An edit: re-render now (the picture follows at once) and play after AUTO_DELAY (or at once with `now`).
func _changed(now := false) -> void:
	_render()
	_changed_at = -1.0 if now else _clock
	if now and auto_box.button_pressed:
		audio.stop()
		play()


func _process(delta: float) -> void:
	_clock += delta
	if _changed_at >= 0.0 and _clock - _changed_at >= AUTO_DELAY:
		_changed_at = -1.0
		if auto_box.button_pressed:
			audio.stop()
			play()
	wave_view.set_playhead(audio.get_playback_position() if audio.playing else -1.0)


## Shortcuts (rebindable, Ctrl+/ lists them) run before the interface sees the key; not while typing.
func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.is_pressed() or event.is_echo() or keys_panel == null or keys_panel.is_open():
		return
	if MachineKeymap.matches(event, "keys_panel"):
		keys_panel.toggle()
		get_viewport().set_input_as_handled()
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit or focused is SpinBox:
		return
	for id in ["sfx_play", "sfx_mutate", "sfx_randomise"]:
		if MachineKeymap.matches(event, id):
			{"sfx_play": play, "sfx_mutate": mutate, "sfx_randomise": randomise}[id].call()
			get_viewport().set_input_as_handled()
			return


func _refresh_key_labels() -> void:
	if play_button != null:
		play_button.text = "Play   " + MachineKeymap.text("sfx_play")


# --- ui -------------------------------------------------------------------------------------------
func _build_ui() -> void:
	var root := Control.new()
	root.theme = MachineUITheme.build()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	var bg := ColorRect.new()
	bg.color = MachineUITheme.APP_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	var top := _dock(root, "TopBar", Rect2(0, 0, 0, TOP_H), Vector4(0, 0, 1, 0))
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	var mark := ColorRect.new()
	mark.color = MachineUITheme.ACCENT
	mark.custom_minimum_size = Vector2(4, 18)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(mark)
	bar.add_child(_label("MACHINE PARTS", "Brand"))
	bar.add_child(_label("SFX Studio", "Muted"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	play_button = _button("Play", play)
	bar.add_child(play_button)
	auto_box = CheckBox.new()
	auto_box.text = "Auto-play"
	auto_box.button_pressed = true
	auto_box.focus_mode = Control.FOCUS_NONE
	auto_box.tooltip_text = "Play the sound again a moment after every change."
	bar.add_child(auto_box)
	bar.add_child(_button("Randomise   " + MachineKeymap.text("sfx_randomise"), randomise))
	bar.add_child(_button("Mutate   " + MachineKeymap.text("sfx_mutate"), mutate))
	name_edit = LineEdit.new()
	name_edit.custom_minimum_size = Vector2(180, 0)
	bar.add_child(name_edit)
	var save_button := _button("Save", save)
	save_button.theme_type_variation = "Primary"
	bar.add_child(save_button)
	top.add_child(bar)
	var left := _dock(root, "DockLeft", Rect2(0, TOP_H, LEFT_W, -STATUS_H), Vector4(0, 0, 0, 1))
	var lbox := VBoxContainer.new()
	lbox.add_child(_label("SOUNDS", "Caption"))
	sound_list = ItemList.new()
	sound_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sound_list.item_selected.connect(func(i): select.call_deferred(sound_list.get_item_text(i)))
	lbox.add_child(sound_list)
	left.add_child(lbox)
	var right := _dock(root, "DockRight", Rect2(-RIGHT_W, TOP_H, 0, -STATUS_H), Vector4(1, 0, 1, 1))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	props = VBoxContainer.new()
	props.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	props.add_theme_constant_override("separation", 3)
	scroll.add_child(props)
	right.add_child(scroll)
	var middle := VBoxContainer.new()
	middle.anchor_right = 1.0
	middle.anchor_bottom = 1.0
	middle.offset_left = LEFT_W + 16
	middle.offset_right = -RIGHT_W - 16
	middle.offset_top = TOP_H + 16
	middle.offset_bottom = -STATUS_H - 16
	root.add_child(middle)
	middle.add_child(_label("WAVE", "Caption"))
	wave_view = SfxWaveView.new()
	wave_view.custom_minimum_size = Vector2(0, 260)
	wave_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_child(wave_view)
	info_label = _label("", "Muted")
	middle.add_child(info_label)
	middle.add_child(_label("Sharp front = the transient (\"hit\"), fat middle = the body (weight), thin end = the "
		+ "tail (space). Heavier sounds: lower and longer.", "Muted"))
	middle.get_child(middle.get_child_count() - 1).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var status := _dock(root, "StatusBar", Rect2(0, -STATUS_H, 0, 0), Vector4(0, 1, 1, 1))
	var status_row := HBoxContainer.new()
	status_label = _label("", "Muted")
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(status_label)
	var keys := _button("Shortcuts   " + MachineKeymap.text("keys_panel"), func(): keys_panel.toggle())
	keys.theme_type_variation = "Flat"
	status_row.add_child(keys)
	status.add_child(status_row)
	keys_panel = MachineKeymapPanel.create("SFX Studio")
	root.add_child(keys_panel)
	MachineKeymap.events_hub().changed.connect(_refresh_key_labels)
	_refresh_key_labels.call_deferred()


func _refresh_list() -> void:
	sound_list.clear()
	for n in library.names():
		sound_list.add_item(n)


## One row per setting: the sound's own, then each voice (wave, then level, pitch and tone sliders).
func _build_props() -> void:
	for c in props.get_children():
		c.queue_free()
	rows.clear()
	props.add_child(_label("SOUND", "Caption"))
	var loop := CheckBox.new()
	loop.text = "Loop (engine, tracks: plays until stopped)"
	loop.button_pressed = sound["loop"]
	loop.toggled.connect(func(on):
		sound["loop"] = on
		audio.stop()
		_build_props.call_deferred()
		_changed())
	props.add_child(loop)
	if sound["loop"]:
		_slider_row("sound", "loop_length", sound)
	for key in SOUND_KEYS:
		_slider_row("sound", key, sound)
	var sample_row := _row("Sample file")
	var sample := LineEdit.new()
	sample.placeholder_text = "res://... .wav / .ogg (plays instead of the voices)"
	sample.text = sound["sample"]
	sample.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sample.text_submitted.connect(func(t):
		sound["sample"] = t.strip_edges()
		_changed())
	sample_row.add_child(sample)
	for i in sound["voices"].size():
		var v: Dictionary = sound["voices"][i]
		var head := HBoxContainer.new()
		head.add_child(_label("VOICE %d" % (i + 1), "Caption"))
		var sp := Control.new()
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(sp)
		head.add_child(_button("Remove", func():
			sound["voices"].remove_at(i)
			_build_props.call_deferred()
			_changed()))
		props.add_child(head)
		_wave_row(str(i), v)
		for group in GROUPS:
			props.add_child(_label(group[0], "Muted"))
			for key in group[1]:
				_slider_row(str(i), key, v)
	props.add_child(_button("Add voice", func():
		sound["voices"].append(SfxLibrary.normalized_voice({}))
		_build_props.call_deferred()
		_changed()))


func _row(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := _label(text, "Muted")
	label.custom_minimum_size = Vector2(96, 0)
	row.add_child(label)
	props.add_child(row)
	return row


## A slider and an exact number box, linked; both edit data[key].
func _slider_row(group: String, key: String, data: Dictionary) -> void:
	var r: Array = SfxLibrary.RANGES[key]
	var row := _row(LABELS.get(key, key))
	var slider := HSlider.new()
	slider.min_value = r[0]
	slider.max_value = r[1]
	slider.step = r[2]
	slider.exp_edit = r[3]
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.focus_mode = Control.FOCUS_NONE
	var spin := SpinBox.new()
	spin.min_value = r[0]
	spin.max_value = r[1]
	spin.step = r[2]
	spin.allow_greater = true
	spin.allow_lesser = true
	spin.custom_minimum_size = Vector2(92, 0)
	var integer := key in ["priority", "max_instances"]
	var setter := func(value):
		data[key] = int(value) if integer else float(value)
		slider.set_value_no_signal(float(value))
		spin.set_value_no_signal(float(value))
		_changed()
	slider.set_value_no_signal(float(data[key]))
	spin.set_value_no_signal(float(data[key]))
	slider.value_changed.connect(setter)
	spin.value_changed.connect(setter)
	rows["%s/%s" % [group, key]] = setter
	row.add_child(slider)
	row.add_child(spin)


func _wave_row(group: String, data: Dictionary) -> void:
	var row := _row("Wave")
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.focus_mode = Control.FOCUS_NONE
	for w in SfxLibrary.WAVES:
		option.add_item(w)
	option.select(maxi(SfxLibrary.WAVES.find(data["wave"]), 0))
	var setter := func(i):
		data["wave"] = SfxLibrary.WAVES[i]
		_changed()
	option.item_selected.connect(setter)
	rows["%s/wave" % group] = setter
	row.add_child(option)


func _dock(root: Control, variation: String, rect: Rect2, anchors: Vector4) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = variation
	panel.anchor_left = anchors.x
	panel.anchor_top = anchors.y
	panel.anchor_right = anchors.z
	panel.anchor_bottom = anchors.w
	panel.offset_left = rect.position.x
	panel.offset_top = rect.position.y
	panel.offset_right = rect.size.x
	panel.offset_bottom = rect.size.y
	root.add_child(panel)
	return panel


func _label(text: String, variation := "") -> Label:
	var l := Label.new()
	l.text = text
	if variation != "":
		l.theme_type_variation = variation
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _button(text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.pressed.connect(action)
	return b


func _status(text: String) -> void:
	if status_label != null:
		status_label.text = text


func _user_args() -> Dictionary:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else ""
	return args


func _screenshot(path: String) -> void:
	for i in 20:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
