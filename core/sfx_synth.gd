class_name SfxSynth
extends RefCounted
## Turns a sound preset (SfxLibrary format) into PCM: each voice is an oscillator with an envelope, pitch
## moves, filters and a little grit; the voices are summed into one mono buffer and wrapped in an
## AudioStreamWAV. Deterministic: the same preset always renders the same samples (noise is seeded from
## the sound's name), so the per-play variation comes from SfxPlayer's pitch / volume jitter instead.
##
##     var info := SfxSynth.render(sound)       # {"stream": AudioStreamWAV, "peak", "rms", "length", "samples"}
##
## Per voice, per sample: pitch (freq, slide in octaves / s, delta slide, vibrato in semitones, an arpeggio
## jump, repeat restarts) -> oscillator (square with duty, saw, sine, triangle, noise whose freq sets how
## fast it changes: low = rumble, high = hiss) -> envelope (attack, sustain with a punch, decay with a curve)
## -> resonant low-pass and high-pass filters (each can sweep in octaves / s) -> flanger -> drive (soft
## saturation). Square and saw are band-limited (PolyBLEP) so high notes don't alias into whistles.
## A loop renders `loop_length` seconds at full level and cross-fades its end into its start, so it repeats
## without a click.

const MIX_RATE := 44100
const NOISE_STEPS := 32.0              # noise values per oscillator period
const LOOP_FADE := 0.08                # seconds of cross-fade at a loop's seam
const COEF_EVERY := 16                 # samples between filter coefficient updates while a cutoff sweeps


static func voice_length(v: Dictionary) -> float:
	return float(v.get("delay", 0.0)) + float(v.get("attack", 0.0)) + float(v.get("sustain", 0.0)) \
		+ float(v.get("decay", 0.0))


## Renders a normalized sound (SfxLibrary.normalized). Returns {"stream", "peak", "rms", "length", "samples"};
## `peak` is measured before the safety clamp, so above 1.0 means the preset clips.
static func render(sound: Dictionary) -> Dictionary:
	var loop := bool(sound.get("loop", false))
	var length := SfxLibrary.duration(sound)
	var frames := maxi(int(ceil(length * MIX_RATE)), 1)
	var fade := mini(int(LOOP_FADE * MIX_RATE), frames / 2) if loop else 0
	var mix := PackedFloat32Array()
	mix.resize(frames + fade)
	mix.fill(0.0)
	var base_seed := hash(str(sound.get("name", "")))
	var voices: Array = sound.get("voices", [])
	for i in voices.size():
		var part := render_voice(voices[i], frames + fade, base_seed + i * 7919, loop)
		for j in part.size():
			mix[j] += part[j]
	if loop and fade > 0:                  # the tail fades into the head: sample frames-1 -> 0 is continuous
		for j in fade:
			var a := float(j) / fade
			mix[j] = mix[j] * a + mix[frames + j] * (1.0 - a)
		mix.resize(frames)
	var peak := 0.0
	var energy := 0.0
	for s in mix:
		peak = maxf(peak, absf(s))
		energy += s * s
	var rms := sqrt(energy / maxf(mix.size(), 1))
	return {"stream": to_stream(mix, loop), "peak": peak, "rms": rms, "length": float(mix.size()) / MIX_RATE,
		"samples": mix}


