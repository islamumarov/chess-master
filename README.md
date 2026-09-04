# Chess Master

A complete 2D chess game for **Godot 4.6** (GDScript): you play White (or Black)
against a minimax engine with full chess rules, animated pieces and a dark wood theme.

Open the folder in Godot and press **Play** (`scenes/main.tscn` is the main scene).

## Playing

- **Click** a piece, then click a highlighted square. Green dot = move, red ring = capture.
- Or **drag** a piece onto its target square; dropping anywhere else puts it back.
- Gold = selected piece, blue = last move, pulsing red = king in check.
- Pawn reaching the last rank opens a promotion picker (click outside to cancel).
- Side panel: captured pieces, move list (SAN), **New Game**, **Undo** (takes back your
  move and the reply), **Flip Board**, **Resign**, **Offer Draw** (the AI accepts only when
  it is losing), **Copy FEN**, **Load** a FEN, AI search depth (1–6), sound, **Play as Black**.
- Right-click deselects.

Draws by stalemate, threefold repetition, fifty-move rule and insufficient material are detected.

## Project layout

```
scenes/main.tscn            UI layout (board area, side panel, promotion picker, game-over banner)
scripts/chess/              Rules engine, no scene dependencies
  chess_position.gd         Board state, move generation, make/unmake, check, FEN, Zobrist hashing
  chess_move.gd             Packed-int move encoding helpers
  notation.gd               SAN generation, UCI parsing
scripts/ai/chess_ai.gd      Negamax + alpha-beta, iterative deepening, quiescence, killers, evaluation
scripts/ui/                 game_controller.gd (flow + AI thread), board_view.gd, side_panel.gd,
                            promotion_dialog.gd, piece_textures.gd
assets/pieces/*.svg         Piece set (generated; replace the 12 files to change the look)
assets/sfx/*.wav            Move / capture / check / game-end sounds (generated)
assets/ui/theme.tres        Dark UI theme
tools/gen_assets.py         Regenerates pieces, sounds and the icon (stdlib Python)
tests/perft.gd              Engine self-check; tests/screenshot.gd drives the UI and saves PNGs
docs/superpowers/specs/     Design notes
```

## Tests

```bash
godot --headless --path . --script tests/perft.gd
```

Checks perft node counts on the standard test positions (castling, en passant,
promotions, checks), FEN round-trips, make/unmake integrity, game status, SAN
and that the AI finds forced mates. Add `++ deep` for the slower perft depths.

```bash
godot --path . --script tests/screenshot.gd ++ /absolute/output/dir
```

Plays a scripted game through simulated clicks and saves screenshots (needs a display).

## Engine notes

- Board is a 64-int array (`color * piece_type`), moves are packed ints, undo records are
  packed int64s: the search never allocates objects, which keeps GDScript fast enough for
  depth 3 in well under a second and depth 4 in a few seconds.
- Evaluation: material, piece-square tables (middlegame/endgame king tables), doubled and
  isolated pawns, pawn shield in front of the king, piece mobility.
- The AI searches a copy of the position on a worker thread; the UI stays responsive and
  Undo / New Game abort the search.
- Extending: a transposition table keyed by `ChessPosition.hash` is the natural next step
  for depth 5+; an opening book can pick moves before calling `ChessAI.find_best_move`.
