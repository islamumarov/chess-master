class_name ChessPosition
extends RefCounted
## Pure chess rules: board state, move generation, make/unmake, check detection,
## game status, FEN import/export and Zobrist hashing for repetition detection.
##
## No scene-tree dependencies, so the AI can search a copy from a worker thread.
##
## Board: 64-entry PackedInt32Array, index = rank * 8 + file (a1 = 0, h1 = 7,
## a8 = 56, h8 = 63). Each entry is `color * piece_type`: white pieces are
## positive, black pieces negative, 0 is empty. Moves are packed ints (ChessMove).

enum { EMPTY = 0, PAWN = 1, KNIGHT = 2, BISHOP = 3, ROOK = 4, QUEEN = 5, KING = 6 }
enum Status { ONGOING, CHECKMATE, STALEMATE, DRAW_REPETITION, DRAW_FIFTY_MOVES, DRAW_INSUFFICIENT_MATERIAL }

const WHITE := 1
const BLACK := -1
const NO_SQUARE := -1

const CASTLE_WK := 1
const CASTLE_WQ := 2
const CASTLE_BK := 4
const CASTLE_BQ := 8

const START_FEN := "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
const PIECE_LETTERS := ".PNBRQK"  # indexed by piece type; lower case = black in FEN

# Squares used by the castling code.
const A1 := 0
const B1 := 1
const C1 := 2
const D1 := 3
const E1 := 4
const F1 := 5
const G1 := 6
const H1 := 7
const A8 := 56
const B8 := 57
const C8 := 58
const D8 := 59
const E8 := 60
const F8 := 61
const G8 := 62
const H8 := 63

# Zobrist key table layout.
const ZOB_CASTLE := 768   # 12 piece kinds * 64 squares come first
const ZOB_EP := 784       # 16 castling-right combinations
const ZOB_SIDE := 792     # 8 en passant files
const ZOB_SIZE := 793

# Undo record layout (one int64 per ply):
#   bits 0-17 move | 18-21 captured piece + 8 | 22-25 castling | 26-32 ep square + 1 | 33+ halfmove clock
const UNDO_CAPTURED_SHIFT := 18
const UNDO_CASTLING_SHIFT := 22
const UNDO_EP_SHIFT := 26
const UNDO_HALFMOVE_SHIFT := 33

# Shared read-only lookup tables, built once (see _ensure_tables).
static var _zobrist := PackedInt64Array()
static var _castle_mask := PackedInt32Array()  # rights lost when a piece leaves/enters a square
static var _knight_df := PackedInt32Array()
static var _knight_dr := PackedInt32Array()
static var _king_df := PackedInt32Array()
static var _king_dr := PackedInt32Array()
static var _bishop_df := PackedInt32Array()
static var _bishop_dr := PackedInt32Array()
static var _rook_df := PackedInt32Array()
static var _rook_dr := PackedInt32Array()

var board := PackedInt32Array()
var side_to_move := WHITE
var castling := 0
var ep_square := NO_SQUARE  ## Square a pawn may capture onto en passant, or NO_SQUARE.
var halfmove_clock := 0     ## Plies since the last capture or pawn move (fifty-move rule).
var fullmove_number := 1
var hash := 0               ## Zobrist hash of the current position.

var move_stack := PackedInt32Array()    ## Moves played since the position was loaded.
var hash_history := PackedInt64Array()  ## Hash before each move in move_stack.
var _undo_stack := PackedInt64Array()
var _king_sq := PackedInt32Array([E1, E8])  # [white king, black king]


func _init() -> void:
	_ensure_tables()
	board.resize(64)
	load_fen(START_FEN)


