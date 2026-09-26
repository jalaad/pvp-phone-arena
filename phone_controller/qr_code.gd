class_name QrCode
extends RefCounted
## Minimal QR Code encoder: byte mode, error correction level M, versions 1-10
## (up to ~210 bytes of text) - plenty for a join URL.
## Algorithm ported from Project Nayuki's QR Code generator (MIT licence).
##
##   var tex := QrCode.make_texture("http://192.168.1.20:8080/?s=ABCD")
##   $TextureRect.texture = tex

const _ECC_PER_BLOCK = [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26]
const _NUM_BLOCKS = [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5]
const MAX_VERSION := 10

var version := 1
var size := 21
var _modules := PackedByteArray()
var _is_function := PackedByteArray()


## Returns null if the text is too long.
static func encode(text: String) -> QrCode:
	var qr := QrCode.new()
	if not qr._build(text.to_utf8_buffer()):
		return null
	return qr


## Convenience: text -> ready-to-display texture (use nearest filtering when scaling).
static func make_texture(text: String, pixels_per_module := 8, quiet_zone := 4) -> ImageTexture:
	var qr := encode(text)
	if qr == null:
		return null
	return ImageTexture.create_from_image(qr.to_image(pixels_per_module, quiet_zone))


func is_dark(x: int, y: int) -> bool:
	return _modules[y * size + x] == 1


func to_image(pixels_per_module := 8, quiet_zone := 4, dark := Color.BLACK, light := Color.WHITE) -> Image:
	var px := (size + quiet_zone * 2) * pixels_per_module
	var img := Image.create_empty(px, px, false, Image.FORMAT_RGBA8)
	img.fill(light)
	for y in size:
		for x in size:
			if is_dark(x, y):
				img.fill_rect(Rect2i((x + quiet_zone) * pixels_per_module, (y + quiet_zone) * pixels_per_module,
						pixels_per_module, pixels_per_module), dark)
	return img


# ---------------------------------------------------------------------------

func _build(bytes: PackedByteArray) -> bool:
	version = 1
	while version <= MAX_VERSION and 4 + _count_bits(version) + bytes.size() * 8 > _data_codewords(version) * 8:
		version += 1
	if version > MAX_VERSION:
		push_error("QrCode: text too long (%d bytes)" % bytes.size())
		return false
	size = version * 4 + 17
	_modules.resize(size * size)
	_modules.fill(0)
	_is_function.resize(size * size)
	_is_function.fill(0)

	# Data bits: byte-mode header, payload, terminator, byte padding.
	var capacity := _data_codewords(version) * 8
	var bits := []
	_append_bits(bits, 4, 4)
	_append_bits(bits, bytes.size(), _count_bits(version))
	for b in bytes:
		_append_bits(bits, b, 8)
	_append_bits(bits, 0, mini(4, capacity - bits.size()))
	_append_bits(bits, 0, (8 - bits.size() % 8) % 8)

	var data := []
	for i in range(0, bits.size(), 8):
		var b := 0
		for j in 8:
			b = (b << 1) | bits[i + j]
		data.append(b)
	var pad := 0xEC
	while data.size() * 8 < capacity:
		data.append(pad)
		pad ^= 0xEC ^ 0x11

	_draw_function_patterns()
	_draw_codewords(_add_ecc_and_interleave(data))

	# Try all 8 masks, keep the one with the lowest penalty.
	var best := 0
	var best_penalty := 1 << 30
	for m in 8:
		_apply_mask(m)
		_draw_format_bits(m)
		var p := _penalty()
		if p < best_penalty:
			best_penalty = p
			best = m
		_apply_mask(m)  # XOR again to undo
	_apply_mask(best)
	_draw_format_bits(best)
	return true


static func _append_bits(bits: Array, value: int, count: int) -> void:
	for i in range(count - 1, -1, -1):
		bits.append((value >> i) & 1)


static func _count_bits(ver: int) -> int:
	return 8 if ver <= 9 else 16


