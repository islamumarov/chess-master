class_name ChessNotation
## Standard Algebraic Notation (SAN) for the move list, plus UCI parsing for tests.


## SAN for `move`, which must be legal in `pos`. Call BEFORE making the move.
## The position is temporarily modified to test for check/mate, then restored.
static func to_san(pos: ChessPosition, move: int) -> String:
	var from := ChessMove.from_sq(move)
	var to := ChessMove.to_sq(move)
	var promo := ChessMove.promotion(move)
	var flag := ChessMove.flag(move)
	var piece_type := absi(pos.board[from])
	var san := ""

	if flag == ChessMove.FLAG_CASTLE:
		san = "O-O" if (to & 7) == 6 else "O-O-O"
	else:
		var is_capture := pos.board[to] != 0 or flag == ChessMove.FLAG_EN_PASSANT
		if piece_type == ChessPosition.PAWN:
			if is_capture:
				san += ChessMove.FILES[from & 7]
		else:
			san += ChessPosition.PIECE_LETTERS[piece_type]
			san += _disambiguation(pos, move, piece_type)
		if is_capture:
			san += "x"
		san += ChessMove.square_name(to)
		if promo != 0:
			san += "=" + ChessPosition.PIECE_LETTERS[promo]

	# Check / checkmate suffix.
	pos.make_move(move)
	if pos.in_check(pos.side_to_move):
		san += "#" if pos.generate_legal_moves().is_empty() else "+"
	pos.unmake_move()
	return san


## File, rank or both, when another piece of the same type could also reach `to`.
static func _disambiguation(pos: ChessPosition, move: int, piece_type: int) -> String:
	var from := ChessMove.from_sq(move)
	var to := ChessMove.to_sq(move)
	var same_file := false
	var same_rank := false
	var ambiguous := false
	for other in pos.generate_legal_moves():
		var other_from := ChessMove.from_sq(other)
		if other_from == from or ChessMove.to_sq(other) != to:
			continue
		if absi(pos.board[other_from]) != piece_type:
			continue
		ambiguous = true
		if (other_from & 7) == (from & 7):
			same_file = true
		if (other_from >> 3) == (from >> 3):
			same_rank = true
	if not ambiguous:
		return ""
	if not same_file:
		return ChessMove.FILES[from & 7]
	if not same_rank:
		return str((from >> 3) + 1)
	return ChessMove.square_name(from)


## Finds the legal move matching a UCI string such as "e2e4" or "e7e8q"; 0 if none.
static func move_from_uci(pos: ChessPosition, uci: String) -> int:
	for m in pos.generate_legal_moves():
		if ChessMove.to_uci(m) == uci:
			return m
	return 0
