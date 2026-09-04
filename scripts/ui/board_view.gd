class_name BoardView
extends Control
## Visual chessboard. Draws squares, coordinates and highlights in _draw(),
## hosts one TextureRect per piece (tweened when a move is played) and turns
## clicks into `square_clicked` signals.
##
## Holds no rules: the controller decides what a click means and pushes the
## highlight state (selection, legal targets, last move, check) back in.

signal square_clicked(sq: int)
signal square_right_clicked
signal animation_finished

const LIGHT_SQUARE := Color("d9c7a7")
const DARK_SQUARE := Color("7a5c44")
const FRAME_COLOR := Color("2a221c")
const COORD_ON_LIGHT := Color("7a5c44")
const COORD_ON_DARK := Color("d9c7a7")
const SELECTED_COLOR := Color(1.0, 0.82, 0.25, 0.6)
const LEGAL_COLOR := Color(0.25, 0.7, 0.35, 0.75)
const CAPTURE_COLOR := Color(0.85, 0.2, 0.15, 0.85)
const LAST_MOVE_COLOR := Color(0.3, 0.55, 0.95, 0.4)
const CHECK_COLOR := Color(0.95, 0.15, 0.1)
const HOVER_COLOR := Color(1, 1, 1, 0.14)
const FRAME_WIDTH := 4.0
const MOVE_ANIM_TIME := 0.2
const CAPTURE_FADE_TIME := 0.15
const CHECK_PULSE_SPEED := 5.0

## Show the board from Black's side.
var flipped := false:
	set(value):
		flipped = value
		queue_redraw()
		_layout_pieces()

## Accept clicks (false while the AI thinks or the game is over).
var interactive := true:
	set(value):
		interactive = value
		queue_redraw()

var _position: ChessPosition
var _selected_sq := -1
var _legal_targets := PackedInt32Array()
var _capture_targets := PackedInt32Array()
var _last_move_from := -1
var _last_move_to := -1
var _check_sq := -1
var _hover_sq := -1
var _pulse := 0.0
var _piece_nodes := {}  # square -> TextureRect
var _ghosts: Array[TextureRect] = []  # fading captured pieces
var _tween: Tween


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_STOP
	set_process(false)
	resized.connect(_layout_pieces)


func _process(delta: float) -> void:
	_pulse += delta
	queue_redraw()


# ---------------------------------------------------------------------------
# State pushed in by the controller
# ---------------------------------------------------------------------------

## Binds the position to display and rebuilds all piece sprites.
func display_position(pos: ChessPosition) -> void:
	_position = pos
	rebuild_pieces()


func set_selection(sq: int, targets: PackedInt32Array, captures: PackedInt32Array) -> void:
	_selected_sq = sq
	_legal_targets = targets
	_capture_targets = captures
	queue_redraw()


func clear_selection() -> void:
	set_selection(-1, PackedInt32Array(), PackedInt32Array())


func set_last_move(from: int, to: int) -> void:
	_last_move_from = from
	_last_move_to = to
	queue_redraw()


## Square of a king in check (-1 for none); pulses red while set.
func set_check_square(sq: int) -> void:
	_check_sq = sq
	_pulse = 0.0
	set_process(sq >= 0)
	queue_redraw()


func is_animating() -> bool:
	return _tween != null and _tween.is_valid() and _tween.is_running()


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

func square_size() -> float:
	return minf(size.x, size.y) / 8.0


func board_origin() -> Vector2:
	var side := square_size() * 8.0
	return Vector2((size.x - side) * 0.5, (size.y - side) * 0.5)


## Screen cell (column, row) of a square, taking the flip into account.
func _square_to_cell(sq: int) -> Vector2i:
	var col := sq & 7
	var row := 7 - (sq >> 3)
	if flipped:
		return Vector2i(7 - col, 7 - row)
	return Vector2i(col, row)


func _cell_to_square(col: int, row: int) -> int:
	if flipped:
		col = 7 - col
		row = 7 - row
	return (7 - row) * 8 + col


func square_rect(sq: int) -> Rect2:
	var ss := square_size()
	var cell := _square_to_cell(sq)
	return Rect2(board_origin() + Vector2(cell) * ss, Vector2(ss, ss))


## Square under a local point, or -1 outside the board.
func square_at(point: Vector2) -> int:
	var local := (point - board_origin()) / square_size()
	if local.x < 0.0 or local.y < 0.0 or local.x >= 8.0 or local.y >= 8.0:
		return -1
	return _cell_to_square(int(local.x), int(local.y))


