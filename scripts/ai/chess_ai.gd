class_name ChessAI
extends RefCounted
## Chess engine: negamax with alpha-beta pruning, iterative deepening, quiescence
## search (captures/promotions), MVV-LVA and killer-move ordering, and an
## evaluation made of material, piece-square tables, pawn structure, king
## safety and mobility.
##
## Searches a ChessPosition copy, normally from a worker thread. Set `abort`
## from any thread to stop early; the best move of the last finished depth is
## returned.
##
## ponytail: no transposition table. Add one (Zobrist hash -> score/move/depth)
## if depth 5+ should run in reasonable time.

const SCORE_INF := 1_000_000
const MATE_SCORE := 100_000
const MAX_PLY := 64
const MAX_QUIESCENCE_DEPTH := 8

## Material values in centipawns, indexed by piece type (0 = empty).
const PIECE_VALUES := [0, 100, 320, 330, 500, 900, 20000]

# Evaluation tuning knobs (centipawns).
const DELTA_PRUNING_MARGIN := 200   # quiescence: skip captures that cannot raise alpha even with this bonus
const DOUBLED_PAWN_PENALTY := 12
const ISOLATED_PAWN_PENALTY := 15
const KING_SHIELD_BONUS := 10       # per friendly pawn directly in front of the king
const ENDGAME_MATERIAL := 1400      # both sides at or below this non-pawn material => endgame king table

# Move ordering tiers; a move's sort key is tier + detail, packed above the move bits.
const ORDER_HASH := 1 << 18
const ORDER_CAPTURE := 1 << 16
const ORDER_PROMOTION := 1 << 15
const ORDER_KILLER := 1 << 14
const ORDER_QUIET := 1 << 13

# Piece-square tables (Tomasz Michniewski's "simplified evaluation function").
# Written as seen from White's side, rank 8 first, so index = sq ^ 56 for
# white pieces and sq for black pieces.
const PST_PAWN := [
	 0,  0,  0,  0,  0,  0,  0,  0,
	50, 50, 50, 50, 50, 50, 50, 50,
	10, 10, 20, 30, 30, 20, 10, 10,
	 5,  5, 10, 25, 25, 10,  5,  5,
	 0,  0,  0, 20, 20,  0,  0,  0,
	 5, -5,-10,  0,  0,-10, -5,  5,
	 5, 10, 10,-20,-20, 10, 10,  5,
	 0,  0,  0,  0,  0,  0,  0,  0,
]
const PST_KNIGHT := [
	-50,-40,-30,-30,-30,-30,-40,-50,
	-40,-20,  0,  0,  0,  0,-20,-40,
	-30,  0, 10, 15, 15, 10,  0,-30,
	-30,  5, 15, 20, 20, 15,  5,-30,
	-30,  0, 15, 20, 20, 15,  0,-30,
	-30,  5, 10, 15, 15, 10,  5,-30,
	-40,-20,  0,  5,  5,  0,-20,-40,
	-50,-40,-30,-30,-30,-30,-40,-50,
]
const PST_BISHOP := [
	-20,-10,-10,-10,-10,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5, 10, 10,  5,  0,-10,
	-10,  5,  5, 10, 10,  5,  5,-10,
	-10,  0, 10, 10, 10, 10,  0,-10,
	-10, 10, 10, 10, 10, 10, 10,-10,
	-10,  5,  0,  0,  0,  0,  5,-10,
	-20,-10,-10,-10,-10,-10,-10,-20,
]
const PST_ROOK := [
	 0,  0,  0,  0,  0,  0,  0,  0,
	 5, 10, 10, 10, 10, 10, 10,  5,
	-5,  0,  0,  0,  0,  0,  0, -5,
	-5,  0,  0,  0,  0,  0,  0, -5,
	-5,  0,  0,  0,  0,  0,  0, -5,
	-5,  0,  0,  0,  0,  0,  0, -5,
	-5,  0,  0,  0,  0,  0,  0, -5,
	 0,  0,  0,  5,  5,  0,  0,  0,
]
const PST_QUEEN := [
	-20,-10,-10, -5, -5,-10,-10,-20,
	-10,  0,  0,  0,  0,  0,  0,-10,
	-10,  0,  5,  5,  5,  5,  0,-10,
	 -5,  0,  5,  5,  5,  5,  0, -5,
	  0,  0,  5,  5,  5,  5,  0, -5,
	-10,  5,  5,  5,  5,  5,  0,-10,
	-10,  0,  5,  0,  0,  0,  0,-10,
	-20,-10,-10, -5, -5,-10,-10,-20,
]
const PST_KING_MIDDLE := [
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-30,-40,-40,-50,-50,-40,-40,-30,
	-20,-30,-30,-40,-40,-30,-30,-20,
	-10,-20,-20,-20,-20,-20,-20,-10,
	 20, 20,  0,  0,  0,  0, 20, 20,
	 20, 30, 10,  0,  0, 10, 30, 20,
]
const PST_KING_END := [
	-50,-40,-30,-20,-20,-30,-40,-50,
	-30,-20,-10,  0,  0,-10,-20,-30,
	-30,-10, 20, 30, 30, 20,-10,-30,
	-30,-10, 30, 40, 40, 30,-10,-30,
	-30,-10, 30, 40, 40, 30,-10,-30,
	-30,-10, 20, 30, 30, 20,-10,-30,
	-30,-30,  0,  0,  0,  0,-30,-30,
	-50,-30,-30,-30,-30,-30,-30,-50,
]