## 16-bit mono AudioStreamWAV from float samples (clamped to -1..1). A loop repeats the whole buffer.
static func to_stream(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = samples.size()
	return wav


## One voice, `frames` long (silence before its delay and after its envelope). See the class comment.
static func render_voice(v: Dictionary, frames: int, seed_value: int, loop := false) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(frames)
	out.fill(0.0)
	var sr := float(MIX_RATE)
	var dt := 1.0 / sr
	var wave := SfxLibrary.WAVES.find(str(v.get("wave", "square")))
	var volume := float(v["volume"])
	var start := 0 if loop else int(float(v["delay"]) * sr)
	var attack := maxf(float(v["attack"]), 0.0)
	var sustain := maxf(float(v["sustain"]), 0.0)
	var decay := maxf(float(v["decay"]), 0.0)
	var punch := float(v["punch"])
	var curve := maxf(float(v["curve"]), 0.1)
	var env_end := attack + sustain + decay
	var base_freq := clampf(float(v["freq"]), 1.0, sr * 0.45)
	var freq_min := clampf(float(v["freq_min"]), 1.0, sr * 0.45)
	var slide0 := float(v["slide"])
	var delta_slide := float(v["delta_slide"])
	var vib_depth := float(v["vibrato_depth"]) / 12.0           # semitones -> octaves
	var vib_speed := float(v["vibrato_speed"])
	var arp_mult := float(v["arp_mult"])
	var arp_time := float(v["arp_time"])
	var duty0 := float(v["duty"])
	var duty_sweep := float(v["duty_sweep"])
	var repeat := float(v["repeat"])
	var lpf := float(v["lpf"])
	var lpf_sweep := float(v["lpf_sweep"])
	var k := 2.0 - 2.0 * clampf(float(v["lpf_resonance"]), 0.0, 0.95)
	var hpf := float(v["hpf"])
	var hpf_sweep := float(v["hpf_sweep"])
	var flanger_ms := float(v["flanger_ms"])
	var flanger_sweep := float(v["flanger_sweep"])
	var drive := clampf(float(v["drive"]), 0.0, 1.0)
	var drive_gain := 1.0 + 6.0 * drive
	var drive_norm := 1.0 / tanh(drive_gain)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var phase := 0.0
	var noise_phase := 0.0
	var noise := rng.randf_range(-1.0, 1.0)
	var freq := base_freq
	var slide := slide0
	var arped := false
	var since := 0.0                       # time since the last repeat restart
	var lp_on := lpf > 0.0
	var cutoff := lpf
	var ic1 := 0.0
	var ic2 := 0.0
	var a1 := 0.0
	var a2 := 0.0
	var a3 := 0.0
	var hp_on := hpf > 0.0
	var hcut := hpf
	var hp_a := 0.0
	var hp_in := 0.0
	var hp_out := 0.0
	var fl_on := flanger_ms > 0.0
	var fl_buf := PackedFloat32Array()
	if fl_on:
		fl_buf.resize(4096)
		fl_buf.fill(0.0)
	var fl_pos := 0
	var slides := slide0 != 0.0 or delta_slide != 0.0
	for i in range(start, frames):
		var t := (i - start) * dt
		var env := 1.0
		if not loop:
			if t >= env_end:
				break
			if t < attack:
				env = t / attack
			elif t < attack + sustain:
				env = 1.0 + punch * (1.0 - (t - attack) / sustain)
			else:
				env = pow(1.0 - (t - attack - sustain) / maxf(decay, dt), curve)
		# pitch
		if repeat > 0.0:
			since += dt
			if since >= repeat:
				since -= repeat
				freq = base_freq
				slide = slide0
				arped = false
		else:
			since = t
		if arp_time > 0.0 and not arped and since >= arp_time:
			freq *= arp_mult
			arped = true
		if slides:
			slide += delta_slide * dt
			freq = clampf(freq * pow(2.0, slide * dt), freq_min, sr * 0.45)
		var f := freq
		if vib_depth > 0.0:
			f *= pow(2.0, vib_depth * sin(TAU * vib_speed * t))
		var inc := minf(f * dt, 0.5)
		phase += inc
		if phase >= 1.0:
			phase -= floorf(phase)
		# oscillator
		var s := 0.0
		if wave == 0:                      # square
			var d := clampf(duty0 + duty_sweep * t, 0.05, 0.95)
			s = 1.0 if phase < d else -1.0
			s += _blep(phase, inc) - _blep(fposmod(phase - d, 1.0), inc)
		elif wave == 1:                    # saw
			s = 2.0 * phase - 1.0 - _blep(phase, inc)
		elif wave == 2:                    # sine
			s = sin(TAU * phase)
		elif wave == 3:                    # triangle
			s = 1.0 - 4.0 * absf(phase - 0.5)
		else:                              # noise: a new random value NOISE_STEPS times per period
			noise_phase += f * dt * NOISE_STEPS
			if noise_phase >= 1.0:
				noise_phase -= floorf(noise_phase)
				noise = rng.randf_range(-1.0, 1.0)
			s = noise
		# filters (coefficients refreshed every COEF_EVERY samples while sweeping)
		if lp_on:
			if (i - start) % COEF_EVERY == 0:
				if lpf_sweep != 0.0 and i > start:
					cutoff = clampf(cutoff * pow(2.0, lpf_sweep * dt * COEF_EVERY), 20.0, sr * 0.45)
				var g := tan(PI * cutoff / sr)
				a1 = 1.0 / (1.0 + g * (g + k))
				a2 = g * a1
				a3 = g * a2
			var v3 := s - ic2
			var v1 := a1 * ic1 + a2 * v3
			var v2 := ic2 + a2 * ic1 + a3 * v3
			ic1 = 2.0 * v1 - ic1
			ic2 = 2.0 * v2 - ic2
			s = v2
		if hp_on:
			if (i - start) % COEF_EVERY == 0:
				if hpf_sweep != 0.0 and i > start:
					hcut = clampf(hcut * pow(2.0, hpf_sweep * dt * COEF_EVERY), 10.0, sr * 0.45)
				var rc := 1.0 / (TAU * hcut)
				hp_a = rc / (rc + dt)
			hp_out = hp_a * (hp_out + s - hp_in)
			hp_in = s
			s = hp_out
		if fl_on:
			fl_buf[fl_pos] = s
			var offset := clampi(int((flanger_ms + flanger_sweep * t) * 0.001 * sr), 1, 4095)
			s = (s + fl_buf[(fl_pos - offset) & 4095]) * 0.7
			fl_pos = (fl_pos + 1) & 4095
		if drive > 0.0:
			s = tanh(s * drive_gain) * drive_norm
		out[i] = s * env * volume
	return out


## PolyBLEP: smooths a waveform's jump so it doesn't alias. `t` = phase (0..1) at the jump, `dt` = phase step.
static func _blep(t: float, dt: float) -> float:
	if t < dt:
		t /= dt
		return t + t - t * t - 1.0
	if t > 1.0 - dt:
		t = (t - 1.0) / dt
		return t * t + t + t + 1.0
	return 0.0
