@tool
extends EditorPlugin
## SFX Kit editor plugin: the sounds folder setting and a Tools menu entry that runs SFX Studio.
## SfxLibrary / SfxSynth / SfxPlayer work without the plugin.

const APP := "res://addons/sfx_kit/app/sfx_studio.tscn"
const SETTING := "sfx_kit/sounds_dir"


func _enter_tree() -> void:
	if not ProjectSettings.has_setting(SETTING):
		ProjectSettings.set_setting(SETTING, "res://sfx")
	ProjectSettings.set_initial_value(SETTING, "res://sfx")
	ProjectSettings.add_property_info({"name": SETTING, "type": TYPE_STRING, "hint": PROPERTY_HINT_DIR})
	add_tool_menu_item("Open SFX Studio", _open)


func _exit_tree() -> void:
	remove_tool_menu_item("Open SFX Studio")


func _open() -> void:
	EditorInterface.play_custom_scene(APP)
