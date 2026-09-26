class_name PhoneControllerServer
extends Node
## Turns phones into game controllers.
##
## Add this script as an autoload named "PhoneControllers". Two ways to reach phones:
##
##   LAN mode (desktop builds): the game itself serves controller.html over HTTP (port 8080)
##   and receives input over WebSocket (port 8081). Phones must be on the same Wi-Fi.
##
##   Relay mode (web builds, e.g. itch.io): the game connects out to a relay server
##   (see relay/ in this repo) which serves the page over HTTPS and forwards messages.
##   Phones can be on any network.
##
## Mode and relay address: DEFAULT_MODE / DEFAULT_RELAY_URL below, optionally overridden by the
## Project Settings phone_controllers/mode and phone_controllers/relay_url (or an override.cfg).
## "auto" = relay in web builds, LAN everywhere else.
##
## Show players get_join_url() (or make_qr_texture()) so they can scan in. In relay mode the
## URL is only ready once join_url_changed fires.
##
##   func _process(delta):
##       for p in PhoneControllers.get_players():
##           velocity = p.stick * speed          # Vector2, y+ is down
##           if p.is_pressed(&"attack"): ...

signal player_joined(player_id: int)
## The phone dropped (screen lock, Wi-Fi blip). The slot is kept for reconnect_grace_sec.
signal player_disconnected(player_id: int)
signal player_reconnected(player_id: int)
## The player is gone for good (grace period expired or kicked).
signal player_left(player_id: int)
signal button_pressed(player_id: int, button: StringName)
signal button_released(player_id: int, button: StringName)
## Fired when phones can (or can no longer) join; the join URL is valid while can_join is true.
signal status_changed(can_join: bool, message: String)
signal join_url_changed(url: String)

@export var http_port := 8080
@export var ws_port := 8081
@export var max_players := 8
@export var reconnect_grace_sec := 30.0
## Force the address in the join URL (e.g. "192.168.1.20") if auto-detection picks the wrong adapter.
@export var host_override := ""
@export var auto_start := true

const PAGE_PATH := "res://phone_controller/controller.html"
const COLORS := ["#4cc9f0", "#f72585", "#b8f35a", "#ffb703", "#9b5de5", "#ff6b35", "#2ec4b6", "#e0e0e0"]
const _CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
## Relay used by web builds. Override per project with the Project Setting phone_controllers/relay_url.
const DEFAULT_RELAY_URL := "wss://pvp-phone-relay.pvp-phone-relay.workers.dev"
## "auto" = relay in web builds, LAN elsewhere. Override with phone_controllers/mode ("lan" / "relay").
const DEFAULT_MODE := "auto"
const _RELAY_PING_SEC := 20.0
const _RELAY_RETRY_SEC := 2.0


class Player:
	var id: int
	var name: String
	var color: Color
	## Joystick, each axis -1..1, length <= 1. y is positive DOWN (same as Godot 2D).
	var stick := Vector2.ZERO
	var buttons := {}  # StringName -> true while held
	var connected := true
	var _token := ""
	var _conn: _Connection
	var _disconnected_at := 0.0

	func is_pressed(button: StringName) -> bool:
		return buttons.has(button)


class _Connection:
	var ws := WebSocketPeer.new()  # LAN mode only
	var relay_cid := 0             # relay mode: the relay's id for this phone (0 = LAN connection)
	var player: Player
	var opened_at := 0.0


class _HttpClient:
	var tcp: StreamPeerTCP
	var data := PackedByteArray()
	var started := 0.0


## Changes every start(); old QR codes stop working so stale phones can't join a new session.
## In relay mode this is also the room code.
var session_code := ""
var players := {}  # id -> Player
## True when phones can join (LAN servers listening, or relay room open).
var can_join := false
var status_message := ""

var _http_server := TCPServer.new()
var _ws_server := TCPServer.new()
var _http_clients: Array[_HttpClient] = []
var _connections: Array[_Connection] = []
var _page := PackedByteArray()
var _running := false

