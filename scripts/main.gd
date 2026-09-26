extends Node2D
## Arena, lobby, round flow and HUD. Players join by scanning the QR code; the first
## phone becomes Player 1, the second Player 2. The keyboard also works for both.

const ARENA := Rect2(40, 90, 1200, 590)
const WALL_THICKNESS := 40.0
const PILLARS: Array[Rect2] = [
	Rect2(610, 190, 60, 110),
	Rect2(610, 470, 60, 110),
	Rect2(330, 355, 80, 60),
	Rect2(870, 355, 80, 60),
]
const SPAWNS := [Vector2(200, 385), Vector2(1080, 385)]
const COLOR_NAMES := ["blue", "pink"]

@onready var fighters: Array[Fighter] = [$Player1, $Player2]

var scores := [0, 0]
var in_lobby := true
var round_over := false

var _bars: Array[ProgressBar] = []
var _name_labels: Array[Label] = []
var _score_labels: Array[Label] = []
var _message: Label
var _lobby: Control
var _slot_labels: Array[Label] = []
var _qr_rect: TextureRect
var _url_label: Label
var _how_label: Label


func _ready() -> void:
	_build_walls()
	_build_hud()
	_build_lobby()
	for f in fighters:
		f.health_changed.connect(_on_health_changed)
		f.hurt.connect(_on_fighter_hurt)
		f.died.connect(_on_fighter_died)

	PhoneControllers.max_players = 2
	PhoneControllers.player_joined.connect(_on_phone_joined)
	PhoneControllers.player_left.connect(_on_phone_left)
	PhoneControllers.player_disconnected.connect(func(_id: int) -> void: _refresh_names())
	PhoneControllers.player_reconnected.connect(func(_id: int) -> void: _refresh_names())
	PhoneControllers.button_pressed.connect(_on_phone_button)
	PhoneControllers.status_changed.connect(func(_ok: bool, _msg: String) -> void: _update_join_info())
	_update_join_info()
	_show_lobby()


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("restart"):
		_on_start_pressed()


func _unhandled_input(event: InputEvent) -> void:
	# Tab brings the QR code back up so someone can (re)join.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		_show_lobby()


# --- Flow -------------------------------------------------------------------

func _show_lobby() -> void:
	in_lobby = true
	_lobby.visible = true
	_message.visible = false
	for f in fighters:
		f.set_physics_process(false)
	_refresh_names()


func _start_match() -> void:
	in_lobby = false
	_lobby.visible = false
	for f in fighters:
		f.set_physics_process(true)
		if f.phone_id > 0:
			PhoneControllers.send_text(f.phone_id, "FIGHT!", 1200)
	_start_round()


func _start_round() -> void:
	round_over = false
	_message.visible = false
	fighters[0].reset(SPAWNS[0], Vector2.RIGHT)
	fighters[1].reset(SPAWNS[1], Vector2.LEFT)
	for b in get_tree().get_nodes_in_group("bullets"):
		b.queue_free()


## Enter/Space on the keyboard, or NEXT ROUND on a phone.
func _on_start_pressed() -> void:
	if in_lobby:
		_start_match()
	elif round_over:
		_start_round()


func _on_health_changed(f: Fighter) -> void:
	_bars[f.player_number - 1].value = f.health


func _on_fighter_hurt(f: Fighter, damage: float) -> void:
	if f.phone_id > 0:
		PhoneControllers.vibrate(f.phone_id, 90 if damage >= 5.0 else 30)


func _on_fighter_died(loser: Fighter) -> void:
	if round_over:
		return
	round_over = true
	var winner := fighters[1] if loser == fighters[0] else fighters[0]
	scores[winner.player_number - 1] += 1
	_score_labels[winner.player_number - 1].text = "Wins: %d" % scores[winner.player_number - 1]
	_message.text = "Player %d wins!\nPress NEXT ROUND on a phone, or Enter" % winner.player_number
	_message.add_theme_color_override("font_color", winner.color)
	_message.visible = true
	if winner.phone_id > 0:
		PhoneControllers.send_text(winner.phone_id, "You win the round!")
		PhoneControllers.vibrate(winner.phone_id, [60, 60, 60])
	if loser.phone_id > 0:
		PhoneControllers.send_text(loser.phone_id, "KO! Tap NEXT ROUND for a rematch")
		PhoneControllers.vibrate(loser.phone_id, [250, 80, 250])