static func _ensure_tables() -> void:
	if not _zobrist.is_empty():
		return
	# Fixed seed: hashes are stable across runs (handy for debugging).
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EEDC4E5
	_zobrist.resize(ZOB_SIZE)
	for i in ZOB_SIZE:
		_zobrist[i] = (int(rng.randi()) << 32) | int(rng.randi())

	_castle_mask.resize(64)
	_castle_mask[A1] = CASTLE_WQ
	_castle_mask[H1] = CASTLE_WK
	_castle_mask[E1] = CASTLE_WK | CASTLE_WQ
	_castle_mask[A8] = CASTLE_BQ
	_castle_mask[H8] = CASTLE_BK
	_castle_mask[E8] = CASTLE_BK | CASTLE_BQ

	_knight_df = PackedInt32Array([1, 2, 2, 1, -1, -2, -2, -1])
	_knight_dr = PackedInt32Array([2, 1, -1, -2, -2, -1, 1, 2])
	_king_df = PackedInt32Array([-1, 0, 1, -1, 1, -1, 0, 1])
	_king_dr = PackedInt32Array([-1, -1, -1, 0, 0, 1, 1, 1])
	_bishop_df = PackedInt32Array([1, 1, -1, -1])
	_bishop_dr = PackedInt32Array([1, -1, 1, -1])
	_rook_df = PackedInt32Array([1, -1, 0, 0])
	_rook_dr = PackedInt32Array([0, 0, 1, -1])


# ---------------------------------------------------------------------------
# Basic accessors
# ---------------------------------------------------------------------------

static func square(file: int, rank: int) -> int:
	return rank * 8 + file


static func color_of(piece: int) -> int:
	return signi(piece)


static func type_of(piece: int) -> int:
	return absi(piece)


func piece_at(sq: int) -> int:
	return board[sq]


func king_square(color: int) -> int:
	return _king_sq[0 if color == WHITE else 1]


## Last move played, or 0 if none.
func last_move() -> int:
	var n := move_stack.size()
	return move_stack[n - 1] if n > 0 else 0


func ply_count() -> int:
	return move_stack.size()


## Deep copy; the AI searches on one of these from a worker thread.
func copy() -> ChessPosition:
	var c := ChessPosition.new()
	c.board = board.duplicate()
	c.side_to_move = side_to_move
	c.castling = castling
	c.ep_square = ep_square
	c.halfmove_clock = halfmove_clock
	c.fullmove_number = fullmove_number
	c.hash = hash
	c.move_stack = move_stack.duplicate()
	c.hash_history = hash_history.duplicate()
	c._undo_stack = _undo_stack.duplicate()
	c._king_sq = _king_sq.duplicate()
	return c


# ---------------------------------------------------------------------------
# Attack detection
# ---------------------------------------------------------------------------

## True if any piece of color `by` attacks `sq`. Looks outward from the square,
## which is much cheaper than generating all enemy moves.
func is_square_attacked(sq: int, by: int) -> bool:
	var f := sq & 7
	var r := sq >> 3
	# Pawns: a `by` pawn attacks sq from one rank behind (relative to its direction).
	var pr := r - by
	if pr >= 0 and pr <= 7:
		var pawn := by * PAWN
		if f > 0 and board[pr * 8 + f - 1] == pawn:
			return true
		if f < 7 and board[pr * 8 + f + 1] == pawn:
			return true
	# Knights
	var knight := by * KNIGHT
	for i in 8:
		var tf := f + _knight_df[i]
		var tr := r + _knight_dr[i]
		if tf >= 0 and tf <= 7 and tr >= 0 and tr <= 7 and board[tr * 8 + tf] == knight:
			return true
	# King
	var king := by * KING
	for i in 8:
		var tf := f + _king_df[i]
		var tr := r + _king_dr[i]
		if tf >= 0 and tf <= 7 and tr >= 0 and tr <= 7 and board[tr * 8 + tf] == king:
			return true
	# Sliders: first piece met along each ray decides.
	var queen := by * QUEEN
	var bishop := by * BISHOP
	for i in 4:
		var df := _bishop_df[i]
		var dr := _bishop_dr[i]
		var tf := f + df
		var tr := r + dr
		while tf >= 0 and tf <= 7 and tr >= 0 and tr <= 7:
			var p := board[tr * 8 + tf]
			if p != 0:
				if p == bishop or p == queen:
					return true
				break
			tf += df
			tr += dr
	var rook := by * ROOK
	for i in 4:
		var df := _rook_df[i]
		var dr := _rook_dr[i]
		var tf := f + df
		var tr := r + dr
		while tf >= 0 and tf <= 7 and tr >= 0 and tr <= 7:
			var p := board[tr * 8 + tf]
			if p != 0:
				if p == rook or p == queen:
					return true
				break
			tf += df
			tr += dr
	return false