var _use_relay := false
var _relay_url := ""
var _relay: WebSocketPeer
var _relay_conns := {}  # relay cid -> _Connection
var _relay_retry_at := -1.0
var _relay_last_ping := 0.0
var _relay_no_delay_set := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep phones connected while the game is paused
	var mode := str(ProjectSettings.get_setting("phone_controllers/mode", "")).strip_edges()
	if mode == "":
		mode = DEFAULT_MODE
	_relay_url = str(ProjectSettings.get_setting("phone_controllers/relay_url", "")).strip_edges()
	if _relay_url == "":
		_relay_url = DEFAULT_RELAY_URL
	_relay_url = _relay_url.trim_suffix("/")
	_use_relay = mode == "relay" or (mode == "auto" and OS.has_feature("web"))
	if auto_start:
		start()


func _exit_tree() -> void:
	stop()


# --- Public API -------------------------------------------------------------

func is_relay_mode() -> bool:
	return _use_relay


func start() -> Error:
	stop()
	_new_session_code()
	_running = true
	if _use_relay:
		if _relay_url == "":
			_set_status(false, "No relay configured (DEFAULT_RELAY_URL in phone_controller_server.gd)")
			push_error("PhoneControllers: relay mode needs phone_controllers/relay_url")
			return ERR_UNCONFIGURED
		_connect_relay()
		return OK
	return _start_lan()


func stop() -> void:
	for c in _connections.duplicate():
		_close_connection(c, 1001, "server_stopped")
	_connections.clear()
	_relay_conns.clear()
	if _relay:
		_relay.close(1000, "server_stopped")
		_relay = null
	for h in _http_clients:
		h.tcp.disconnect_from_host()
	_http_clients.clear()
	_http_server.stop()
	_ws_server.stop()
	_running = false
	can_join = false
	for id in players.keys():
		players.erase(id)
		player_left.emit(id)


func get_join_url() -> String:
	if _use_relay:
		var base := _relay_url.replace("wss://", "https://").replace("ws://", "http://")
		return "%s/?r=%s" % [base, session_code]
	return "http://%s:%d/?s=%s" % [get_lan_ip(), http_port, session_code]


## QR code of the join URL, ready for a TextureRect (set texture_filter to Nearest).
func make_qr_texture(pixels_per_module := 8) -> ImageTexture:
	return QrCode.make_texture(get_join_url(), pixels_per_module)


func get_players() -> Array:
	return players.values()


func get_player(id: int) -> Player:
	return players.get(id)


func get_stick(id: int) -> Vector2:
	var p := get_player(id)
	return p.stick if p else Vector2.ZERO


func is_pressed(id: int, button: StringName) -> bool:
	var p := get_player(id)
	return p != null and p.is_pressed(button)


## Rumble the phone (Android only; iOS browsers don't expose vibration).
## `pattern` can be an int (ms) or an Array like [100, 50, 100] (on, off, on...).
func vibrate(id: int, pattern: Variant = 60) -> void:
	if typeof(pattern) == TYPE_ARRAY:
		_send_to(id, {"t": "vibrate", "pattern": pattern})
	else:
		_send_to(id, {"t": "vibrate", "ms": int(pattern)})


## Show a short message on the phone's screen.
func send_text(id: int, text: String, duration_ms := 2500) -> void:
	_send_to(id, {"t": "msg", "text": text, "ms": duration_ms})


## Re-colour / relabel the phone's controller, e.g. to match the fighter it controls.
func set_player_theme(id: int, color: Color, label: String) -> void:
	_send_to(id, {"t": "theme", "color": "#" + color.to_html(false), "name": label})


func kick(id: int) -> void:
	var p := get_player(id)
	if p == null:
		return
	if p._conn:
		var c := p._conn
		_send(c, {"t": "reject", "reason": "kicked"})
		c.player = null
		_close_connection(c, 4003, "kicked")
	players.erase(id)
	player_left.emit(id)