## Search settings.
var max_depth := 3
var time_limit_msec := 3000  ## Soft cap: no new iteration starts once a quarter of this is used.
var mobility_weight := 2     ## Centipawns per reachable square of a piece (0 disables the term).
var abort := false           ## Set from another thread to stop the search.

## Statistics of the last search.
var nodes := 0
var quiescence_nodes := 0
var depth_reached := 0
var best_score := 0          ## From the root side-to-move's perspective.
var elapsed_msec := 0

var _pst: Array = []  # PackedInt32Array per piece type
var _pst_king_end := PackedInt32Array(PST_KING_END)
var _killers := PackedInt32Array()  # two quiet cutoff moves per ply
var _deadline := 0
var _stopped := false


func _init() -> void:
	_pst.resize(7)
	_pst[ChessPosition.PAWN] = PackedInt32Array(PST_PAWN)
	_pst[ChessPosition.KNIGHT] = PackedInt32Array(PST_KNIGHT)
	_pst[ChessPosition.BISHOP] = PackedInt32Array(PST_BISHOP)
	_pst[ChessPosition.ROOK] = PackedInt32Array(PST_ROOK)
	_pst[ChessPosition.QUEEN] = PackedInt32Array(PST_QUEEN)
	_pst[ChessPosition.KING] = PackedInt32Array(PST_KING_MIDDLE)
	_killers.resize(MAX_PLY * 2)


# ---------------------------------------------------------------------------
# Search
# ---------------------------------------------------------------------------

## Best move for the side to move (0 if there is none). Iterative deepening:
## each depth reuses the previous best move for ordering, and the search can be
## cut off at any time while still returning a complete-depth answer.
func find_best_move(pos: ChessPosition) -> int:
	var start := Time.get_ticks_msec()
	nodes = 0
	quiescence_nodes = 0
	abort = false
	_stopped = false
	depth_reached = 0
	best_score = 0
	_deadline = start + time_limit_msec
	_killers.fill(0)

	var root_moves := pos.generate_legal_moves()
	if root_moves.is_empty():
		return 0
	var best := root_moves[0]
	if root_moves.size() == 1:
		depth_reached = 1
		elapsed_msec = Time.get_ticks_msec() - start
		return best

	for depth in range(1, max_depth + 1):
		var result := _search_root(pos, depth, root_moves, best)
		if _stopped:
			break  # partial iteration: keep the previous depth's answer
		best = result[0]
		best_score = result[1]
		depth_reached = depth
		if absi(best_score) >= MATE_SCORE - MAX_PLY:
			break  # forced mate found
		# The next iteration costs several times more than this one.
		if (Time.get_ticks_msec() - start) * 4 > time_limit_msec:
			break
	elapsed_msec = Time.get_ticks_msec() - start
	return best


func _search_root(pos: ChessPosition, depth: int, moves: PackedInt32Array, prev_best: int) -> Array:
	var ordered := _order_moves(pos, moves, 0, prev_best)
	var alpha := -SCORE_INF
	var best_move := prev_best
	var best := -SCORE_INF
	for i in range(ordered.size() - 1, -1, -1):
		var m := int(ordered[i] & ChessMove.MOVE_MASK)
		pos.make_move(m)
		var score := -_negamax(pos, depth - 1, -SCORE_INF, -alpha, 1)
		pos.unmake_move()
		if _stopped:
			break
		if score > best:
			best = score
			best_move = m
			if score > alpha:
				alpha = score
	return [best_move, best]


