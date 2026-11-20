class_name SfxWaveView
extends Control
## SFX Studio's picture of a sound: the rendered samples as a min / max band, lines where it would clip,
## and a playhead while it plays. Seeing the shape helps: a sharp front edge is the transient, the fat
## middle the body, the thin end the tail (PRESENTATION 6).

const BINS := 1024

var length := 0.0                      # seconds
var loop := false
var playhead := -1.0                   # seconds, -1 = not playing
var color := Color("#f0a03c")
var line := Color("#3c434e")
var clip := Color("#ff5d52")
var _lo := PackedFloat32Array()        # per bin: lowest and highest sample
var _hi := PackedFloat32Array()


func show_samples(data: PackedFloat32Array, seconds: float, is_loop: bool) -> void:
	length = seconds
	loop = is_loop
	_lo.resize(BINS)
	_hi.resize(BINS)
	_lo.fill(0.0)
	_hi.fill(0.0)
	if not data.is_empty():
		var per := float(data.size()) / BINS
		for i in data.size():
			var b := mini(int(i / per), BINS - 1)
			_lo[b] = minf(_lo[b], data[i])
			_hi[b] = maxf(_hi[b], data[i])
	queue_redraw()


func set_playhead(seconds: float) -> void:
	if seconds != playhead:
		playhead = seconds
		queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	var mid := h * 0.5
	var half := h * 0.45
	draw_rect(Rect2(Vector2.ZERO, size), Color("#0f1114"))
	draw_line(Vector2(0, mid), Vector2(w, mid), line)
	draw_line(Vector2(0, mid - half), Vector2(w, mid - half), Color(clip, 0.35))
	draw_line(Vector2(0, mid + half), Vector2(w, mid + half), Color(clip, 0.35))
	if _lo.is_empty() or w < 2:
		return
	for x in int(w):
		var a := int(x * BINS / w)
		var b := maxi(int((x + 1) * BINS / w), a + 1)
		var lo := 0.0
		var hi := 0.0
		for i in range(a, mini(b, BINS)):
			lo = minf(lo, _lo[i])
			hi = maxf(hi, _hi[i])
		var c := clip if hi > 1.0 or lo < -1.0 else color
		draw_line(Vector2(x, mid - clampf(hi, -1.1, 1.1) * half), Vector2(x, mid - clampf(lo, -1.1, 1.1) * half + 1.0), c)
	if playhead >= 0.0 and length > 0.0:
		var px := fposmod(playhead, length) / length * w if loop else minf(playhead / length, 1.0) * w
		draw_line(Vector2(px, 0), Vector2(px, h), Color.WHITE, 1.0)