func in_check(color: int = side_to_move) -> bool:
	return is_square_attacked(_king_sq[0 if color == WHITE else 1], -color)


# ---------------------------------------------------------------------------
# Move generation
# ---------------------------------------------------------------------------

## Pseudo-legal moves for `color` (default: side to move); may leave the own king
## in check. With `captures_only`, returns only captures, en passant and
## promotions (used by the quiescence search).
func generate_pseudo_legal_moves(color: int = side_to_move, captures_only: bool = false) -> PackedInt32Array:
	var moves := PackedInt32Array()
	for from in 64:
		var piece := board[from]
		if piece == 0 or piece * color < 0:
			continue
		var f := from & 7
		var r := from >> 3
		var type := piece * color
		if type == PAWN:
			_gen_pawn(moves, from, f, r, color, captures_only)
		elif type == KNIGHT:
			_gen_steps(moves, from, f, r, color, _knight_df, _knight_dr, captures_only)
		elif type == BISHOP:
			_gen_slides(moves, from, f, r, color, _bishop_df, _bishop_dr, captures_only)
		elif type == ROOK:
			_gen_slides(moves, from, f, r, color, _rook_df, _rook_dr, captures_only)
		elif type == QUEEN:
			_gen_slides(moves, from, f, r, color, _bishop_df, _bishop_dr, captures_only)
			_gen_slides(moves, from, f, r, color, _rook_df, _rook_dr, captures_only)
		else:
			_gen_steps(moves, from, f, r, color, _king_df, _king_dr, captures_only)
			if not captures_only:
				_gen_castling(moves, color)
	return moves


## Strictly legal moves for the side to move (own king not left in check).
func generate_legal_moves() -> PackedInt32Array:
	var legal := PackedInt32Array()
	var color := side_to_move
	for m in generate_pseudo_legal_moves(color):
		make_move(m)
		if not in_check(color):
			legal.push_back(m)
		unmake_move()
	return legal


