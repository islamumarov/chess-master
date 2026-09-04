class_name BoardView
extends Control
## Visual chessboard. Draws squares, coordinates and highlights in _draw(),
## hosts one TextureRect per piece (tweened when a move is played) and turns
## clicks and drags into `square_clicked` / `drag_dropped` signals.
##
## Holds no rules: the controller decides what a click or a drop means and
## pushes the highlight state (selection, legal targets, last move, check) back in.

signal square_clicked(sq: int)
signal square_right_clicked
signal animation_finished
## A press on a piece of the side to move turned into a drag.
signal drag_started(sq: int)
## A drag was released over another square; the controller decides legality.
signal drag_dropped(from: int, to: int)

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
const CAPTURE_DESTROY_TIME := 0.3  ## Length of the burst that destroys a captured piece.
const CAPTURE_DESTROY_LEAD := 0.07  ## How long before the mover lands the burst starts.
const CAPTURE_GHOST_SCALE := 1.35  ## Size the captured sprite swells to while it fades.
const FRAGMENT_COUNT := 12
const FRAGMENT_SIZE_FRACTION := 0.09  ## Fragment side, as a fraction of a square.
const FRAGMENT_START_FRACTION := 0.1  ## Radius the fragments start out from the square centre.
const FRAGMENT_SPREAD_FRACTION := 0.6  ## Distance the fragments fly, in squares.
const FRAGMENT_SPREAD_JITTER := 0.45  ## Fraction of that distance that is randomised away.
const FRAGMENT_END_SCALE := 0.3
const FRAGMENT_SPIN := 1.2  ## Radians a fragment turns over the burst.
const FRAGMENT_WHITE := Color("f4ecdc")  ## Piece fills, so the shards match the captured side.
const FRAGMENT_BLACK := Color("2b2624")
const DRAG_START_DISTANCE := 6.0  ## Pixels the mouse must travel before a press becomes a drag.
const DRAG_SNAP_BACK_TIME := 0.12  ## Time the sprite takes to slide home after a dropped drag.
const LIFT_SCALE := 1.07
const LIFT_UP_FRACTION := 0.35  ## Portion of the move spent scaling up before easing back down.
const PROMOTION_SWAP_FRACTION := 0.9  ## Progress at which the pawn sprite swaps to the promoted piece.
const CHECK_PULSE_SPEED := 5.0

## Show the board from Black's side.
var flipped := false:
	set(value):
		flipped = value
		queue_redraw()
		_layout_pieces()

## Accept clicks and drags (false while the AI thinks or the game is over).
var interactive := true:
	set(value):
		interactive = value
		if not value:
			_cancel_drag()
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
var _fx_nodes: Array[Control] = []  # ghost and fragments of the piece being destroyed
var _fx_tween: Tween  # capture burst, deliberately independent of _tween
var _tween: Tween
var _press_sq := -1        # square the left button went down on, -1 when not pressed
var _press_point := Vector2.ZERO
var _press_can_drag := false
var _drag_from := -1       # square the dragged piece came from, -1 when not dragging
var _drag_node: TextureRect
var _drag_tween: Tween     # snap-back of a released drag


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
	return _is_own_piece(sq)


## True when the square holds a piece of the side to move, the only kind that
## can be picked up. Whether the move it lands on is legal is the controller's call.
func _is_own_piece(sq: int) -> bool:
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
		if _drag_from >= 0:
			_drag_to_point(event.position)
		elif _press_can_drag and event.position.distance_to(_press_point) > DRAG_START_DISTANCE:
			_begin_drag(event.position)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_sq = square_at(event.position) if interactive else -1
				_press_point = event.position
				_press_can_drag = _press_sq >= 0 and _is_own_piece(_press_sq)
			else:
				_release(event.position)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_cancel_drag()
			square_right_clicked.emit()
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover_sq != -1:
		_hover_sq = -1
		queue_redraw()


# ---------------------------------------------------------------------------
# Dragging
# ---------------------------------------------------------------------------

## Picks the pressed piece up: it leaves its square, follows the cursor above
## the other pieces, and the controller highlights it like a click-selection.
func _begin_drag(point: Vector2) -> void:
	var node: TextureRect = _piece_nodes.get(_press_sq)
	if node == null:
		return
	if _drag_tween != null and _drag_tween.is_valid():
		_drag_tween.kill()
	_drag_from = _press_sq
	_drag_node = node
	node.pivot_offset = node.size * 0.5
	move_child(node, -1)  # drag above the other pieces
	drag_started.emit(_drag_from)
	_drag_to_point(point)


