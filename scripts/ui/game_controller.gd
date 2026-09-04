extends Control
## Game flow for Chess Master. Owns the position, turns board clicks into moves,
## runs the AI on a worker thread and keeps the board view and side panel in sync.

const STATUS_COLOR_HUMAN := Color("e8d9b8")
const STATUS_COLOR_AI := Color("9a8f80")
const STATUS_COLOR_CHECK := Color("ff6b5b")
const STATUS_COLOR_END := Color("f0c060")
## The AI accepts a draw offer when it judges itself at least this far behind (centipawns).
const DRAW_ACCEPT_THRESHOLD := -150
const THINKING_DOT_INTERVAL := 0.4

@onready var board: BoardView = %BoardView
@onready var panel: SidePanel = %SidePanel
@onready var promotion_dialog: PromotionDialog = %PromotionDialog
@onready var game_over_banner: Control = %GameOverBanner
@onready var game_over_title: Label = %GameOverTitle
@onready var game_over_subtitle: Label = %GameOverSubtitle
@onready var resign_dialog: ConfirmationDialog = %ResignDialog
@onready var sfx_move: AudioStreamPlayer = %SfxMove
@onready var sfx_capture: AudioStreamPlayer = %SfxCapture
@onready var sfx_check: AudioStreamPlayer = %SfxCheck
@onready var sfx_game_end: AudioStreamPlayer = %SfxGameEnd

var pos := ChessPosition.new()
var ai := ChessAI.new()
var human_color := ChessPosition.WHITE
var sound_enabled := true
var game_over := false

var _san_history: Array[String] = []
var _start_fullmove := 1
var _start_side := ChessPosition.WHITE
var _legal_moves := PackedInt32Array()      # legal moves for the human's current turn
var _selected_sq := -1
var _pending_promotion := PackedInt32Array()  # candidate moves awaiting the piece choice
var _thread: Thread
var _search_id := 0                          # stale AI results (after Undo / New Game) are ignored
var _ai_thinking := false
var _thinking_timer := 0.0
var _thinking_dots := 0


func _ready() -> void:
	board.square_clicked.connect(_on_square_clicked)
	board.square_right_clicked.connect(_clear_selection)
	promotion_dialog.piece_chosen.connect(_on_promotion_chosen)
	promotion_dialog.cancelled.connect(_clear_selection)
	panel.new_game_requested.connect(new_game)
	panel.undo_requested.connect(undo)
	panel.flip_requested.connect(flip_board)
	panel.resign_requested.connect(_on_resign_requested)
	panel.draw_offer_requested.connect(offer_draw)
	panel.copy_fen_requested.connect(copy_fen)
	panel.load_fen_requested.connect(load_fen)
	panel.depth_changed.connect(_on_depth_changed)
	panel.sound_toggled.connect(_on_sound_toggled)
	panel.play_as_black_toggled.connect(_on_play_as_black_toggled)
	resign_dialog.confirmed.connect(resign)
	%GameOverNewGame.pressed.connect(new_game)
	ai.max_depth = panel.get_depth()
	new_game()


func _exit_tree() -> void:
	_abort_ai()


func _process(delta: float) -> void:
	if not _ai_thinking:
		return
	_thinking_timer += delta
	if _thinking_timer >= THINKING_DOT_INTERVAL:
		_thinking_timer = 0.0
		_thinking_dots = (_thinking_dots + 1) % 4
		_update_status()


# ---------------------------------------------------------------------------
# Game control
# ---------------------------------------------------------------------------

func new_game() -> void:
	_abort_ai()
	pos.load_fen(ChessPosition.START_FEN)
	_after_position_loaded()


func load_fen(fen: String) -> void:
	if fen.strip_edges().is_empty():
		return
	_abort_ai()
	if not pos.load_fen(fen):
		panel.set_info("Invalid FEN")
		_next_turn()
		return
	_after_position_loaded()


func _after_position_loaded() -> void:
	_san_history.clear()
	_start_fullmove = pos.fullmove_number
	_start_side = pos.side_to_move
	game_over = false
	game_over_banner.hide()
	promotion_dialog.hide()
	board.flipped = human_color == ChessPosition.BLACK
	board.display_position(pos)
	board.set_last_move(-1, -1)
	panel.set_info("")
	_clear_selection()
	_refresh_panel()
	_next_turn()


## Takes back the last full move: the AI's reply (if any) and the human's move.
func undo() -> void:
	if pos.ply_count() == 0:
		return
	_abort_ai()
	promotion_dialog.hide()
	pos.unmake_move()
	_san_history.pop_back()
	while pos.side_to_move != human_color and pos.ply_count() > 0:
		pos.unmake_move()
		_san_history.pop_back()
	game_over = false
	game_over_banner.hide()
	board.rebuild_pieces()
	var last := pos.last_move()
	if last != 0:
		board.set_last_move(ChessMove.from_sq(last), ChessMove.to_sq(last))
	else:
		board.set_last_move(-1, -1)
	panel.set_info("")
	_clear_selection()
	_refresh_panel()
	_next_turn()