static func _is_light_square(sq: int) -> bool:
	return ((sq >> 3) + (sq & 7)) % 2 == 1


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	var ss := square_size()
	var origin := board_origin()
	var side := ss * 8.0
	draw_rect(Rect2(origin - Vector2(FRAME_WIDTH, FRAME_WIDTH), Vector2(side, side) + Vector2(FRAME_WIDTH, FRAME_WIDTH) * 2.0), FRAME_COLOR)
	for sq in 64:
		draw_rect(square_rect(sq), LIGHT_SQUARE if _is_light_square(sq) else DARK_SQUARE)

	if _last_move_from >= 0:
		draw_rect(square_rect(_last_move_from), LAST_MOVE_COLOR)
		draw_rect(square_rect(_last_move_to), LAST_MOVE_COLOR)
	if _check_sq >= 0:
		var alpha := 0.35 + 0.3 * (0.5 + 0.5 * sin(_pulse * CHECK_PULSE_SPEED))
		var rect := square_rect(_check_sq)
		draw_rect(rect, Color(CHECK_COLOR, alpha))
		draw_circle(rect.get_center(), ss * 0.42, Color(CHECK_COLOR, alpha * 0.6), true, -1.0, true)
	if _selected_sq >= 0:
		draw_rect(square_rect(_selected_sq), SELECTED_COLOR)
	if _hover_sq >= 0 and interactive and _is_hoverable(_hover_sq):
		draw_rect(square_rect(_hover_sq), HOVER_COLOR)
	for sq in _legal_targets:
		var center := square_rect(sq).get_center()
		if _capture_targets.has(sq):
			draw_arc(center, ss * 0.43, 0.0, TAU, 48, CAPTURE_COLOR, ss * 0.07, true)
		else:
			draw_circle(center, ss * 0.16, LEGAL_COLOR, true, -1.0, true)

	_draw_coordinates(ss)


## File letters along the bottom row and rank numbers down the left column.
func _draw_coordinates(ss: float) -> void:
	var font := get_theme_default_font()
	var font_size := maxi(int(ss * 0.18), 8)
	for i in 8:
		var file_sq := _cell_to_square(i, 7)
		var rect := square_rect(file_sq)
		var color := COORD_ON_LIGHT if _is_light_square(file_sq) else COORD_ON_DARK
		draw_string(font, rect.position + Vector2(ss - font_size * 0.85, ss - font_size * 0.35),
				ChessMove.FILES[file_sq & 7], HORIZONTAL_ALIGNMENT_RIGHT, -1, font_size, color)
		var rank_sq := _cell_to_square(0, i)
		rect = square_rect(rank_sq)
		color = COORD_ON_LIGHT if _is_light_square(rank_sq) else COORD_ON_DARK
		draw_string(font, rect.position + Vector2(font_size * 0.3, font_size * 1.1),
				str((rank_sq >> 3) + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


## A square is worth highlighting when it holds a piece of the side to move or
## is a legal target of the selected piece.
func _is_hoverable(sq: int) -> bool:
	if _legal_targets.has(sq):
		return true
	return _position != null and _position.board[sq] * _position.side_to_move > 0


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var sq := square_at(event.position)
		if sq != _hover_sq:
			_hover_sq = sq
			queue_redraw()
		var pointing := interactive and sq >= 0 and _is_hoverable(sq)
		mouse_default_cursor_shape = CURSOR_POINTING_HAND if pointing else CURSOR_ARROW
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var sq := square_at(event.position)
			if sq >= 0 and interactive:
				square_clicked.emit(sq)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			square_right_clicked.emit()
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover_sq != -1:
		_hover_sq = -1
		queue_redraw()


# ---------------------------------------------------------------------------
# Pieces
# ---------------------------------------------------------------------------

## Recreates piece sprites from the bound position. Finishes any running animation.
func rebuild_pieces() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	for node in _piece_nodes.values():
		node.queue_free()
	_piece_nodes.clear()
	for ghost in _ghosts:
		ghost.queue_free()
	_ghosts.clear()
	if _position == null:
		return
	for sq in 64:
		var piece := _position.board[sq]
		if piece != 0:
			_piece_nodes[sq] = _make_piece(piece, sq)


## Animates a move that has ALREADY been made on the position: sprites are
## rebuilt for the new position, then the moved piece (and castling rook) slide
## in from their old squares while a ghost of the captured piece fades out.
func animate_move(from: int, to: int, captured_piece: int = 0, captured_sq: int = -1,
		rook_from: int = -1, rook_to: int = -1) -> void:
	rebuild_pieces()
	var mover: TextureRect = _piece_nodes.get(to)
	if mover == null:
		animation_finished.emit()
		return
	_tween = create_tween().set_parallel(true)
	if captured_piece != 0 and captured_sq >= 0:
		var ghost := _make_piece(captured_piece, captured_sq)
		_ghosts.append(ghost)
		_tween.tween_property(ghost, "modulate:a", 0.0, CAPTURE_FADE_TIME)
	_place(mover, from)
	move_child(mover, -1)  # slide above the other pieces
	_tween.tween_property(mover, "position", square_rect(to).position, MOVE_ANIM_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if rook_from >= 0:
		var rook: TextureRect = _piece_nodes.get(rook_to)
		if rook != null:
			_place(rook, rook_from)
			_tween.tween_property(rook, "position", square_rect(rook_to).position, MOVE_ANIM_TIME) \
					.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(_on_animation_finished)


func _on_animation_finished() -> void:
	for ghost in _ghosts:
		ghost.queue_free()
	_ghosts.clear()
	_layout_pieces()
	animation_finished.emit()


func _make_piece(piece: int, sq: int) -> TextureRect:
	var node := TextureRect.new()
	node.texture = PieceTextures.get_texture(piece)
	node.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	node.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	node.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(node)
	_place(node, sq)
	return node


func _place(node: TextureRect, sq: int) -> void:
	var rect := square_rect(sq)
	node.position = rect.position
	node.size = rect.size


func _layout_pieces() -> void:
	for sq in _piece_nodes:
		_place(_piece_nodes[sq], sq)