## Best-guess LAN IPv4 address of this machine.
func get_lan_ip() -> String:
	if host_override != "":
		return host_override
	var best := ""
	var best_score := -1
	for ip: String in IP.get_local_addresses():
		if ip.contains(":") or ip.begins_with("127.") or ip.begins_with("169.254."):
			continue
		var score := 0
		if ip.begins_with("192.168."):
			score = 3
			if ip.begins_with("192.168.56."):  # VirtualBox host-only adapter
				score = 1
		elif ip.begins_with("10."):
			score = 2
		elif ip.begins_with("172."):
			var second := ip.get_slice(".", 1).to_int()
			if second >= 16 and second <= 31:
				score = 1  # often Docker/WSL/Hyper-V; used only as a fallback
		if score > best_score:
			best_score = score
			best = ip
	return best if best != "" else "127.0.0.1"


# --- Main loop --------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _running:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _use_relay:
		_poll_relay(now)
	else:
		_poll_http(now)
		_poll_websockets(now)
	_expire_dropped_players(now)


func _expire_dropped_players(now: float) -> void:
	var expired := []
	for p: Player in players.values():
		if not p.connected and now - p._disconnected_at > reconnect_grace_sec:
			expired.append(p.id)
	for id in expired:
		players.erase(id)
		player_left.emit(id)


func _new_session_code() -> void:
	session_code = ""
	for i in 4:
		session_code += _CODE_CHARS[randi() % _CODE_CHARS.length()]


func _set_status(is_ready: bool, message: String) -> void:
	var url_changed := is_ready and not can_join
	can_join = is_ready
	status_message = message
	status_changed.emit(is_ready, message)
	if url_changed:
		join_url_changed.emit(get_join_url())


# --- LAN mode ---------------------------------------------------------------

func _start_lan() -> Error:
	var html := FileAccess.get_file_as_string(PAGE_PATH)
	if html.is_empty():
		push_error("PhoneControllers: can't read %s. In exported builds add *.html to Export > Resources > 'Filters to export non-resource files'." % PAGE_PATH)
	_page = html.replace("__WS_PORT__", str(ws_port)).to_utf8_buffer()

	var err := _http_server.listen(http_port)
	if err != OK:
		push_error("PhoneControllers: can't listen on HTTP port %d (error %d)" % [http_port, err])
		_set_status(false, "Can't open port %d (is the game already running?)" % http_port)
		return err
	err = _ws_server.listen(ws_port)
	if err != OK:
		_http_server.stop()
		push_error("PhoneControllers: can't listen on WebSocket port %d (error %d)" % [ws_port, err])
		_set_status(false, "Can't open port %d (is the game already running?)" % ws_port)
		return err
	print("PhoneControllers: phones can join at ", get_join_url())
	_set_status(true, "Phones must be on the same Wi-Fi as this computer.")
	return OK


func _poll_http(now: float) -> void:
	while _http_server.is_connection_available():
		var h := _HttpClient.new()
		h.tcp = _http_server.take_connection()
		h.started = now
		_http_clients.append(h)

	for h: _HttpClient in _http_clients.duplicate():
		var done := false
		h.tcp.poll()
		if h.tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			done = true
		else:
			var available := h.tcp.get_available_bytes()
			if available > 0:
				var res := h.tcp.get_partial_data(available)
				if res[0] == OK:
					h.data.append_array(res[1])
			var request := h.data.get_string_from_ascii()
			if request.contains("\r\n\r\n"):
				_serve(h.tcp, request)
				done = true
			elif now - h.started > 5.0 or h.data.size() > 16384:
				done = true
		if done:
			h.tcp.disconnect_from_host()
			_http_clients.erase(h)


func _serve(tcp: StreamPeerTCP, request: String) -> void:
	var path := request.get_slice(" ", 1).get_slice("?", 0)
	if path == "/" or path == "/index.html" or path == "/controller.html":
		_respond(tcp, "200 OK", "text/html; charset=utf-8", _page)
	else:
		_respond(tcp, "404 Not Found", "text/plain", "Not found".to_utf8_buffer())


func _respond(tcp: StreamPeerTCP, status: String, content_type: String, body: PackedByteArray) -> void:
	var header := "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" \
			% [status, content_type, body.size()]
	tcp.put_data(header.to_utf8_buffer() + body)


