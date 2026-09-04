class_name ChessMove
## Helpers for the packed-integer move representation used by the engine.
##
## A move is a single int so move generation and search never allocate objects
## (object allocation is the slowest thing GDScript does in a hot loop):
##
##   bits  0-5  : from square (0 = a1 ... 63 = h8)
##   bits  6-11 : to square
##   bits 12-14 : promotion piece type (0 = none, else ChessPosition.KNIGHT..QUEEN)
##   bits 15-17 : special flag (FLAG_* below)
##
## A value of 0 (a1 -> a1) is never a real move and is used as "no move".

const FLAG_NONE := 0
const FLAG_DOUBLE_PUSH := 1  ## Pawn two-square advance (sets the en passant square).
const FLAG_EN_PASSANT := 2   ## Pawn captures en passant (captured pawn is not on `to`).
const FLAG_CASTLE := 3       ## King castles; the rook moves too.

const MOVE_BITS := 18
const MOVE_MASK := (1 << MOVE_BITS) - 1

const FILES := "abcdefgh"
const PROMOTION_LETTERS := "--nbrq"  # indexed by piece type


static func make(from_sq: int, to_sq: int, promotion: int = 0, flag: int = FLAG_NONE) -> int:
	return from_sq | (to_sq << 6) | (promotion << 12) | (flag << 15)


static func from_sq(move: int) -> int:
	return move & 63


static func to_sq(move: int) -> int:
	return (move >> 6) & 63


static func promotion(move: int) -> int:
	return (move >> 12) & 7


static func flag(move: int) -> int:
	return (move >> 15) & 7


static func square_name(sq: int) -> String:
	return FILES[sq & 7] + str((sq >> 3) + 1)


## "e4" -> 28. Returns -1 for malformed input.
static func square_from_name(name: String) -> int:
	if name.length() != 2:
		return -1
	var file := FILES.find(name[0])
	var rank := int(name[1]) - 1
	if file < 0 or rank < 0 or rank > 7:
		return -1
	return rank * 8 + file


## Long algebraic / UCI form, e.g. "e2e4", "e7e8q".
static func to_uci(move: int) -> String:
	var s := square_name(from_sq(move)) + square_name(to_sq(move))
	var promo := promotion(move)
	if promo != 0:
		s += PROMOTION_LETTERS[promo]
	return s