static func _raw_modules(ver: int) -> int:
	var r := (16 * ver + 128) * ver + 64
	if ver >= 2:
		var n := floori(ver / 7.0) + 2
		r -= (25 * n - 10) * n - 55
		if ver >= 7:
			r -= 36
	return r


static func _data_codewords(ver: int) -> int:
	return (_raw_modules(ver) >> 3) - _ECC_PER_BLOCK[ver] * _NUM_BLOCKS[ver]


static func _bit(value: int, i: int) -> bool:
	return ((value >> i) & 1) == 1


# --- Reed-Solomon over GF(2^8) ---

static func _gf_mul(x: int, y: int) -> int:
	var z := 0
	for i in range(7, -1, -1):
		z = (z << 1) ^ ((z >> 7) * 0x11D)
		z ^= ((y >> i) & 1) * x
	return z


static func _rs_divisor(degree: int) -> Array:
	var r := []
	r.resize(degree)
	r.fill(0)
	r[degree - 1] = 1
	var root := 1
	for i in degree:
		for j in degree:
			r[j] = _gf_mul(r[j], root)
			if j + 1 < degree:
				r[j] ^= r[j + 1]
		root = _gf_mul(root, 2)
	return r


static func _rs_remainder(data: Array, divisor: Array) -> Array:
	var r := []
	r.resize(divisor.size())
	r.fill(0)
	for b in data:
		var factor: int = b ^ r.pop_front()
		r.append(0)
		for i in r.size():
			r[i] ^= _gf_mul(divisor[i], factor)
	return r


func _add_ecc_and_interleave(data: Array) -> Array:
	var num_blocks: int = _NUM_BLOCKS[version]
	var ecc_len: int = _ECC_PER_BLOCK[version]
	var raw := _raw_modules(version) >> 3
	var num_short := num_blocks - raw % num_blocks
	var short_len := floori(raw / float(num_blocks))
	var divisor := _rs_divisor(ecc_len)
	var blocks := []
	var k := 0
	for i in num_blocks:
		var n := short_len - ecc_len + (0 if i < num_short else 1)
		var dat := data.slice(k, k + n)
		k += n
		var ecc := _rs_remainder(dat, divisor)
		if i < num_short:
			dat.append(0)
		blocks.append(dat + ecc)
	var out := []
	for i in blocks[0].size():
		for j in num_blocks:
			if i != short_len - ecc_len or j >= num_short:
				out.append(blocks[j][i])
	return out


# --- Matrix drawing ---

func _set_function(x: int, y: int, dark: bool) -> void:
	var i := y * size + x
	_modules[i] = 1 if dark else 0
	_is_function[i] = 1


func _draw_function_patterns() -> void:
	for i in size:
		_set_function(6, i, i % 2 == 0)
		_set_function(i, 6, i % 2 == 0)
	_draw_finder(3, 3)
	_draw_finder(size - 4, 3)
	_draw_finder(3, size - 4)
	var pos := _alignment_positions()
	var n := pos.size()
	for i in n:
		for j in n:
			if (i == 0 and j == 0) or (i == 0 and j == n - 1) or (i == n - 1 and j == 0):
				continue
			_draw_alignment(pos[i], pos[j])
	_draw_format_bits(0)
	_draw_version()


func _draw_finder(cx: int, cy: int) -> void:
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var d := maxi(absi(dx), absi(dy))
			var x := cx + dx
			var y := cy + dy
			if x >= 0 and x < size and y >= 0 and y < size:
				_set_function(x, y, d != 2 and d != 4)


func _draw_alignment(cx: int, cy: int) -> void:
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			_set_function(cx + dx, cy + dy, maxi(absi(dx), absi(dy)) != 1)


func _alignment_positions() -> Array:
	if version == 1:
		return []
	var n := floori(version / 7.0) + 2
	var step := ceili((version * 4 + 4) / float(n * 2 - 2)) * 2
	var r := [6]
	var p := size - 7
	while r.size() < n:
		r.insert(1, p)
		p -= step
	return r


