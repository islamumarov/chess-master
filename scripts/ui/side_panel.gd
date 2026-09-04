class_name SidePanel
extends PanelContainer
## Right-hand panel: status text, captured pieces, move list, buttons and options.
## Purely presentational: buttons become signals, the controller pushes data in.

signal new_game_requested
signal undo_requested
signal flip_requested
signal resign_requested
signal draw_offer_requested
signal copy_fen_requested
signal load_fen_requested(fen: String)
signal depth_changed(depth: int)
signal sound_toggled(enabled: bool)
signal play_as_black_toggled(enabled: bool)

const CAPTURED_ICON_SIZE := 26
const MOVE_NUMBER_COLOR := "#8c8074"

@onready var _status_label: Label = %StatusLabel
@onready var _info_label: Label = %InfoLabel
@onready var _move_list: RichTextLabel = %MoveList
@onready var _captured_by_white: HFlowContainer = %CapturedByWhite
@onready var _captured_by_black: HFlowContainer = %CapturedByBlack
@onready var _undo_button: Button = %UndoButton
@onready var _fen_edit: LineEdit = %FenEdit
@onready var _depth_spin: SpinBox = %DepthSpin


func _ready() -> void:
	%NewGameButton.pressed.connect(func(): new_game_requested.emit())
	_undo_button.pressed.connect(func(): undo_requested.emit())
	%FlipButton.pressed.connect(func(): flip_requested.emit())
	%ResignButton.pressed.connect(func(): resign_requested.emit())
	%DrawButton.pressed.connect(func(): draw_offer_requested.emit())
	%CopyFenButton.pressed.connect(func(): copy_fen_requested.emit())
	%LoadFenButton.pressed.connect(func(): load_fen_requested.emit(_fen_edit.text))
	_fen_edit.text_submitted.connect(func(text: String): load_fen_requested.emit(text))
	_depth_spin.value_changed.connect(func(value: float): depth_changed.emit(int(value)))
	%SoundToggle.toggled.connect(func(on: bool): sound_toggled.emit(on))
	%PlayBlackToggle.toggled.connect(func(on: bool): play_as_black_toggled.emit(on))


func get_depth() -> int:
	return int(_depth_spin.value)


func set_status(text: String, color: Color) -> void:
	_status_label.text = text
	_status_label.add_theme_color_override("font_color", color)


## Secondary line: search statistics, draw-offer replies, FEN feedback.
func set_info(text: String) -> void:
	_info_label.text = text


func set_fen(fen: String) -> void:
	if not _fen_edit.has_focus():
		_fen_edit.text = fen


func set_undo_enabled(enabled: bool) -> void:
	_undo_button.disabled = not enabled


## Renders the move list as numbered pairs; the latest move is bold.
func set_moves(sans: Array[String], first_move_number: int, black_starts: bool) -> void:
	var text := ""
	var number := first_move_number
	var i := 0
	if black_starts and sans.size() > 0:
		text += "%s …  %s\n" % [_number(number), _san_markup(sans, 0)]
		number += 1
		i = 1
	while i < sans.size():
		text += "%s %s" % [_number(number), _san_markup(sans, i)]
		if i + 1 < sans.size():
			text += "   " + _san_markup(sans, i + 1)
		text += "\n"
		number += 1
		i += 2
	_move_list.text = text


func _number(n: int) -> String:
	return "[color=%s]%d.[/color]" % [MOVE_NUMBER_COLOR, n]


func _san_markup(sans: Array[String], index: int) -> String:
	return "[b]%s[/b]" % sans[index] if index == sans.size() - 1 else sans[index]


## Signed piece codes of everything captured so far (black pieces were taken by White).
func set_captured(pieces: PackedInt32Array) -> void:
	var by_white: Array[int] = []
	var by_black: Array[int] = []
	for p in pieces:
		if p < 0:
			by_white.append(p)
		else:
			by_black.append(p)
	# Most valuable first.
	by_white.sort_custom(func(a: int, b: int) -> bool: return absi(a) > absi(b))
	by_black.sort_custom(func(a: int, b: int) -> bool: return absi(a) > absi(b))
	_fill_icons(_captured_by_white, by_white)
	_fill_icons(_captured_by_black, by_black)


func _fill_icons(container: HFlowContainer, pieces: Array[int]) -> void:
	for child in container.get_children():
		child.queue_free()
	for p in pieces:
		var icon := TextureRect.new()
		icon.texture = PieceTextures.get_texture(p)
		icon.custom_minimum_size = Vector2(CAPTURED_ICON_SIZE, CAPTURED_ICON_SIZE)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		container.add_child(icon)
