class_name Fighter
extends CharacterBody2D
## A player-controlled fighter. Reads the keyboard actions "p<N>_up/down/left/right"
## and "p<N>_attack/shoot/block/dash" (N = player_number) AND, if a phone is assigned
## (phone_id > 0), that phone's stick and buttons. Either works at any time.

signal health_changed(fighter: Fighter)
signal hurt(fighter: Fighter, damage: float)
signal died(fighter: Fighter)

@export_range(1, 2) var player_number := 1
@export var color := Color("#4cc9f0")
@export var move_speed := 260.0

const MAX_HEALTH := 100.0
const RADIUS := 22.0

const ATTACK_DAMAGE := 12.0
const ATTACK_RANGE := 70.0
const ATTACK_ARC := 0.35        # min dot(facing, dir-to-target): ~70 degrees each side
const ATTACK_COOLDOWN := 0.4
const ATTACK_KNOCKBACK := 520.0

const SHOOT_COOLDOWN := 0.6

const DASH_SPEED := 820.0
const DASH_TIME := 0.16
const DASH_COOLDOWN := 0.9

const BLOCK_SPEED_MULT := 0.4
const BLOCK_DAMAGE_MULT := 0.2  # hits from the front while blocking do 20% damage

const BULLET_SCENE := preload("res://scenes/bullet.tscn")

var health := MAX_HEALTH
var alive := true
var facing := Vector2.RIGHT
var is_blocking := false
## PhoneControllers player id driving this fighter; 0 = keyboard only.
var phone_id := 0

var _prefix := ""
var _phone_presses := {}  # buttons pressed on the phone since the last physics frame
var _knockback := Vector2.ZERO
var _dash_dir := Vector2.ZERO
var _dash_left := 0.0
var _attack_cd := 0.0
var _shoot_cd := 0.0
var _dash_cd := 0.0
var _swing_fx := 0.0
var _hurt_fx := 0.0


func _ready() -> void:
	_prefix = "p%d_" % player_number
	add_to_group("fighters")


func _physics_process(delta: float) -> void:
	_attack_cd = maxf(_attack_cd - delta, 0.0)
	_shoot_cd = maxf(_shoot_cd - delta, 0.0)
	_dash_cd = maxf(_dash_cd - delta, 0.0)
	_swing_fx = maxf(_swing_fx - delta, 0.0)
	_hurt_fx = maxf(_hurt_fx - delta, 0.0)

	var input_dir := Vector2.ZERO
	if alive:
		input_dir = _move_input()
		is_blocking = _held("block") and _dash_left <= 0.0
		# While blocking you strafe: facing (and the shield) stays put.
		if input_dir.length() > 0.2 and not is_blocking:
			facing = input_dir.normalized()

		if _just_pressed("dash") and _dash_cd == 0.0 and not is_blocking:
			_dash_dir = input_dir.normalized() if input_dir != Vector2.ZERO else facing
			_dash_left = DASH_TIME
			_dash_cd = DASH_COOLDOWN
		if _just_pressed("attack") and _attack_cd == 0.0 and not is_blocking:
			_attack()
		if _just_pressed("shoot") and _shoot_cd == 0.0 and not is_blocking:
			_shoot()
	else:
		is_blocking = false
	_phone_presses.clear()

	if _dash_left > 0.0:
		_dash_left -= delta
		velocity = _dash_dir * DASH_SPEED
	else:
		velocity = input_dir * move_speed * (BLOCK_SPEED_MULT if is_blocking else 1.0)
	velocity += _knockback
	_knockback = _knockback.move_toward(Vector2.ZERO, 2200.0 * delta)
	move_and_slide()
	queue_redraw()


## Called by attacks and bullets. from_position is where the hit came from (for blocking).
func take_hit(damage: float, knockback: Vector2, from_position: Vector2) -> void:
	if not alive or _dash_left > 0.0:  # dashing grants brief invulnerability
		return
	var from_dir := (from_position - global_position).normalized()
	if is_blocking and facing.dot(from_dir) > 0.2:
		damage *= BLOCK_DAMAGE_MULT
		knockback *= 0.3
	health = maxf(health - damage, 0.0)
	_knockback += knockback
	_hurt_fx = 0.12
	hurt.emit(self, damage)
	health_changed.emit(self)
	if health == 0.0:
		alive = false
		died.emit(self)


func reset(spawn_position: Vector2, face: Vector2) -> void:
	global_position = spawn_position
	facing = face
	health = MAX_HEALTH
	alive = true
	is_blocking = false
	_knockback = Vector2.ZERO
	_dash_left = 0.0
	_attack_cd = 0.0
	_shoot_cd = 0.0
	_dash_cd = 0.0
	health_changed.emit(self)


## Called by main when this fighter's phone presses a button. Buffered so a quick
## tap between two physics frames still counts.
func phone_button_pressed(button: StringName) -> void:
	_phone_presses[button] = true


func _move_input() -> Vector2:
	var dir := Input.get_vector(_prefix + "left", _prefix + "right", _prefix + "up", _prefix + "down")
	if phone_id > 0:
		var stick := PhoneControllers.get_stick(phone_id)
		if stick.length() > dir.length():
			dir = stick
	return dir


func _held(action: String) -> bool:
	return Input.is_action_pressed(_prefix + action) \
			or (phone_id > 0 and PhoneControllers.is_pressed(phone_id, StringName(action)))


func _just_pressed(action: String) -> bool:
	return Input.is_action_just_pressed(_prefix + action) or _phone_presses.has(StringName(action))


func _attack() -> void:
	_attack_cd = ATTACK_COOLDOWN
	_swing_fx = 0.12
	for other: Fighter in get_tree().get_nodes_in_group("fighters"):
		if other == self or not other.alive:
			continue
		var to_other := other.global_position - global_position
		if to_other.length() <= ATTACK_RANGE + RADIUS and facing.dot(to_other.normalized()) >= ATTACK_ARC:
			other.take_hit(ATTACK_DAMAGE, to_other.normalized() * ATTACK_KNOCKBACK, global_position)


func _shoot() -> void:
	_shoot_cd = SHOOT_COOLDOWN
	var bullet: Bullet = BULLET_SCENE.instantiate()
	bullet.shooter = self
	bullet.direction = facing
	bullet.color = color
	bullet.position = position + facing * (RADIUS + 8.0)
	get_parent().add_child(bullet)


func _draw() -> void:
	var body := color if alive else color.darkened(0.65)
	if _hurt_fx > 0.0:
		body = Color.WHITE
	if _dash_left > 0.0:
		draw_circle(-_dash_dir * 16.0, RADIUS * 0.85, Color(color, 0.25))
	draw_circle(Vector2.ZERO, RADIUS, body)
	draw_circle(facing * (RADIUS - 8.0), 5.0, Color("#0b0d12"))
	var a := facing.angle()
	if is_blocking:
		draw_arc(Vector2.ZERO, RADIUS + 9.0, a - 1.1, a + 1.1, 16, Color("#e8ecf4"), 5.0)
	if _swing_fx > 0.0:
		draw_arc(Vector2.ZERO, ATTACK_RANGE * 0.85, a - 1.2, a + 1.2, 20, Color(color, 0.85), 10.0)
	# Dash-ready pip under the fighter.
	draw_circle(Vector2(0, RADIUS + 10.0), 3.5, Color("#e8ecf4") if _dash_cd == 0.0 else Color("#3a4150"))
	draw_string(ThemeDB.fallback_font, Vector2(-20, -RADIUS - 10.0), "P%d" % player_number,
			HORIZONTAL_ALIGNMENT_CENTER, 40, 14, Color.WHITE)