func _draw_format_bits(mask: int) -> void:
	var data := mask  # ECC level M has format bits 0b00
	var rem := data
	for i in 10:
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	var bits := ((data << 10) | rem) ^ 0x5412
	for i in 6:
		_set_function(8, i, _bit(bits, i))
	_set_function(8, 7, _bit(bits, 6))
	_set_function(8, 8, _bit(bits, 7))
	_set_function(7, 8, _bit(bits, 8))
	for i in range(9, 15):
		_set_function(14 - i, 8, _bit(bits, i))
	for i in 8:
		_set_function(size - 1 - i, 8, _bit(bits, i))
	for i in range(8, 15):
		_set_function(8, size - 15 + i, _bit(bits, i))
	_set_function(8, size - 8, true)  # always-dark module


func _draw_version() -> void:
	if version < 7:
		return
	var rem := version
	for i in 12:
		rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
	var bits := (version << 12) | rem
	for i in 18:
		var dark := _bit(bits, i)
		var a := size - 11 + i % 3
		var b := floori(i / 3.0)
		_set_function(a, b, dark)
		_set_function(b, a, dark)


func _draw_codewords(data: Array) -> void:
	var i := 0
	var right := size - 1
	while right >= 1:
		if right == 6:
			right = 5
		for vert in size:
			for j in 2:
				var x := right - j
				var upward := ((right + 1) & 2) == 0
				var y := size - 1 - vert if upward else vert
				var idx := y * size + x
				if _is_function[idx] == 0 and i < data.size() * 8:
					_modules[idx] = (data[i >> 3] >> (7 - (i & 7))) & 1
					i += 1
		right -= 2


func _apply_mask(mask: int) -> void:
	for y in size:
		for x in size:
			var invert := false
			match mask:
				0: invert = (x + y) % 2 == 0
				1: invert = y % 2 == 0
				2: invert = x % 3 == 0
				3: invert = (x + y) % 3 == 0
				4: invert = (floori(x / 3.0) + floori(y / 2.0)) % 2 == 0
				5: invert = (x * y) % 2 + (x * y) % 3 == 0
				6: invert = ((x * y) % 2 + (x * y) % 3) % 2 == 0
				7: invert = ((x + y) % 2 + (x * y) % 3) % 2 == 0
			var idx := y * size + x
			if invert and _is_function[idx] == 0:
				_modules[idx] ^= 1


# --- Mask penalty (lower = easier to scan) ---

func _penalty() -> int:
	var p := 0
	var line := PackedByteArray()
	line.resize(size)
	for y in size:
		for x in size:
			line[x] = _modules[y * size + x]
		p += _line_penalty(line)
	for x in size:
		for y in size:
			line[y] = _modules[y * size + x]
		p += _line_penalty(line)
	for y in size - 1:
		for x in size - 1:
			var c := _modules[y * size + x]
			if c == _modules[y * size + x + 1] and c == _modules[(y + 1) * size + x] and c == _modules[(y + 1) * size + x + 1]:
				p += 3
	var dark := 0
	for m in _modules:
		dark += m
	p += floori(absi(dark * 20 - size * size * 10) / float(size * size)) * 10
	return p


func _line_penalty(l: PackedByteArray) -> int:
	var p := 0
	var run := 1
	for i in range(1, size + 1):
		if i < size and l[i] == l[i - 1]:
			run += 1
		else:
			if run >= 5:
				p += run - 2
			run = 1
	for i in range(0, size - 6):  # finder-like 1:1:3:1:1 patterns
		if l[i] == 1 and l[i + 1] == 0 and l[i + 2] == 1 and l[i + 3] == 1 and l[i + 4] == 1 and l[i + 5] == 0 and l[i + 6] == 1:
			var before := true
			var after := true
			for k in range(1, 5):
				if i - k >= 0 and l[i - k] == 1:
					before = false
				if i + 6 + k < size and l[i + 6 + k] == 1:
					after = false
			if before or after:
				p += 40
	return p
