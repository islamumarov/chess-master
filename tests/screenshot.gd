extends SceneTree
## Visual smoke test: plays a scripted sequence through the real UI (simulated
## clicks) and saves screenshots. Needs a display, so not --headless:
##
##   godot --path . --script tests/screenshot.gd ++ /absolute/output/dir


func _init() -> void:
	var helper := Node.new()
	helper.set_script(load("res://tests/screenshot_helper.gd"))
	root.add_child.call_deferred(helper)