func _drag_to_point(point: Vector2) -> void:
	_drag_node.position = point - _drag_node.size * 0.5


## A drag or a click ends here: a drop over another square goes to the
## controller, a press that never moved off its square stays a plain click.
func _release(point: Vector2) -> void:
	var sq := square_at(point)
	var from := _drag_from
	if from >= 0:
		_drop_drag()
		if sq >= 0 and sq != from:
			drag_dropped.emit(from, sq)
	elif interactive and _press_sq >= 0 and sq == _press_sq:
		square_clicked.emit(sq)
	_press_sq = -1
	_press_can_drag = false


## Ends the drag and slides the sprite home. A legal drop rebuilds the sprites
## through animate_move() in the same frame, so the snap-back is only seen when
## the move was refused or the piece was let go off the board.
func _drop_drag() -> void:
	var node := _drag_node
	var from := _drag_from
	_drag_node = null
	_drag_from = -1
	if node == null:
		return
	_drag_tween = create_tween()
	_drag_tween.tween_property(node, "position", square_rect(from).position, DRAG_SNAP_BACK_TIME) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Drops the piece back without telling the controller (right-click, AI's turn).
func _cancel_drag() -> void:
	_press_sq = -1
	_press_can_drag = false
	if _drag_from >= 0:
		_drop_drag()


# ---------------------------------------------------------------------------
# Pieces
# ---------------------------------------------------------------------------

## Recreates piece sprites from the bound position. Finishes any running move
## animation; a capture burst owns its own nodes and tween, so it plays on and
## cleans itself up instead of being cut off half way.
func rebuild_pieces() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if _drag_tween != null and _drag_tween.is_valid():
		_drag_tween.kill()
	_drag_tween = null
	_drag_node = null  # freed below with the rest of the sprites
	_drag_from = -1
	_press_sq = -1
	_press_can_drag = false
	for node in _piece_nodes.values():
		node.queue_free()
	_piece_nodes.clear()
	if _position == null:
		return
	for sq in 64:
		var piece := _position.board[sq]
		if piece != 0:
			_piece_nodes[sq] = _make_piece(piece, sq)


## Animates a move that has ALREADY been made on the position: sprites are
## rebuilt for the new position, then the moved piece (and castling rook) slide
## in from their old squares while the captured piece is destroyed on its square.
## `promo_pawn_piece` is the signed pawn code the mover used to be, when the
## move promoted it; the sprite shows the pawn sliding, then swaps to the
## already-promoted piece shortly before it lands.
func animate_move(from: int, to: int, captured_piece: int = 0, captured_sq: int = -1,
		rook_from: int = -1, rook_to: int = -1, promo_pawn_piece: int = 0) -> void:
	rebuild_pieces()
	var mover: TextureRect = _piece_nodes.get(to)
	if mover == null:
		animation_finished.emit()
		return
	_tween = create_tween().set_parallel(true)
	if captured_piece != 0 and captured_sq >= 0:
		_start_capture_effect(captured_piece, captured_sq, MOVE_ANIM_TIME - CAPTURE_DESTROY_LEAD)
	_place(mover, from)
	move_child(mover, -1)  # slide above the other pieces
	mover.pivot_offset = mover.size * 0.5
	if promo_pawn_piece != 0:
		var promoted_texture := mover.texture
		mover.texture = PieceTextures.get_texture(promo_pawn_piece)
		_tween.tween_callback(func(): mover.texture = promoted_texture) \
				.set_delay(MOVE_ANIM_TIME * PROMOTION_SWAP_FRACTION)
	_tween.tween_property(mover, "position", square_rect(to).position, MOVE_ANIM_TIME) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(mover, "scale", Vector2(LIFT_SCALE, LIFT_SCALE), MOVE_ANIM_TIME * LIFT_UP_FRACTION) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.tween_property(mover, "scale", Vector2.ONE, MOVE_ANIM_TIME * (1.0 - LIFT_UP_FRACTION)) \
			.set_delay(MOVE_ANIM_TIME * LIFT_UP_FRACTION) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	if rook_from >= 0:
		var rook: TextureRect = _piece_nodes.get(rook_to)
		if rook != null:
			_place(rook, rook_from)
			_tween.tween_property(rook, "position", square_rect(rook_to).position, MOVE_ANIM_TIME) \
					.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tween.finished.connect(_on_animation_finished)


func _on_animation_finished() -> void:
	for node in _piece_nodes.values():
		node.scale = Vector2.ONE
	_layout_pieces()  # snap positions exactly; undoes any float drift from the tween
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
		if _piece_nodes[sq] != _drag_node:  # a held piece stays under the cursor
			_place(_piece_nodes[sq], sq)


# ---------------------------------------------------------------------------
# Capture effect
# ---------------------------------------------------------------------------

## Destroys a captured piece on its square: a ghost of it swells while fading
## out and a burst of fragments in its colour scatters away, `delay` seconds
## after the move animation starts (so it fires as the capturer lands).
##
## The burst runs on its own tween and node list, which is why it survives a
## rebuild_pieces() half way through instead of leaving tweens pointing at freed
## sprites; it frees its nodes when it ends, or when the next capture starts.
## Call this before raising the mover, so the mover keeps drawing above it.
func _start_capture_effect(piece: int, sq: int, delay: float) -> void:
	_clear_capture_effect()
	var center := square_rect(sq).get_center()
	var ss := square_size()
	_fx_tween = create_tween().set_parallel(true)

	var ghost := _make_piece(piece, sq)
	_fx_nodes.append(ghost)
	ghost.pivot_offset = ghost.size * 0.5
	_fx_tween.tween_property(ghost, "scale", Vector2(CAPTURE_GHOST_SCALE, CAPTURE_GHOST_SCALE), CAPTURE_DESTROY_TIME) \
			.set_delay(delay).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_fx_tween.tween_property(ghost, "modulate:a", 0.0, CAPTURE_DESTROY_TIME) \
			.set_delay(delay).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

	var frag_size := Vector2.ONE * ss * FRAGMENT_SIZE_FRACTION
	var color := FRAGMENT_WHITE if piece > 0 else FRAGMENT_BLACK
	for i in FRAGMENT_COUNT:
		# One fragment per equal slice of the circle, jittered so the ring of
		# shards does not read as a regular pattern.
		var direction := Vector2.from_angle(TAU * (float(i) + randf()) / float(FRAGMENT_COUNT))
		var start := center + direction * ss * FRAGMENT_START_FRACTION - frag_size * 0.5
		var travel := ss * FRAGMENT_SPREAD_FRACTION * randf_range(1.0 - FRAGMENT_SPREAD_JITTER, 1.0)
		var frag := _make_fragment(color, frag_size, start)
		_fx_nodes.append(frag)
		_fx_tween.tween_callback(frag.show).set_delay(delay)
		_fx_tween.tween_property(frag, "position", start + direction * travel, CAPTURE_DESTROY_TIME) \
				.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_fx_tween.tween_property(frag, "rotation", frag.rotation + randf_range(-FRAGMENT_SPIN, FRAGMENT_SPIN), CAPTURE_DESTROY_TIME) \
				.set_delay(delay)
		_fx_tween.tween_property(frag, "scale", Vector2(FRAGMENT_END_SCALE, FRAGMENT_END_SCALE), CAPTURE_DESTROY_TIME) \
				.set_delay(delay).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		_fx_tween.tween_property(frag, "modulate:a", 0.0, CAPTURE_DESTROY_TIME) \
				.set_delay(delay).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_fx_tween.finished.connect(_clear_capture_effect)


## Hidden until the burst starts, so it does not sit on the square while the
## capturing piece is still on its way.
func _make_fragment(color: Color, frag_size: Vector2, pos: Vector2) -> ColorRect:
	var frag := ColorRect.new()
	frag.color = color
	frag.size = frag_size
	frag.position = pos
	frag.pivot_offset = frag_size * 0.5
	frag.rotation = randf() * TAU
	frag.mouse_filter = MOUSE_FILTER_IGNORE
	frag.hide()
	add_child(frag)
	return frag


func _clear_capture_effect() -> void:
	if _fx_tween != null and _fx_tween.is_valid():
		_fx_tween.kill()
	_fx_tween = null
	for node in _fx_nodes:
		node.queue_free()
	_fx_nodes.clear()