## Fail-soft negamax with alpha-beta. Scores are from the side to move's view.
func _negamax(pos: ChessPosition, depth: int, alpha: int, beta: int, ply: int) -> int:
	nodes += 1
	if (nodes & 2047) == 0 and (abort or Time.get_ticks_msec() > _deadline):
		_stopped = true
	if _stopped:
		return 0
	# Draw by repetition or fifty-move rule.
	if pos.is_repetition() or pos.halfmove_clock >= 100:
		return 0

	var color := pos.side_to_move
	var in_check := pos.in_check(color)
	if in_check and ply < MAX_PLY - 8:
		depth += 1  # check extension: don't stop searching in the middle of a forcing sequence
	if depth <= 0:
		return _quiescence(pos, alpha, beta, ply, 0)

	var ordered := _order_moves(pos, pos.generate_pseudo_legal_moves(color), ply, 0)
	var legal_count := 0
	var best := -SCORE_INF
	for i in range(ordered.size() - 1, -1, -1):
		var m := int(ordered[i] & ChessMove.MOVE_MASK)
		var to := (m >> 6) & 63
		var is_quiet := pos.board[to] == 0 and (m >> 12) == 0  # no capture, no promotion, no en passant/castle flag
		pos.make_move(m)
		if pos.in_check(color):
			pos.unmake_move()  # left own king in check: illegal
			continue
		legal_count += 1
		var score := -_negamax(pos, depth - 1, -beta, -alpha, ply + 1)
		pos.unmake_move()
		if _stopped:
			return 0
		if score > best:
			best = score
			if score > alpha:
				alpha = score
				if alpha >= beta:
					if is_quiet:
						_store_killer(ply, m)
					return best
	if legal_count == 0:
		return -MATE_SCORE + ply if in_check else 0  # checkmate (sooner is worse) or stalemate
	return best


## Captures and promotions only, until the position is quiet. Prevents the
## horizon effect of evaluating in the middle of an exchange.
func _quiescence(pos: ChessPosition, alpha: int, beta: int, ply: int, qdepth: int) -> int:
	nodes += 1
	quiescence_nodes += 1
	if (nodes & 2047) == 0 and (abort or Time.get_ticks_msec() > _deadline):
		_stopped = true
	if _stopped:
		return 0
	var stand_pat := evaluate(pos)
	if stand_pat >= beta or qdepth >= MAX_QUIESCENCE_DEPTH or ply >= MAX_PLY - 1:
		return stand_pat
	if stand_pat > alpha:
		alpha = stand_pat

	var color := pos.side_to_move
	var ordered := _order_moves(pos, pos.generate_pseudo_legal_moves(color, true), ply, 0)
	var best := stand_pat
	for i in range(ordered.size() - 1, -1, -1):
		var m := int(ordered[i] & ChessMove.MOVE_MASK)
		# Delta pruning: a capture that cannot lift the score above alpha is not worth searching.
		var gain: int = PIECE_VALUES[absi(pos.board[(m >> 6) & 63])] + PIECE_VALUES[(m >> 12) & 7]
		if stand_pat + gain + DELTA_PRUNING_MARGIN < alpha:
			continue
		pos.make_move(m)
		if pos.in_check(color):
			pos.unmake_move()
			continue
		var score := -_quiescence(pos, -beta, -alpha, ply + 1, qdepth + 1)
		pos.unmake_move()
		if _stopped:
			return 0
		if score > best:
			best = score
			if score > alpha:
				alpha = score
				if alpha >= beta:
					break
	return best


func _store_killer(ply: int, move: int) -> void:
	var idx := ply * 2
	if _killers[idx] != move:
		_killers[idx + 1] = _killers[idx]
		_killers[idx] = move


## Returns moves packed as (sort_key << 20) | move, sorted ascending; iterate
## from the end to get the most promising moves first. Order: previous best,
## captures by MVV-LVA, promotions, killer moves, then quiet moves by how much
## the piece's square improves.
func _order_moves(pos: ChessPosition, moves: PackedInt32Array, ply: int, hash_move: int) -> PackedInt64Array:
	var ordered := PackedInt64Array()
	ordered.resize(moves.size())
	var board := pos.board
	var white := pos.side_to_move == ChessPosition.WHITE
	var killer1 := _killers[ply * 2]
	var killer2 := _killers[ply * 2 + 1]
	for i in moves.size():
		var m := moves[i]
		var key: int
		if m == hash_move:
			key = ORDER_HASH
		else:
			var from := m & 63
			var to := (m >> 6) & 63
			var promo := (m >> 12) & 7
			var attacker := absi(board[from])
			var victim := absi(board[to])
			if ((m >> 15) & 7) == ChessMove.FLAG_EN_PASSANT:
				victim = ChessPosition.PAWN
			if victim != 0:
				key = ORDER_CAPTURE + PIECE_VALUES[victim] * 8 - attacker + PIECE_VALUES[promo]
			elif promo != 0:
				key = ORDER_PROMOTION + PIECE_VALUES[promo]
			elif m == killer1 or m == killer2:
				key = ORDER_KILLER
			else:
				var pst: PackedInt32Array = _pst[attacker]
				var gain := pst[to ^ 56] - pst[from ^ 56] if white else pst[to] - pst[from]
				key = ORDER_QUIET + gain
		ordered[i] = (key << 20) | m
	ordered.sort()
	return ordered


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

