class_name PromotionDialog
extends Control
## Overlay asking which piece a pawn promotes to. Clicking outside the panel cancels.

signal piece_chosen(piece_type: int)
signal cancelled

const TYPES := [ChessPosition.QUEEN, ChessPosition.ROOK, ChessPosition.BISHOP, ChessPosition.KNIGHT]
const HOVER_TINT := Color(1.2, 1.2, 1.2)

@onready var _buttons: Array[TextureButton] = [%PromoQueen, %PromoRook, %PromoBishop, %PromoKnight]


func _ready() -> void:
	hide()
	for i in _buttons.size():
		var button := _buttons[i]
		button.pressed.connect(_on_button_pressed.bind(TYPES[i]))
		button.mouse_entered.connect(func(): button.modulate = HOVER_TINT)
		button.mouse_exited.connect(func(): button.modulate = Color.WHITE)


## Shows the four promotion pieces in the given color.
func open(color: int) -> void:
	for i in _buttons.size():
		_buttons[i].texture_normal = PieceTextures.get_texture(color * TYPES[i])
		_buttons[i].modulate = Color.WHITE
	show()


func _on_button_pressed(piece_type: int) -> void:
	hide()
	piece_chosen.emit(piece_type)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		accept_event()
		hide()
		cancelled.emit()
