extends Node
## Driver for tests/screenshot.gd: loads the main scene, clicks through a few
## moves, a promotion and a checkmate, saving a PNG after each stage.

var out_dir := "user://"
var _main: Control
var _board: BoardView


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		out_dir = args[0]
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child(_main)
	_board = _main.get_node("%BoardView")
	await _run()
	get_tree().quit()


func _run() -> void:
	await _wait(0.6)
	_click_square(12)  # e2: select
	await _wait(0.4)
	await _shot("01_selection")
	_click_square(28)  # e4: move, AI replies
	await _wait(2.5)
	_click_square(6)   # g1
	await _wait(0.3)
	_click_square(21)  # f3
	await _wait(2.5)
	_click_square(3)   # d1: queen selected, several legal targets
	await _wait(0.4)
	await _shot("02_midgame")

	_main.load_fen("8/P7/8/8/8/8/8/k6K w - - 0 1")
	await _wait(0.4)
	_click_square(48)  # a7
	await _wait(0.3)
	_click_square(56)  # a8: promotion dialog opens
	await _wait(0.4)
	await _shot("03_promotion")
	_click_control(_main.get_node("%PromoQueen"))
	await _wait(0.8)
	await _shot("04_promoted")

	_main.load_fen("6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1")
	await _wait(0.4)
	_click_square(0)   # a1
	await _wait(0.3)
	_click_square(56)  # a8: checkmate
	await _wait(1.2)
	await _shot("05_checkmate")

	_main.flip_board()
	_main.undo()
	await _wait(0.5)
	await _shot("06_flipped_after_undo")


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := out_dir.path_join(name + ".png")
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("screenshot %s -> %s (%s)" % [name, path, error_string(err)])


func _click_square(sq: int) -> void:
	_click_at(_board.get_global_rect().position + _board.square_rect(sq).get_center())


func _click_control(control: Control) -> void:
	_click_at(control.get_global_rect().get_center())


func _click_at(point: Vector2) -> void:
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point
	press.global_position = point
	get_viewport().push_input(press, true)
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	get_viewport().push_input(release, true)