## Static evaluation in centipawns from the side to move's perspective.
func evaluate(pos: ChessPosition) -> int:
	var board := pos.board
	var score := 0  # white's perspective until the last line
	var white_pawn_files := 0  # 4-bit pawn count per file
	var black_pawn_files := 0
	var white_material := 0    # non-pawn, non-king material
	var black_material := 0
	var white_king := 0
	var black_king := 0
	var pst_pawn: PackedInt32Array = _pst[ChessPosition.PAWN]

	for sq in 64:
		var p := board[sq]
		if p == 0:
			continue
		if p > 0:
			if p == ChessPosition.PAWN:
				score += 100 + pst_pawn[sq ^ 56]
				white_pawn_files += 1 << ((sq & 7) * 4)
			elif p == ChessPosition.KING:
				white_king = sq
			else:
				var value: int = PIECE_VALUES[p]
				var pst: PackedInt32Array = _pst[p]
				score += value + pst[sq ^ 56]
				white_material += value
		else:
			var t := -p
			if t == ChessPosition.PAWN:
				score -= 100 + pst_pawn[sq]
				black_pawn_files += 1 << ((sq & 7) * 4)
			elif t == ChessPosition.KING:
				black_king = sq
			else:
				var value: int = PIECE_VALUES[t]
				var pst: PackedInt32Array = _pst[t]
				score -= value + pst[sq]
				black_material += value

	# Kings: hide in the middlegame, centralise in the endgame.
	var endgame := white_material <= ENDGAME_MATERIAL and black_material <= ENDGAME_MATERIAL
	var king_pst: PackedInt32Array = _pst_king_end if endgame else _pst[ChessPosition.KING]
	score += king_pst[white_king ^ 56] - king_pst[black_king]

	# Pawn structure: doubled and isolated pawns.
	for f in 8:
		var wc := (white_pawn_files >> (f * 4)) & 15
		var bc := (black_pawn_files >> (f * 4)) & 15
		if wc > 1:
			score -= DOUBLED_PAWN_PENALTY * (wc - 1)
		if bc > 1:
			score += DOUBLED_PAWN_PENALTY * (bc - 1)
		var neighbours := 0
		if f > 0:
			neighbours |= 15 << ((f - 1) * 4)
		if f < 7:
			neighbours |= 15 << ((f + 1) * 4)
		if wc > 0 and (white_pawn_files & neighbours) == 0:
			score -= ISOLATED_PAWN_PENALTY * wc
		if bc > 0 and (black_pawn_files & neighbours) == 0:
			score += ISOLATED_PAWN_PENALTY * bc

	# King safety: pawns directly in front of the king (middlegame only).
	if not endgame:
		score += KING_SHIELD_BONUS * (_pawn_shield(board, white_king, ChessPosition.WHITE)
				- _pawn_shield(board, black_king, ChessPosition.BLACK))

	# Mobility: how many squares the knights, bishops, rooks and queens can reach.
	if mobility_weight > 0:
		score += mobility_weight * (pos.count_piece_mobility(ChessPosition.WHITE)
				- pos.count_piece_mobility(ChessPosition.BLACK))

	return score if pos.side_to_move == ChessPosition.WHITE else -score


## Evaluation from White's point of view, for the UI.
func evaluate_white_pov(pos: ChessPosition) -> int:
	var e := evaluate(pos)
	return e if pos.side_to_move == ChessPosition.WHITE else -e


static func _pawn_shield(board: PackedInt32Array, king_sq: int, color: int) -> int:
	var rank := (king_sq >> 3) + color
	if rank < 0 or rank > 7:
		return 0
	var file := king_sq & 7
	var pawn := color * ChessPosition.PAWN
	var count := 0
	for f in range(maxi(file - 1, 0), mini(file + 1, 7) + 1):
		if board[rank * 8 + f] == pawn:
			count += 1
	return count
