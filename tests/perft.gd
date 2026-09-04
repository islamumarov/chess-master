extends SceneTree
## Engine self-check: perft node counts (castling, en passant, promotion,
## checks), FEN round-trips, make/unmake integrity, game status, SAN and a
## mate-in-one for the AI. No test framework needed.
##
##   godot --headless --path . --script tests/perft.gd           # ~10 s
##   godot --headless --path . --script tests/perft.gd ++ deep   # deeper perft, ~1 min
##
## Exit code 0 = all passed.

const FAST_LEAF_LIMIT := 10_000  # skip perft cases with more leaves unless "deep"

# [name, fen, expected leaf counts for depth 1, 2, 3, ...] — chessprogramming.org/Perft_Results
const PERFT_CASES := [
	["start position", ChessPosition.START_FEN, [20, 400, 8902, 197281]],
	["kiwipete", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", [48, 2039, 97862]],
	["position 3 (en passant, checks)", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", [14, 191, 2812, 43238]],
	["position 4 (promotions, castling)", "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", [6, 264, 9467]],
	["position 4 mirrored", "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1", [6, 264, 9467]],
	["position 5", "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", [44, 1486, 62379]],
	["position 6", "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", [46, 2079, 89890]],
]

var failures := 0


func _init() -> void:
	var deep := "deep" in OS.get_cmdline_user_args()
	var t0 := Time.get_ticks_msec()
	_test_perft(deep)
	_test_fen_roundtrip()
	_test_make_unmake()
	_test_game_status()
	_test_san()
	_test_ai()
	var verdict := "OK" if failures == 0 else "FAILED"
	print("\n%s — %d failure(s) in %.1f s" % [verdict, failures, (Time.get_ticks_msec() - t0) / 1000.0])
	quit(1 if failures > 0 else 0)


func _check(name: String, got: Variant, expected: Variant) -> void:
	if got == expected:
		print("  ok    %s" % name)
	else:
		failures += 1
		printerr("  FAIL  %s: got %s, expected %s" % [name, got, expected])


func perft(pos: ChessPosition, depth: int) -> int:
	var moves := pos.generate_legal_moves()
	if depth <= 1:
		return moves.size()
	var count := 0
	for m in moves:
		pos.make_move(m)
		count += perft(pos, depth - 1)
		pos.unmake_move()
	return count


func _test_perft(deep: bool) -> void:
	print("perft")
	for c in PERFT_CASES:
		var pos := ChessPosition.new()
		_check("load '%s'" % c[0], pos.load_fen(c[1]), true)
		var expected: Array = c[2]
		for depth in expected.size():
			if expected[depth] > FAST_LEAF_LIMIT and not deep:
				continue
			var t := Time.get_ticks_msec()
			var got := perft(pos, depth + 1)
			_check("%s depth %d (%d ms)" % [c[0], depth + 1, Time.get_ticks_msec() - t], got, expected[depth])


func _test_fen_roundtrip() -> void:
	print("fen")
	for c in PERFT_CASES:
		var pos := ChessPosition.new()
		pos.load_fen(c[1])
		_check("round-trip %s" % c[0], pos.to_fen(), c[1])
	var pos := ChessPosition.new()
	_check("reject missing king", pos.load_fen("8/8/8/8/8/8/8/K7 w - - 0 1"), false)
	_check("reject garbage", pos.load_fen("hello"), false)
	_check("untouched after bad load", pos.to_fen(), ChessPosition.START_FEN)
	pos.load_fen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
	pos.make_move(ChessNotation.move_from_uci(pos, "e1g1"))
	_check("castling updates fen", pos.to_fen(), "r3k2r/8/8/8/8/8/8/R4RK1 b kq - 1 1")
	pos.load_fen("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")
	pos.make_move(ChessNotation.move_from_uci(pos, "e2e4"))
	_check("double push sets ep square", pos.to_fen(), "4k3/8/8/8/4P3/8/8/4K3 b - e3 0 1")
	pos.load_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w Kk - 0 1")
	_check("drops rights contradicted by placement", pos.castling, ChessPosition.CASTLE_WK | ChessPosition.CASTLE_BK)


func _test_make_unmake() -> void:
	print("make/unmake")
	var pos := ChessPosition.new()
	pos.load_fen(PERFT_CASES[1][1])
	var original_fen := pos.to_fen()
	var original_hash := pos.hash
	var hash_ok := true
	var plies := 0
	# Walk a deterministic line 40 plies deep, checking the incremental hash at every step.
	while plies < 40:
		var moves := pos.generate_legal_moves()
		if moves.is_empty():
			break
		pos.make_move(moves[(plies * 7) % moves.size()])
		plies += 1
		if pos.hash != pos.compute_hash():
			hash_ok = false
	_check("incremental hash matches recomputed hash over %d plies" % plies, hash_ok, true)
	for i in plies:
		pos.unmake_move()
	_check("unmake restores fen", pos.to_fen(), original_fen)
	_check("unmake restores hash", pos.hash, original_hash)
	_check("unmake empties move stack", pos.ply_count(), 0)
	# Mobility counter must agree with the generator for knights and sliders.
	for color in [ChessPosition.WHITE, ChessPosition.BLACK]:
		var expected := 0
		for m in pos.generate_pseudo_legal_moves(color):
			var t := absi(pos.board[ChessMove.from_sq(m)])
			if t != ChessPosition.PAWN and t != ChessPosition.KING:
				expected += 1
		_check("piece mobility count (color %d)" % color, pos.count_piece_mobility(color), expected)


func _test_game_status() -> void:
	print("game status")
	var pos := ChessPosition.new()
	pos.load_fen("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
	_check("fool's mate is checkmate", pos.get_game_status(), ChessPosition.Status.CHECKMATE)
	_check("fool's mate side is in check", pos.in_check(), true)
	pos.load_fen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
	_check("stalemate", pos.get_game_status(), ChessPosition.Status.STALEMATE)
	pos.load_fen("8/8/8/4k3/8/8/8/4K2N w - - 0 1")
	_check("K+N vs K is insufficient material", pos.get_game_status(), ChessPosition.Status.DRAW_INSUFFICIENT_MATERIAL)
	pos.load_fen("8/8/8/4k3/8/8/8/4K2R w - - 0 1")
	_check("K+R vs K is not insufficient", pos.get_game_status(), ChessPosition.Status.ONGOING)
	pos.load_fen("8/8/8/4k3/8/8/8/4K2R w - - 100 60")
	_check("fifty-move rule", pos.get_game_status(), ChessPosition.Status.DRAW_FIFTY_MOVES)
	pos.load_fen(ChessPosition.START_FEN)
	for uci in ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1"]:
		pos.make_move(ChessNotation.move_from_uci(pos, uci))
	_check("not yet threefold", pos.get_game_status(), ChessPosition.Status.ONGOING)
	pos.make_move(ChessNotation.move_from_uci(pos, "f6g8"))
	_check("threefold repetition", pos.get_game_status(), ChessPosition.Status.DRAW_REPETITION)
	var captured := pos.get_captured_pieces()
	pos.load_fen("4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1")
	pos.make_move(ChessNotation.move_from_uci(pos, "e4d5"))
	captured = pos.get_captured_pieces()
	_check("captured pieces tracked", Array(captured), [-ChessPosition.PAWN])


func _test_san() -> void:
	print("san")
	_check_san(ChessPosition.START_FEN, "e2e4", "e4")
	_check_san("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", "e1g1", "O-O")
	_check_san("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", "e1c1", "O-O-O")
	_check_san("4k3/8/8/8/8/8/8/1N1K1N2 w - - 0 1", "b1d2", "Nbd2")
	_check_san("4k3/8/8/8/8/8/8/1N1K1N2 w - - 0 1", "f1d2", "Nfd2")
	_check_san("4k3/8/8/8/R7/8/8/R3K3 w - - 0 1", "a1a2", "R1a2")
	_check_san("4k3/8/8/3p4/4P3/8/8/4K3 w - - 0 1", "e4d5", "exd5")
	_check_san("4k3/8/8/8/8/8/8/R3K3 w - - 0 1", "a1a8", "Ra8+")
	_check_san("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1", "a1a8", "Ra8#")
	_check_san("8/P7/8/8/8/8/8/k6K w - - 0 1", "a7a8q", "a8=Q+")
	_check_san("8/P7/8/8/8/8/8/k6K w - - 0 1", "a7a8n", "a8=N")
	_check_san("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1", "e5d6", "exd6")


func _check_san(fen: String, uci: String, expected: String) -> void:
	var pos := ChessPosition.new()
	pos.load_fen(fen)
	var move := ChessNotation.move_from_uci(pos, uci)
	if move == 0:
		failures += 1
		printerr("  FAIL  san %s: move %s is not legal" % [expected, uci])
		return
	var fen_before := pos.to_fen()
	_check("san %s" % expected, ChessNotation.to_san(pos, move), expected)
	if pos.to_fen() != fen_before:
		failures += 1
		printerr("  FAIL  to_san modified the position")


func _test_ai() -> void:
	print("ai")
	var ai := ChessAI.new()
	var pos := ChessPosition.new()
	pos.load_fen("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")
	ai.max_depth = 3
	_check("finds mate in one", ChessMove.to_uci(ai.find_best_move(pos)), "a1a8")
	pos.load_fen("r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4")
	_check("finds scholar's mate", ChessMove.to_uci(ai.find_best_move(pos)), "h5f7")
	pos.load_fen("4k3/8/8/8/8/8/8/4K2R w K - 0 1")
	ai.max_depth = 2
	var m := ai.find_best_move(pos)
	_check("returns a legal move", m in Array(pos.generate_legal_moves()), true)
	# Benchmark: opening position at the default depth (prints, no assertion).
	pos.load_fen("r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 3 2")
	for depth in [3, 4]:
		ai.max_depth = depth
		ai.time_limit_msec = 60_000
		var best := ai.find_best_move(pos)
		print("  bench depth %d: %s score %d, %d nodes in %d ms" % [depth, ChessMove.to_uci(best), ai.best_score, ai.nodes, ai.elapsed_msec])