# --- Phones -----------------------------------------------------------------

func _fighter_for_phone(id: int) -> Fighter:
	for f in fighters:
		if f.phone_id == id:
			return f
	return null


func _on_phone_joined(id: int) -> void:
	var slot: Fighter = null
	for f in fighters:
		if f.phone_id == 0:
			slot = f
			break
	if slot == null:
		PhoneControllers.kick(id)
		return
	slot.phone_id = id
	var p := PhoneControllers.get_player(id)
	PhoneControllers.set_player_theme(id, slot.color, "P%d · %s" % [slot.player_number, p.name])
	PhoneControllers.send_text(id, "You're Player %d (%s)" % [slot.player_number, COLOR_NAMES[slot.player_number - 1]])
	PhoneControllers.vibrate(id, 60)
	_refresh_names()
	# Everyone's here: start automatically.
	if in_lobby and fighters.all(func(f: Fighter) -> bool: return f.phone_id > 0):
		_start_match()


func _on_phone_left(id: int) -> void:
	var f := _fighter_for_phone(id)
	if f:
		f.phone_id = 0
	_refresh_names()


func _on_phone_button(id: int, button: StringName) -> void:
	if button == &"start":
		_on_start_pressed()
		return
	var f := _fighter_for_phone(id)
	if f:
		f.phone_button_pressed(button)


func _refresh_names() -> void:
	for i in 2:
		var f := fighters[i]
		var p := PhoneControllers.get_player(f.phone_id) if f.phone_id > 0 else null
		var who := "keyboard"
		if p:
			who = p.name + ("" if p.connected else " (reconnecting…)")
		_name_labels[i].text = "PLAYER %d · %s" % [f.player_number, who]
		if _slot_labels.size() > i:
			_slot_labels[i].text = ("P%d  %s" % [f.player_number, p.name + "  - ready" if p else "waiting for a phone…"])
			_slot_labels[i].modulate = Color.WHITE if p else Color(1, 1, 1, 0.55)


# --- Arena ------------------------------------------------------------------

func _build_walls() -> void:
	var t := WALL_THICKNESS
	var a := ARENA
	var rects: Array[Rect2] = [
		Rect2(a.position.x - t, a.position.y - t, a.size.x + t * 2, t),  # top
		Rect2(a.position.x - t, a.end.y, a.size.x + t * 2, t),           # bottom
		Rect2(a.position.x - t, a.position.y, t, a.size.y),              # left
		Rect2(a.end.x, a.position.y, t, a.size.y),                       # right
	]
	rects.append_array(PILLARS)
	var body := StaticBody2D.new()
	body.name = "Walls"
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	for r in rects:
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = r.size
		shape.shape = rect_shape
		shape.position = r.get_center()
		body.add_child(shape)


func _draw() -> void:
	draw_rect(ARENA, Color("#12161f"))
	for x in range(int(ARENA.position.x), int(ARENA.end.x), 60):
		draw_line(Vector2(x, ARENA.position.y), Vector2(x, ARENA.end.y), Color("#171c27"), 1.0)
	for y in range(int(ARENA.position.y), int(ARENA.end.y), 60):
		draw_line(Vector2(ARENA.position.x, y), Vector2(ARENA.end.x, y), Color("#171c27"), 1.0)
	draw_rect(ARENA, Color("#2a3142"), false, 4.0)
	for p in PILLARS:
		draw_rect(p, Color("#2a3142"))
		draw_rect(p, Color("#3a4358"), false, 2.0)


# --- HUD & lobby ------------------------------------------------------------