func flip_board() -> void:
	board.flipped = not board.flipped


func resign() -> void:
	if game_over:
		return
	_abort_ai()
	game_over = true
	board.interactive = false
	_clear_selection()
	var loser := _color_name(human_color)
	var winner := _color_name(-human_color)
	_show_game_over("Resignation", "%s resigned – %s wins" % [loser, winner])


func offer_draw() -> void:
	if game_over or _ai_thinking:
		return
	# Evaluate from the AI's point of view; it only takes a draw when losing.
	var white_eval := ai.evaluate_white_pov(pos)
	var ai_eval := white_eval if human_color == ChessPosition.BLACK else -white_eval
	if ai_eval <= DRAW_ACCEPT_THRESHOLD:
		game_over = true
		board.interactive = false
		_clear_selection()
		_show_game_over("Draw", "Draw agreed")
	else:
		panel.set_info("%s declines the draw offer" % _color_name(-human_color))


func copy_fen() -> void:
	DisplayServer.clipboard_set(pos.to_fen())
	panel.set_info("FEN copied to clipboard")


func _on_resign_requested() -> void:
	if not game_over:
		resign_dialog.popup_centered()


func _on_depth_changed(depth: int) -> void:
	ai.max_depth = depth


func _on_sound_toggled(enabled: bool) -> void:
	sound_enabled = enabled


func _on_play_as_black_toggled(enabled: bool) -> void:
	human_color = ChessPosition.BLACK if enabled else ChessPosition.WHITE
	new_game()


# ---------------------------------------------------------------------------
# Turn flow
# ---------------------------------------------------------------------------

## Called after every position change: ends the game, hands the move to the
## human, or starts the AI.
func _next_turn() -> void:
	board.set_check_square(pos.king_square(pos.side_to_move) if pos.in_check() else -1)
	var status := pos.get_game_status()
	if status != ChessPosition.Status.ONGOING:
		_end_game(status)
		return
	if pos.side_to_move == human_color:
		_legal_moves = pos.generate_legal_moves()
		_update_status()
		if board.is_animating():
			# Keep input locked until the piece that just moved (ours or the AI's)
			# finishes sliding into place.
			await board.animation_finished
			if game_over or pos.side_to_move != human_color:
				return
		board.interactive = true
	else:
		_start_ai()


func _update_status() -> void:
	if game_over:
		return
	var side := _color_name(pos.side_to_move)
	if _ai_thinking:
		panel.set_status("%s is thinking%s" % [side, ".".repeat(_thinking_dots)], STATUS_COLOR_AI)
	elif pos.in_check():
		panel.set_status("Check! %s to move" % side, STATUS_COLOR_CHECK)
	else:
		panel.set_status("%s to move" % side, STATUS_COLOR_HUMAN)


func _end_game(status: int) -> void:
	game_over = true
	board.interactive = false
	_clear_selection()
	var title := "Draw"
	var subtitle := ""
	match status:
		ChessPosition.Status.CHECKMATE:
			title = "Checkmate"
			subtitle = "%s wins" % _color_name(-pos.side_to_move)
		ChessPosition.Status.STALEMATE:
			title = "Stalemate"
			subtitle = "Draw"
		ChessPosition.Status.DRAW_REPETITION:
			subtitle = "Threefold repetition"
		ChessPosition.Status.DRAW_FIFTY_MOVES:
			subtitle = "Fifty-move rule"
		ChessPosition.Status.DRAW_INSUFFICIENT_MATERIAL:
			subtitle = "Insufficient material"
	_show_game_over(title, subtitle)


func _show_game_over(title: String, subtitle: String) -> void:
	panel.set_status("%s – %s" % [title, subtitle], STATUS_COLOR_END)
	game_over_title.text = title
	game_over_subtitle.text = subtitle
	if board.is_animating():
		await board.animation_finished
	if not game_over:
		return  # a new game started during the animation
	game_over_banner.show()
	_play_sound(sfx_game_end)


# ---------------------------------------------------------------------------
# Human input
# ---------------------------------------------------------------------------

func _on_square_clicked(sq: int) -> void:
	if game_over or _ai_thinking or pos.side_to_move != human_color or board.is_animating():
		return
	if _selected_sq >= 0 and sq != _selected_sq:
		var candidates := PackedInt32Array()
		for m in _legal_moves:
			if ChessMove.from_sq(m) == _selected_sq and ChessMove.to_sq(m) == sq:
				candidates.push_back(m)
		if candidates.size() == 1:
			_play_move(candidates[0])
			return
		if candidates.size() > 1:  # four promotion choices
			_pending_promotion = candidates
			promotion_dialog.open(human_color)
			return
	var piece := pos.board[sq]
	if piece != 0 and signi(piece) == pos.side_to_move:
		_select(sq)
	else:
		_clear_selection()