func _poll_websockets(now: float) -> void:
	while _ws_server.is_connection_available():
		var c := _Connection.new()
		c.opened_at = now
		c.ws.accept_stream(_ws_server.take_connection())
		_connections.append(c)

	for c: _Connection in _connections.duplicate():
		c.ws.poll()
		match c.ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				while c.ws.get_available_packet_count() > 0:
					_on_text(c, c.ws.get_packet().get_string_from_utf8())
				if c.player == null and now - c.opened_at > 10.0:
					c.ws.close(4000, "no_hello")  # connected but never joined
			WebSocketPeer.STATE_CLOSED:
				_connections.erase(c)
				_on_connection_closed(c, now)


# --- Relay mode -------------------------------------------------------------
# Relay protocol (JSON text frames on one WebSocket):
#   relay -> game  {"t":"_room","room":CODE}        room is ours, phones can join
#                  {"c":ID,"open":true}             phone ID connected
#                  {"c":ID,"m":{...}}               message from phone ID
#                  {"c":ID,"closed":true}           phone ID disconnected
#   game -> relay  {"c":ID,"m":{...}}               message to phone ID
#                  {"c":ID,"close":REASON}          disconnect phone ID
#                  "ping"                           keep-alive (relay answers "pong")

func _connect_relay() -> void:
	_relay = WebSocketPeer.new()
	_relay_retry_at = -1.0
	_relay_no_delay_set = false
	var err := _relay.connect_to_url("%s/ws/host/%s" % [_relay_url, session_code])
	if err != OK:
		_relay = null
		_relay_retry_at = Time.get_ticks_msec() / 1000.0 + _RELAY_RETRY_SEC
		_set_status(false, "Can't reach the relay server, retrying…")
		return
	_set_status(false, "Connecting to the relay server…")


func _poll_relay(now: float) -> void:
	if _relay == null:
		if _relay_retry_at >= 0.0 and now >= _relay_retry_at:
			_connect_relay()
		return

	_relay.poll()
	match _relay.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _relay_no_delay_set and not OS.has_feature("web"):
				_relay_no_delay_set = true
				_relay.set_no_delay(true)  # send small packets immediately (no Nagle batching); needs an open socket
			while _relay.get_available_packet_count() > 0:
				_on_relay_text(_relay.get_packet().get_string_from_utf8(), now)
			if now - _relay_last_ping > _RELAY_PING_SEC:
				_relay_last_ping = now
				_relay.send_text("ping")
			for c: _Connection in _relay_conns.values():
				if c.player == null and now - c.opened_at > 10.0:
					_close_connection(c, 4000, "no_hello")
		WebSocketPeer.STATE_CLOSED:
			var reason := _relay.get_close_reason()
			_relay = null
			# Phones behind the relay are gone too; their players keep their slots for the grace period.
			for c: _Connection in _relay_conns.values().duplicate():
				_drop_relay_connection(c, now)
			if reason == "room_taken":
				_new_session_code()  # someone else has this code: pick another and go again
				can_join = false
				_connect_relay()
			else:
				_relay_retry_at = now + _RELAY_RETRY_SEC
				_set_status(false, "Lost the relay server, reconnecting…")


func _on_relay_text(text: String, now: float) -> void:
	if text == "pong":
		return  # answer to our keep-alive
	var msg: Variant = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY:
		return  # "pong" and anything unexpected
	if msg.get("t") == "_room":
		print("PhoneControllers: phones can join at ", get_join_url())
		_set_status(true, "Scan with any phone (Wi-Fi or mobile data).")
		return
	var cid := int(msg.get("c", 0))
	if cid <= 0:
		return
	if msg.get("open", false):
		var c := _Connection.new()
		c.relay_cid = cid
		c.opened_at = now
		_relay_conns[cid] = c
		_connections.append(c)
	elif msg.get("closed", false):
		var c: _Connection = _relay_conns.get(cid)
		if c:
			_drop_relay_connection(c, now)
	elif msg.has("m"):
		var c: _Connection = _relay_conns.get(cid)
		if c and typeof(msg["m"]) == TYPE_DICTIONARY:
			_on_message(c, msg["m"])


func _drop_relay_connection(c: _Connection, now: float) -> void:
	_relay_conns.erase(c.relay_cid)
	_connections.erase(c)
	_on_connection_closed(c, now)


