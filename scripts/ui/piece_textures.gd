class_name PieceTextures
## Loads and caches the piece sprites. Files follow the common naming
## convention `wK.svg`, `bP.svg`, ... so any standard piece set can be dropped
## into assets/pieces/ without code changes.

const PIECE_DIR := "res://assets/pieces/"
const LETTERS := ".PNBRQK"

static var _cache := {}


## Texture for a signed piece code (ChessPosition convention), or null for empty.
static func get_texture(piece: int) -> Texture2D:
	if piece == 0:
		return null
	if not _cache.has(piece):
		var color := "w" if piece > 0 else "b"
		_cache[piece] = load(PIECE_DIR + color + LETTERS[absi(piece)] + ".svg")
	return _cache[piece]