func _select(sq: int) -> void:
	_selected_sq = sq
	var targets := PackedInt32Array()
	var captures := PackedInt32Array()
	for m in _legal_moves:
		if ChessMove.from_sq(m) != sq:
			continue
		var to := ChessMove.to_sq(m)
		if targets.has(to):
			continue
		targets.push_back(to)
		if pos.board[to] != 0 or ChessMove.flag(m) == ChessMove.FLAG_EN_PASSANT:
			captures.push_back(to)
	board.set_selection(sq, targets, captures)


func _clear_selection() -> void:
	_selected_sq = -1
	_pending_promotion = PackedInt32Array()
	board.clear_selection()


func _on_promotion_chosen(piece_type: int) -> void:
	for m in _pending_promotion:
		if ChessMove.promotion(m) == piece_type:
			_play_move(m)
			return
	_clear_selection()


# ---------------------------------------------------------------------------
# Playing moves (human or AI)
# ---------------------------------------------------------------------------

func _play_move(move: int) -> void:
	var from := ChessMove.from_sq(move)
	var to := ChessMove.to_sq(move)
	var flag := ChessMove.flag(move)
	var captured_sq := -1
	var captured_piece := 0
	if flag == ChessMove.FLAG_EN_PASSANT:
		captured_sq = to - pos.side_to_move * 8
		captured_piece = pos.board[captured_sq]
	elif pos.board[to] != 0:
		captured_sq = to
		captured_piece = pos.board[to]
	var rook_from := -1
	var rook_to := -1
	if flag == ChessMove.FLAG_CASTLE:
		rook_from = to + 1 if to > from else to - 2
		rook_to = to - 1 if to > from else to + 1
	var promo_pawn_piece := pos.board[from] if ChessMove.promotion(move) != 0 else 0

	var san := ChessNotation.to_san(pos, move)  # needs the pre-move position
	pos.make_move(move)
	_san_history.append(san)
	_clear_selection()
	board.set_last_move(from, to)
	board.animate_move(from, to, captured_piece, captured_sq, rook_from, rook_to, promo_pawn_piece)
	if pos.in_check():
		_play_sound(sfx_check)
	elif captured_piece != 0:
		_play_sound(sfx_capture)
	else:
		_play_sound(sfx_move)
	_refresh_panel()
	_next_turn()


func _refresh_panel() -> void:
	panel.set_moves(_san_history, _start_fullmove, _start_side == ChessPosition.BLACK)
	panel.set_captured(pos.get_captured_pieces())
	panel.set_fen(pos.to_fen())
	panel.set_undo_enabled(pos.ply_count() > 0)


func _play_sound(player: AudioStreamPlayer) -> void:
	if sound_enabled:
		player.play()


# ---------------------------------------------------------------------------
# AI (worker thread)
# ---------------------------------------------------------------------------

func _start_ai() -> void:
	_ai_thinking = true
	_thinking_timer = 0.0
	_thinking_dots = 0
	board.interactive = false
	_update_status()
	_search_id += 1
	_thread = Thread.new()
	_thread.start(_ai_worker.bind(pos.copy(), _search_id))


## Runs on the worker thread: must not touch nodes, only the position copy.
func _ai_worker(snapshot: ChessPosition, search_id: int) -> void:
	var move := ai.find_best_move(snapshot)
	_on_ai_finished.call_deferred(search_id, move)


func _on_ai_finished(search_id: int, move: int) -> void:
	if search_id != _search_id:
		return  # aborted search; its thread was already joined
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_ai_thinking = false
	if move == 0 or game_over:
		return
	panel.set_info(_format_search_info())
	if board.is_animating():
		await board.animation_finished
		if search_id != _search_id or game_over:
			return
	_play_move(move)


## Stops any running search and invalidates its pending result.
func _abort_ai() -> void:
	_search_id += 1
	if _thread != null:
		ai.abort = true
		_thread.wait_to_finish()
		_thread = null
	_ai_thinking = false


func _format_search_info() -> String:
	var score := ai.best_score  # from the AI's perspective
	var white_score := score if human_color == ChessPosition.BLACK else -score
	var eval_text: String
	if absi(score) >= ChessAI.MATE_SCORE - ChessAI.MAX_PLY:
		var mate_in := ceili((ChessAI.MATE_SCORE - absi(score)) / 2.0)
		eval_text = "%s#%d" % ["+" if white_score > 0 else "-", mate_in]
	else:
		eval_text = "%+.2f" % (white_score / 100.0)
	return "Depth %d · Eval %s · %s nodes · %.1f s" % [
			ai.depth_reached, eval_text, _with_thousands(ai.nodes), ai.elapsed_msec / 1000.0]


static func _with_thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


static func _color_name(color: int) -> String:
	return "White" if color == ChessPosition.WHITE else "Black"