# --- Shared connection handling ---------------------------------------------

func _close_connection(c: _Connection, code: int, reason: String) -> void:
	if c.relay_cid > 0:
		if _relay and _relay.get_ready_state() == WebSocketPeer.STATE_OPEN:
			_relay.send_text(JSON.stringify({"c": c.relay_cid, "close": reason}))
		if _relay_conns.has(c.relay_cid):
			_drop_relay_connection(c, Time.get_ticks_msec() / 1000.0)
	else:
		c.ws.close(code, reason)  # the poll loop notices the close and cleans up


func _on_text(c: _Connection, text: String) -> void:
	var msg: Variant = JSON.parse_string(text)
	if typeof(msg) == TYPE_DICTIONARY:
		_on_message(c, msg)


func _on_message(c: _Connection, msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"hello":
			_handle_hello(c, msg)
		"in":
			if c.player:
				_apply_input(c.player, msg)
		"ping":
			_send(c, {"t": "pong", "ts": msg.get("ts", 0)})


func _handle_hello(c: _Connection, msg: Dictionary) -> void:
	if str(msg.get("s", "")) != session_code:
		_reject(c, "old_session")
		return
	var token := str(msg.get("token", "")).left(64)
	var requested_name := str(msg.get("name", "")).strip_edges().left(12)

	# Same phone coming back (after a screen lock, page reload, etc.) -> same player slot.
	if token != "":
		for p: Player in players.values():
			if p._token != token:
				continue
			if p._conn and p._conn != c:
				var old := p._conn
				old.player = null
				_close_connection(old, 4002, "replaced")
			var was_connected := p.connected
			p._conn = c
			p.connected = true
			c.player = p
			if requested_name != "":
				p.name = requested_name
			_send_welcome(p)
			if not was_connected:
				player_reconnected.emit(p.id)
			return

	if players.size() >= max_players:
		_reject(c, "full")
		return

	var p := Player.new()
	p.id = _free_id()
	p.name = requested_name if requested_name != "" else "Player %d" % p.id
	p.color = Color(COLORS[(p.id - 1) % COLORS.size()])
	p._token = token
	p._conn = c
	c.player = p
	players[p.id] = p
	_send_welcome(p)
	player_joined.emit(p.id)


func _apply_input(p: Player, msg: Dictionary) -> void:
	var stick := Vector2(float(msg.get("x", 0.0)), float(msg.get("y", 0.0)))
	p.stick = stick.limit_length(1.0)

	var held := {}
	var list: Variant = msg.get("b", [])
	if list is Array:
		for b in list:
			held[StringName(str(b))] = true
	for b: StringName in p.buttons.keys():
		if not held.has(b):
			p.buttons.erase(b)
			button_released.emit(p.id, b)
	for b: StringName in held:
		if not p.buttons.has(b):
			p.buttons[b] = true
			button_pressed.emit(p.id, b)


func _on_connection_closed(c: _Connection, now: float) -> void:
	var p := c.player
	if p == null or p._conn != c:
		return
	p._conn = null
	p.connected = false
	p._disconnected_at = now
	_apply_input(p, {})  # release everything so nothing sticks
	player_disconnected.emit(p.id)


func _reject(c: _Connection, reason: String) -> void:
	_send(c, {"t": "reject", "reason": reason})
	_close_connection(c, 4001, reason)


func _send_welcome(p: Player) -> void:
	_send(p._conn, {"t": "welcome", "id": p.id, "name": p.name, "color": "#" + p.color.to_html(false)})


func _send_to(id: int, msg: Dictionary) -> void:
	var p := get_player(id)
	if p and p._conn:
		_send(p._conn, msg)


func _send(c: _Connection, msg: Dictionary) -> void:
	if c == null:
		return
	if c.relay_cid > 0:
		if _relay and _relay.get_ready_state() == WebSocketPeer.STATE_OPEN and _relay_conns.has(c.relay_cid):
			_relay.send_text(JSON.stringify({"c": c.relay_cid, "m": msg}))
	elif c.ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		c.ws.send_text(JSON.stringify(msg))


func _free_id() -> int:
	var id := 1
	while players.has(id):
		id += 1
	return id