## Legal moves from `from` to `to`; a promotion yields four (one per piece).
func legal_moves_between(from: int, to: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for m in generate_legal_moves():
		if (m & 63) == from and ((m >> 6) & 63) == to:
			result.push_back(m)
	return result


func _gen_pawn(moves: PackedInt32Array, from: int, f: int, r: int, color: int, captures_only: bool) -> void:
	var r1 := r + color
	if r1 < 0 or r1 > 7:
		return  # Pawn on its last rank: only possible in hand-made FENs.
	var promo_rank := 7 if color == WHITE else 0
	var is_promo := r1 == promo_rank
	# Pushes
	var to := r1 * 8 + f
	if board[to] == 0:
		if is_promo:
			_add_promotions(moves, from, to)
		elif not captures_only:
			moves.push_back(from | (to << 6))
			var start_rank := 1 if color == WHITE else 6
			if r == start_rank:
				var to2 := to + color * 8
				if board[to2] == 0:
					moves.push_back(from | (to2 << 6) | (ChessMove.FLAG_DOUBLE_PUSH << 15))
	# Diagonal captures, including en passant
	if f > 0:
		_gen_pawn_capture(moves, from, r1 * 8 + f - 1, color, is_promo)
	if f < 7:
		_gen_pawn_capture(moves, from, r1 * 8 + f + 1, color, is_promo)


func _gen_pawn_capture(moves: PackedInt32Array, from: int, to: int, color: int, is_promo: bool) -> void:
	var target := board[to]
	if target != 0:
		if target * color < 0:
			if is_promo:
				_add_promotions(moves, from, to)
			else:
				moves.push_back(from | (to << 6))
	elif to == ep_square and color == side_to_move:
		moves.push_back(from | (to << 6) | (ChessMove.FLAG_EN_PASSANT << 15))


func _add_promotions(moves: PackedInt32Array, from: int, to: int) -> void:
	var base := from | (to << 6)
	moves.push_back(base | (QUEEN << 12))
	moves.push_back(base | (ROOK << 12))
	moves.push_back(base | (BISHOP << 12))
	moves.push_back(base | (KNIGHT << 12))


## Knight and king: single steps.
func _gen_steps(moves: PackedInt32Array, from: int, f: int, r: int, color: int,
		dfs: PackedInt32Array, drs: PackedInt32Array, captures_only: bool) -> void:
	for i in 8:
		var tf := f + dfs[i]
		var tr := r + drs[i]
		if tf < 0 or tf > 7 or tr < 0 or tr > 7:
			continue
		var to := tr * 8 + tf
		var target := board[to]
		if target == 0:
			if not captures_only:
				moves.push_back(from | (to << 6))
		elif target * color < 0:
			moves.push_back(from | (to << 6))


## Bishop, rook and queen: slide until blocked.
func _gen_slides(moves: PackedInt32Array, from: int, f: int, r: int, color: int,
		dfs: PackedInt32Array, drs: PackedInt32Array, captures_only: bool) -> void:
	for i in 4:
		var df := dfs[i]
		var dr := drs[i]
		var tf := f + df
		var tr := r + dr
		while tf >= 0 and tf <= 7 and tr >= 0 and tr <= 7:
			var to := tr * 8 + tf
			var target := board[to]
			if target == 0:
				if not captures_only:
					moves.push_back(from | (to << 6))
			else:
				if target * color < 0:
					moves.push_back(from | (to << 6))
				break
			tf += df
			tr += dr


## Castling: rights still held, squares between king and rook empty, king not in
## check and not passing through or landing on an attacked square. The rights
## bits are only ever set while king and rook stand on their home squares.
func _gen_castling(moves: PackedInt32Array, color: int) -> void:
	var enemy := -color
	if color == WHITE:
		if (castling & CASTLE_WK) != 0 and board[F1] == 0 and board[G1] == 0 \
				and not is_square_attacked(E1, enemy) and not is_square_attacked(F1, enemy) \
				and not is_square_attacked(G1, enemy):
			moves.push_back(E1 | (G1 << 6) | (ChessMove.FLAG_CASTLE << 15))
		if (castling & CASTLE_WQ) != 0 and board[D1] == 0 and board[C1] == 0 and board[B1] == 0 \
				and not is_square_attacked(E1, enemy) and not is_square_attacked(D1, enemy) \
				and not is_square_attacked(C1, enemy):
			moves.push_back(E1 | (C1 << 6) | (ChessMove.FLAG_CASTLE << 15))
	else:
		if (castling & CASTLE_BK) != 0 and board[F8] == 0 and board[G8] == 0 \
				and not is_square_attacked(E8, enemy) and not is_square_attacked(F8, enemy) \
				and not is_square_attacked(G8, enemy):
			moves.push_back(E8 | (G8 << 6) | (ChessMove.FLAG_CASTLE << 15))
		if (castling & CASTLE_BQ) != 0 and board[D8] == 0 and board[C8] == 0 and board[B8] == 0 \
				and not is_square_attacked(E8, enemy) and not is_square_attacked(D8, enemy) \
				and not is_square_attacked(C8, enemy):
			moves.push_back(E8 | (C8 << 6) | (ChessMove.FLAG_CASTLE << 15))


## Number of pseudo-legal knight, bishop, rook and queen moves for `color`
## (pawns and king excluded). Only counts, so it is much cheaper than
## generating the moves; used by the AI's mobility term.
func count_piece_mobility(color: int) -> int:
	var count := 0
	for from in 64:
		var piece := board[from]
		if piece == 0 or piece * color < 0:
			continue
		var type := piece * color
		if type == PAWN or type == KING:
			continue
		var f := from & 7
		var r := from >> 3
		if type == KNIGHT:
			for i in 8:
				var tf := f + _knight_df[i]
				var tr := r + _knight_dr[i]
				if tf >= 0 and tf <= 7 and tr >= 0 and tr <= 7 and board[tr * 8 + tf] * color <= 0:
					count += 1
		else:
			if type != ROOK:
				count += _count_ray_squares(f, r, color, _bishop_df, _bishop_dr)
			if type != BISHOP:
				count += _count_ray_squares(f, r, color, _rook_df, _rook_dr)
	return count


func _count_ray_squares(f: int, r: int, color: int, dfs: PackedInt32Array, drs: PackedInt32Array) -> int:
	var count := 0
	for i in 4:
		var df := dfs[i]
		var dr := drs[i]
		var tf := f + df
		var tr := r + dr
		while tf >= 0 and tf <= 7 and tr >= 0 and tr <= 7:
			var target := board[tr * 8 + tf]
			if target == 0:
				count += 1
			else:
				if target * color < 0:
					count += 1
				break
			tf += df
			tr += dr
	return count


# ---------------------------------------------------------------------------
# Make / unmake
# ---------------------------------------------------------------------------

static func _piece_key(piece: int, sq: int) -> int:
	# 12 piece kinds: white P..K = 0..5, black P..K = 6..11
	return ((absi(piece) - 1) + (6 if piece < 0 else 0)) * 64 + sq


## Plays `move` (assumed pseudo-legal for the side to move) and records undo data.
func make_move(move: int) -> void:
	var from := move & 63
	var to := (move >> 6) & 63
	var promo := (move >> 12) & 7
	var flag := (move >> 15) & 7
	var color := side_to_move
	var piece := board[from]
	var type := piece * color
	var captured := board[to]
	var capture_sq := to
	if flag == ChessMove.FLAG_EN_PASSANT:
		capture_sq = to - color * 8
		captured = board[capture_sq]

	_undo_stack.push_back(move
			| ((captured + 8) << UNDO_CAPTURED_SHIFT)
			| (castling << UNDO_CASTLING_SHIFT)
			| ((ep_square + 1) << UNDO_EP_SHIFT)
			| (halfmove_clock << UNDO_HALFMOVE_SHIFT))
	hash_history.push_back(hash)
	move_stack.push_back(move)

	var h := hash
	if captured != 0:
		board[capture_sq] = 0
		h ^= _zobrist[_piece_key(captured, capture_sq)]

	var placed := piece if promo == 0 else color * promo
	board[from] = 0
	board[to] = placed
	h ^= _zobrist[_piece_key(piece, from)] ^ _zobrist[_piece_key(placed, to)]

	if flag == ChessMove.FLAG_CASTLE:
		# King moved two squares; the rook jumps over it to the adjacent square.
		var rook_from := to + 1 if to > from else to - 2
		var rook_to := to - 1 if to > from else to + 1
		var rook := board[rook_from]
		board[rook_from] = 0
		board[rook_to] = rook
		h ^= _zobrist[_piece_key(rook, rook_from)] ^ _zobrist[_piece_key(rook, rook_to)]

	if type == KING:
		_king_sq[0 if color == WHITE else 1] = to

	# Castling rights: any move from/to a king or rook home square removes them.
	h ^= _zobrist[ZOB_CASTLE + castling]
	castling &= ~(_castle_mask[from] | _castle_mask[to])
	h ^= _zobrist[ZOB_CASTLE + castling]

	if ep_square != NO_SQUARE:
		h ^= _zobrist[ZOB_EP + (ep_square & 7)]
	if flag == ChessMove.FLAG_DOUBLE_PUSH:
		ep_square = from + color * 8
		h ^= _zobrist[ZOB_EP + (ep_square & 7)]
	else:
		ep_square = NO_SQUARE

	if captured != 0 or type == PAWN:
		halfmove_clock = 0
	else:
		halfmove_clock += 1
	if color == BLACK:
		fullmove_number += 1
	side_to_move = -color
	hash = h ^ _zobrist[ZOB_SIDE]


## Reverts the last make_move.
func unmake_move() -> void:
	var n := _undo_stack.size()
	if n == 0:
		return
	var rec := _undo_stack[n - 1]
	_undo_stack.resize(n - 1)
	move_stack.resize(n - 1)
	hash = hash_history[n - 1]
	hash_history.resize(n - 1)

	var move := int(rec & ChessMove.MOVE_MASK)
	var captured := int((rec >> UNDO_CAPTURED_SHIFT) & 15) - 8
	castling = int((rec >> UNDO_CASTLING_SHIFT) & 15)
	ep_square = int((rec >> UNDO_EP_SHIFT) & 127) - 1
	halfmove_clock = int(rec >> UNDO_HALFMOVE_SHIFT)

	var from := move & 63
	var to := (move >> 6) & 63
	var promo := (move >> 12) & 7
	var flag := (move >> 15) & 7
	var color := -side_to_move  # the side that made the move
	side_to_move = color
	if color == BLACK:
		fullmove_number -= 1

	var piece := board[to]
	if promo != 0:
		piece = color * PAWN
	board[from] = piece
	board[to] = 0
	if flag == ChessMove.FLAG_EN_PASSANT:
		board[to - color * 8] = captured
	elif captured != 0:
		board[to] = captured
	if flag == ChessMove.FLAG_CASTLE:
		if to > from:
			board[to + 1] = board[to - 1]
			board[to - 1] = 0
		else:
			board[to - 2] = board[to + 1]
			board[to + 1] = 0
	if piece * color == KING:
		_king_sq[0 if color == WHITE else 1] = from


# ---------------------------------------------------------------------------
# Game status
# ---------------------------------------------------------------------------

## How many earlier positions equal the current one. Only positions since the
## last irreversible move (pawn move / capture) can repeat, so the scan is short.
func repetition_count() -> int:
	var count := 0
	var n := hash_history.size()
	var k := 2  # same side to move => even ply distance
	while k <= halfmove_clock and k <= n:
		if hash_history[n - k] == hash:
			count += 1
		k += 2
	return count


func is_threefold_repetition() -> bool:
	return repetition_count() >= 2


## Any earlier repetition at all; the AI treats this as a draw during search.
func is_repetition() -> bool:
	return repetition_count() >= 1


## Neither side can ever mate: bare kings, a lone minor piece, or only bishops
## that all stand on the same square color.
func has_insufficient_material() -> bool:
	var minors := 0
	var knights := 0
	var bishop_square_colors := 0  # bit 0: dark squares, bit 1: light squares
	for sq in 64:
		var t := absi(board[sq])
		if t == PAWN or t == ROOK or t == QUEEN:
			return false
		if t == KNIGHT:
			knights += 1
			minors += 1
		elif t == BISHOP:
			minors += 1
			bishop_square_colors |= 1 << (((sq >> 3) + (sq & 7)) & 1)
	if minors <= 1:
		return true
	return knights == 0 and bishop_square_colors != 3


func get_game_status() -> int:
	if generate_legal_moves().is_empty():
		return Status.CHECKMATE if in_check(side_to_move) else Status.STALEMATE
	if is_threefold_repetition():
		return Status.DRAW_REPETITION
	if halfmove_clock >= 100:
		return Status.DRAW_FIFTY_MOVES
	if has_insufficient_material():
		return Status.DRAW_INSUFFICIENT_MATERIAL
	return Status.ONGOING


## Pieces captured so far (signed piece codes), oldest first.
func get_captured_pieces() -> PackedInt32Array:
	var result := PackedInt32Array()
	for rec in _undo_stack:
		var captured := int((rec >> UNDO_CAPTURED_SHIFT) & 15) - 8
		if captured != 0:
			result.push_back(captured)
	return result


# ---------------------------------------------------------------------------
# FEN
# ---------------------------------------------------------------------------

## Loads a FEN string. Returns false (and leaves the position untouched) if the
## string is malformed or lacks exactly one king per side. Castling rights that
## contradict the piece placement are dropped. Clears the move history.
func load_fen(fen: String) -> bool:
	var parts := fen.strip_edges().split(" ", false)
	if parts.size() < 2:
		return false
	var ranks := parts[0].split("/")
	if ranks.size() != 8:
		return false

	var new_board := PackedInt32Array()
	new_board.resize(64)
	var white_king := -1
	var black_king := -1
	for i in 8:
		var rank := 7 - i
		var file := 0
		for ch in ranks[i]:
			if ch.is_valid_int():
				file += int(ch)
			else:
				var type := PIECE_LETTERS.find(ch.to_upper())
				if type <= 0 or file > 7:
					return false
				var piece := type if ch == ch.to_upper() else -type
				var sq := rank * 8 + file
				new_board[sq] = piece
				if piece == KING:
					if white_king >= 0:
						return false
					white_king = sq
				elif piece == -KING:
					if black_king >= 0:
						return false
					black_king = sq
				file += 1
		if file != 8:
			return false
	if white_king < 0 or black_king < 0:
		return false

	var side := 0
	if parts[1] == "w":
		side = WHITE
	elif parts[1] == "b":
		side = BLACK
	else:
		return false

	var rights := 0
	if parts.size() > 2:
		for ch in parts[2]:
			match ch:
				"K": rights |= CASTLE_WK
				"Q": rights |= CASTLE_WQ
				"k": rights |= CASTLE_BK
				"q": rights |= CASTLE_BQ
	# Rights are meaningless unless king and rook are home; drop the bogus ones.
	if new_board[E1] != KING:
		rights &= ~(CASTLE_WK | CASTLE_WQ)
	if new_board[H1] != ROOK:
		rights &= ~CASTLE_WK
	if new_board[A1] != ROOK:
		rights &= ~CASTLE_WQ
	if new_board[E8] != -KING:
		rights &= ~(CASTLE_BK | CASTLE_BQ)
	if new_board[H8] != -ROOK:
		rights &= ~CASTLE_BK
	if new_board[A8] != -ROOK:
		rights &= ~CASTLE_BQ

	var ep := NO_SQUARE
	if parts.size() > 3 and parts[3] != "-":
		ep = ChessMove.square_from_name(parts[3])

	var halfmove := int(parts[4]) if parts.size() > 4 and parts[4].is_valid_int() else 0
	var fullmove := int(parts[5]) if parts.size() > 5 and parts[5].is_valid_int() else 1

	board = new_board
	side_to_move = side
	castling = rights
	ep_square = ep
	halfmove_clock = maxi(halfmove, 0)
	fullmove_number = maxi(fullmove, 1)
	_king_sq[0] = white_king
	_king_sq[1] = black_king
	move_stack.clear()
	hash_history.clear()
	_undo_stack.clear()
	hash = compute_hash()
	return true


func to_fen() -> String:
	var s := ""
	for rank in range(7, -1, -1):
		var empty := 0
		for file in 8:
			var p := board[rank * 8 + file]
			if p == 0:
				empty += 1
			else:
				if empty > 0:
					s += str(empty)
					empty = 0
				var letter := PIECE_LETTERS[absi(p)]
				s += letter if p > 0 else letter.to_lower()
		if empty > 0:
			s += str(empty)
		if rank > 0:
			s += "/"
	s += " w " if side_to_move == WHITE else " b "
	var rights := ""
	if (castling & CASTLE_WK) != 0:
		rights += "K"
	if (castling & CASTLE_WQ) != 0:
		rights += "Q"
	if (castling & CASTLE_BK) != 0:
		rights += "k"
	if (castling & CASTLE_BQ) != 0:
		rights += "q"
	s += rights if rights != "" else "-"
	s += " " + (ChessMove.square_name(ep_square) if ep_square != NO_SQUARE else "-")
	s += " %d %d" % [halfmove_clock, fullmove_number]
	return s


## Full Zobrist hash from scratch (make_move keeps `hash` updated incrementally).
func compute_hash() -> int:
	var h := 0
	for sq in 64:
		var p := board[sq]
		if p != 0:
			h ^= _zobrist[_piece_key(p, sq)]
	h ^= _zobrist[ZOB_CASTLE + castling]
	if ep_square != NO_SQUARE:
		h ^= _zobrist[ZOB_EP + (ep_square & 7)]
	if side_to_move == BLACK:
		h ^= _zobrist[ZOB_SIDE]
	return h