## QR code + join instructions; in relay mode they appear once the relay has given us a room.
func _update_join_info() -> void:
	if _qr_rect == null:
		return
	if PhoneControllers.can_join:
		_qr_rect.texture = PhoneControllers.make_qr_texture(10)
		_url_label.text = PhoneControllers.get_join_url()
		_how_label.text = "Scan the code with your phone to grab a fighter.\n" + PhoneControllers.status_message
	else:
		_qr_rect.texture = null
		_url_label.text = ""
		_how_label.text = PhoneControllers.status_message

func _build_hud() -> void:
	var hud := CanvasLayer.new()
	add_child(hud)

	for i in 2:
		var f := fighters[i]
		var box := VBoxContainer.new()
		box.position = Vector2(40 if i == 0 else 840, 16)
		box.custom_minimum_size = Vector2(400, 0)
		hud.add_child(box)

		var row := HBoxContainer.new()
		box.add_child(row)
		var name_label := Label.new()
		name_label.add_theme_color_override("font_color", f.color)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		row.add_child(name_label)
		_name_labels.append(name_label)
		var score := Label.new()
		score.text = "Wins: 0"
		row.add_child(score)
		_score_labels.append(score)

		var bar := ProgressBar.new()
		bar.max_value = Fighter.MAX_HEALTH
		bar.value = Fighter.MAX_HEALTH
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(400, 18)
		bar.fill_mode = ProgressBar.FILL_BEGIN_TO_END if i == 0 else ProgressBar.FILL_END_TO_BEGIN
		var fill := StyleBoxFlat.new()
		fill.bg_color = f.color
		bar.add_theme_stylebox_override("fill", fill)
		var bg := StyleBoxFlat.new()
		bg.bg_color = Color("#1c212c")
		bar.add_theme_stylebox_override("background", bg)
		box.add_child(bar)
		_bars.append(bar)

	var controls := Label.new()
	controls.text = "Phones: stick + ATTACK / SHOOT / BLOCK / DASH     Keyboard  P1: WASD + K L J I   P2: Arrows + Num 5 6 4 8     Tab: show QR"
	controls.add_theme_font_size_override("font_size", 13)
	controls.add_theme_color_override("font_color", Color("#6b7489"))
	controls.position = Vector2(40, 692)
	hud.add_child(controls)

	_message = Label.new()
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_message.add_theme_font_size_override("font_size", 40)
	_message.add_theme_constant_override("outline_size", 12)
	_message.add_theme_color_override("font_outline_color", Color("#0b0d12"))
	hud.add_child(_message)


func _build_lobby() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)

	_lobby = ColorRect.new()
	(_lobby as ColorRect).color = Color(0.043, 0.051, 0.071, 0.93)
	_lobby.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_lobby)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_lobby.add_child(center)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 56)
	center.add_child(row)

	var qr := TextureRect.new()
	_qr_rect = qr
	qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr.custom_minimum_size = Vector2(360, 360)
	row.add_child(qr)

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 14)
	row.add_child(col)

	var title := Label.new()
	title.text = "PvP Phone Arena"
	title.add_theme_font_size_override("font_size", 44)
	col.add_child(title)

	var how := Label.new()
	_how_label = how
	how.add_theme_color_override("font_color", Color("#8a93a6"))
	col.add_child(how)

	var url := Label.new()
	_url_label = url
	url.add_theme_color_override("font_color", Color("#6b7489"))
	url.add_theme_font_size_override("font_size", 14)
	col.add_child(url)

	col.add_child(HSeparator.new())
	for f in fighters:
		var slot := Label.new()
		slot.add_theme_font_size_override("font_size", 26)
		slot.add_theme_color_override("font_color", f.color)
		col.add_child(slot)
		_slot_labels.append(slot)
	col.add_child(HSeparator.new())

	var start := Label.new()
	start.text = "Starts automatically when both phones join.\nPlaying with the keyboard? Press Enter to start now."
	start.add_theme_color_override("font_color", Color("#8a93a6"))
	col.add_child(start)
