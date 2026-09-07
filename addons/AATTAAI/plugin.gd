@tool
extends EditorPlugin

# Inner class for rendering the coordinate & floor grid in preview viewport
class AATTAIPreviewGrid extends Node2D:
	var show_grid: bool = true:
		set(v):
			show_grid = v
			queue_redraw()
	var grid_size: int = 64
	var grid_color: Color = Color(1.0, 1.0, 1.0, 0.08)
	var sub_grid_color: Color = Color(1.0, 1.0, 1.0, 0.03)
	var axis_color_x: Color = Color(0.9, 0.35, 0.35, 0.65) # Red Floor (X Axis)
	var axis_color_y: Color = Color(0.35, 0.85, 0.35, 0.65) # Green Center (Y Axis)

	func _draw() -> void:
		if not show_grid: return
		var extent := 4000.0
		var half_grid := grid_size / 2
		
		# Sub-grid lines (32px)
		var sub_count := int(extent / half_grid)
		for i in range(-sub_count, sub_count + 1):
			var pos := float(i * half_grid)
			if int(pos) % grid_size == 0: continue
			draw_line(Vector2(-extent, pos), Vector2(extent, pos), sub_grid_color, 1.0)
			draw_line(Vector2(pos, -extent), Vector2(pos, extent), sub_grid_color, 1.0)
			
		# Main grid lines (64px)
		var count := int(extent / grid_size)
		for i in range(-count, count + 1):
			var pos := float(i * grid_size)
			if pos == 0.0: continue
			draw_line(Vector2(-extent, pos), Vector2(extent, pos), grid_color, 1.0)
			draw_line(Vector2(pos, -extent), Vector2(pos, extent), grid_color, 1.0)
		
		# Origin Axes
		draw_line(Vector2(-extent, 0), Vector2(extent, 0), axis_color_x, 1.5)
		draw_line(Vector2(0, -extent), Vector2(0, extent), axis_color_y, 1.5)
		
		# Origin Pivot Marker
		draw_circle(Vector2.ZERO, 3.5, Color(1.0, 1.0, 1.0, 0.9))
		draw_arc(Vector2.ZERO, 6.0, 0, TAU, 16, Color(1.0, 0.8, 0.2, 0.8), 1.2)

var _import_dialog: Window
var _interp_dialog: Window
var _atlas_edit: LineEdit
var _folder_edit: LineEdit
var _png_edit: LineEdit
var _out_edit: LineEdit
var _fps_spin: SpinBox
var _status_lbl: Label
var _btn_import: Button
var _btn_update: Button

var _atlas_val_lbl: Label
var _folder_val_lbl: Label
var _png_val_lbl: Label

# Animation Checklist & Search Controls
var _anim_title_lbl: Label
var _anim_search_edit: LineEdit
var _anim_container: GridContainer
var _anim_checkboxes: Dictionary = {}
var _btn_select_all: Button
var _btn_deselect_all: Button
var _btn_select_filtered: Button
var _last_scanned_folder: String = ""

# Controls
var _swapper_check: CheckBox
var _filter_option: OptionButton
var _interp_option: OptionButton

# Preview panel variables
var _preview_viewport: SubViewport
var _preview_grid: Node2D
var _grid_btn: Button
var _loop_btn: Button
var _preview_node: Node2D
var _preview_player: AnimationPlayer
var _play_btn: Button
var _anim_option: OptionButton
var _scrub_slider: HSlider
var _preview_timer: Timer
var _preview_debounce_timer: Timer
var _is_scrubbing := false
var _is_updating_slider := false
var _was_playing_before_scrub := false

const SETTINGS_PATH = "res://.godot/aattaai_settings.cfg"

func _enter_tree() -> void:
	add_tool_menu_item("Import Adobe Animate...", _on_import_menu_pressed)
	add_tool_menu_item("Batch Set Animation Interpolation...", _on_interp_tool_pressed)
	print("[AdobeAnimateImporter] Plugin loaded.")

func _exit_tree() -> void:
	remove_tool_menu_item("Import Adobe Animate...")
	remove_tool_menu_item("Batch Set Animation Interpolation...")
	if _import_dialog:
		_import_dialog.queue_free()
		_import_dialog = null
	if _interp_dialog:
		_interp_dialog.queue_free()
		_interp_dialog = null

func _on_import_menu_pressed() -> void:
	if not _import_dialog:
		_import_dialog = _build_dialog()
		get_editor_interface().get_base_control().add_child(_import_dialog)
	
	_last_scanned_folder = ""
	_populate_from_selection()
	_validate_all()
	_import_dialog.popup_centered(Vector2i(1080, 640))

func _on_interp_tool_pressed() -> void:
	if not _interp_dialog:
		_interp_dialog = _build_interp_dialog()
		get_editor_interface().get_base_control().add_child(_interp_dialog)
	
	_interp_dialog.popup_centered(Vector2i(650, 420))

func _populate_from_selection() -> void:
	if not get_editor_interface():
		return
	var selected_paths := get_editor_interface().get_selected_paths()
	if selected_paths.is_empty():
		return
	
	for path in selected_paths:
		if path.ends_with(".json"):
			var fname := path.get_file().to_lower()
			if fname.contains("spritemap") or fname.contains("atlas") or fname.contains("spritesheet"):
				_atlas_edit.text = path
				_auto_predict_from_atlas(path)
			else:
				_folder_edit.text = path.get_base_dir()
		elif path.ends_with(".png"):
			_png_edit.text = path
			if _atlas_edit.text.strip_edges().is_empty():
				var predicted_atlas := path.get_base_dir().path_join(path.get_file().get_basename() + ".json")
				if FileAccess.file_exists(predicted_atlas):
					_atlas_edit.text = predicted_atlas
					_auto_predict_from_atlas(predicted_atlas)
		elif DirAccess.dir_exists_absolute(path):
			_folder_edit.text = path

func _auto_predict_from_atlas(atlas_path: String) -> void:
	if atlas_path.is_empty():
		return
	var base_dir := atlas_path.get_base_dir()
	var atlas_basename := atlas_path.get_file().get_basename()
	
	# 1. Predict PNG
	var predicted_png := base_dir.path_join(atlas_basename + ".png")
	if FileAccess.file_exists(predicted_png):
		_png_edit.text = predicted_png
	else:
		var spritemap_png := base_dir.path_join("spritemap1.png")
		if FileAccess.file_exists(spritemap_png):
			_png_edit.text = spritemap_png
		else:
			var dir := DirAccess.open(base_dir)
			if dir != null:
				dir.list_dir_begin()
				var f := dir.get_next()
				var pngs := []
				while f != "":
					if not dir.current_is_dir() and f.ends_with(".png"):
						pngs.append(f)
					f = dir.get_next()
				dir.list_dir_end()
				if pngs.size() == 1:
					_png_edit.text = base_dir.path_join(pngs[0])
				elif pngs.size() > 1:
					_png_edit.text = base_dir.path_join(pngs[0])

	# 2. Predict Animation Folder
	var predicted_anim_folder := base_dir.path_join("animations")
	if DirAccess.dir_exists_absolute(predicted_anim_folder) or DirAccess.open(predicted_anim_folder) != null:
		_folder_edit.text = predicted_anim_folder
	else:
		predicted_anim_folder = base_dir.path_join("animation")
		if DirAccess.dir_exists_absolute(predicted_anim_folder) or DirAccess.open(predicted_anim_folder) != null:
			_folder_edit.text = predicted_anim_folder
		else:
			_folder_edit.text = base_dir
	_last_scanned_folder = ""

	# 3. Predict Output Scene Path
	var character_name := "imported_character"
	if atlas_basename != "spritemap1" and atlas_basename != "spritesheet" and atlas_basename != "atlas":
		character_name = atlas_basename
	_out_edit.text = base_dir.path_join(character_name + ".tscn")

func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("settings", "atlas_path", _atlas_edit.text.strip_edges())
	config.set_value("settings", "folder_path", _folder_edit.text.strip_edges())
	config.set_value("settings", "png_path", _png_edit.text.strip_edges())
	config.set_value("settings", "out_path", _out_edit.text.strip_edges())
	config.set_value("settings", "fps_override", int(_fps_spin.value))
	config.set_value("settings", "add_swapper", _swapper_check.button_pressed)
	config.set_value("settings", "filter_mode", _filter_option.selected)
	if _interp_option:
		config.set_value("settings", "interp_mode", _interp_option.selected)
	if _grid_btn:
		config.set_value("settings", "show_grid", _grid_btn.button_pressed)
	if _loop_btn:
		config.set_value("settings", "preview_loop", _loop_btn.button_pressed)
	
	var dir := DirAccess.open("res://")
	if dir != null and not dir.dir_exists(".godot"):
		dir.make_dir(".godot")
	config.save(SETTINGS_PATH)

func _load_settings() -> Dictionary:
	var res := {
		"atlas_path": "",
		"folder_path": "",
		"png_path": "",
		"out_path": "res://imported_character.tscn",
		"fps_override": 0,
		"add_swapper": true,
		"filter_mode": 0,
		"interp_mode": 0,
		"show_grid": true,
		"preview_loop": true
	}
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		res["atlas_path"] = config.get_value("settings", "atlas_path", "")
		res["folder_path"] = config.get_value("settings", "folder_path", "")
		res["png_path"] = config.get_value("settings", "png_path", "")
		res["out_path"] = config.get_value("settings", "out_path", "res://imported_character.tscn")
		res["fps_override"] = int(config.get_value("settings", "fps_override", 0))
		res["add_swapper"] = config.get_value("settings", "add_swapper", true)
		res["filter_mode"] = config.get_value("settings", "filter_mode", 0)
		res["interp_mode"] = config.get_value("settings", "interp_mode", 0)
		res["show_grid"] = config.get_value("settings", "show_grid", true)
		res["preview_loop"] = config.get_value("settings", "preview_loop", true)
	return res

func _validate_all() -> void:
	if not _atlas_edit: return
	var atlas_ok := false
	var folder_ok := false
	var png_ok := false
	
	# Validate Atlas
	var atlas_path := _atlas_edit.text.strip_edges()
	if atlas_path.is_empty():
		_atlas_val_lbl.text = "❌ No file selected."
		_atlas_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	elif not FileAccess.file_exists(atlas_path):
		_atlas_val_lbl.text = "❌ File does not exist."
		_atlas_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	elif not atlas_path.ends_with(".json"):
		_atlas_val_lbl.text = "⚠️ Must be a .json file."
		_atlas_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	else:
		_atlas_val_lbl.text = "✅ File exists."
		_atlas_val_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
		atlas_ok = true

	# Validate PNG
	var png_path := _png_edit.text.strip_edges()
	if png_path.is_empty():
		_png_val_lbl.text = "❌ No file selected."
		_png_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	elif not FileAccess.file_exists(png_path):
		_png_val_lbl.text = "❌ File does not exist."
		_png_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	elif not png_path.ends_with(".png"):
		_png_val_lbl.text = "⚠️ Must be a .png file."
		_png_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	else:
		_png_val_lbl.text = "✅ File exists."
		_png_val_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
		png_ok = true

	# Validate Folder/File & update animation checklist
	var folder_path := _folder_edit.text.strip_edges()
	_update_animation_checklist(folder_path)
	
	var total_count := _anim_checkboxes.size()
	if folder_path.is_empty():
		_folder_val_lbl.text = "❌ No file or folder selected."
		_folder_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	elif total_count == 0:
		_folder_val_lbl.text = "⚠️ No animation JSON files found."
		_folder_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.4))
	else:
		_folder_val_lbl.text = "✅ Found %d animation(s)." % total_count
		_folder_val_lbl.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
		folder_ok = true

	_update_action_buttons_state(atlas_ok, folder_ok, png_ok)

func _update_action_buttons_state(atlas_ok: bool, folder_ok: bool, png_ok: bool) -> void:
	var selected_anims := _get_selected_animations()
	var has_selected := not selected_anims.is_empty()
	var out_path := _out_edit.text.strip_edges()
	var out_exists := FileAccess.file_exists(out_path)

	if _anim_title_lbl:
		_anim_title_lbl.text = "📋 Animations (%d/%d selected):" % [selected_anims.size(), _anim_checkboxes.size()]

	if _btn_import:
		_btn_import.disabled = not (atlas_ok and folder_ok and png_ok and has_selected)
	if _btn_update:
		_btn_update.disabled = not (atlas_ok and folder_ok and png_ok and has_selected and out_exists)
		if out_exists:
			_btn_update.text = "🔄 Update Scene (%s)" % out_path.get_file()
		else:
			_btn_update.text = "🔄 Update Existing Scene"

	if atlas_ok and folder_ok and png_ok and has_selected:
		_request_preview_update()
	else:
		_clear_preview()

func _update_animation_checklist(folder_path: String) -> void:
	if not _anim_container: return
	var clean_path := folder_path.replace("\\", "/").strip_edges()
	if clean_path == _last_scanned_folder and not _anim_checkboxes.is_empty():
		return
	_last_scanned_folder = clean_path

	for child in _anim_container.get_children():
		_anim_container.remove_child(child)
		child.queue_free()
	_anim_checkboxes.clear()

	if clean_path.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "(Select folder/file to list animations)"
		empty_lbl.add_theme_color_override("font_color", Color(0.5, 0.7, 0.9))
		_anim_container.add_child(empty_lbl)
		return

	var importer = load("res://addons/AATTAAI/importer.gd").new()
	var anim_list: Array = importer.get_available_animations(clean_path)

	if anim_list.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No animation JSON files found in this path."
		empty_lbl.add_theme_color_override("font_color", Color(1.0, 0.7, 0.4))
		_anim_container.add_child(empty_lbl)
		return

	for anim_name in anim_list:
		var cb := CheckBox.new()
		cb.text = anim_name
		cb.button_pressed = true
		cb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_anim_container.add_child(cb)
		_anim_checkboxes[anim_name] = cb
		cb.toggled.connect(func(_t: bool):
			_on_anim_selection_changed()
		)
	
	if _anim_search_edit and not _anim_search_edit.text.is_empty():
		_filter_animation_checkboxes(_anim_search_edit.text)

func _filter_animation_checkboxes(query: String) -> void:
	var q := query.strip_edges().to_lower()
	for anim_name in _anim_checkboxes:
		var cb: CheckBox = _anim_checkboxes[anim_name]
		if is_instance_valid(cb):
			if q.is_empty() or q in anim_name.to_lower():
				cb.visible = true
			else:
				cb.visible = false

func _get_selected_animations() -> Array:
	var res: Array = []
	for anim_name in _anim_checkboxes:
		var cb: CheckBox = _anim_checkboxes[anim_name]
		if is_instance_valid(cb) and cb.button_pressed:
			res.append(anim_name)
	return res

func _on_anim_selection_changed() -> void:
	var selected := _get_selected_animations()
	var has_selected := not selected.is_empty()
	var out_path := _out_edit.text.strip_edges()
	var out_exists := FileAccess.file_exists(out_path)

	var atlas_path := _atlas_edit.text.strip_edges()
	var png_path := _png_edit.text.strip_edges()
	var folder_path := _folder_edit.text.strip_edges()
	var folder_ok := (not folder_path.is_empty()) and (FileAccess.file_exists(folder_path) or DirAccess.dir_exists_absolute(folder_path))
	var files_ok = FileAccess.file_exists(atlas_path) and FileAccess.file_exists(png_path) and folder_ok

	if _anim_title_lbl:
		_anim_title_lbl.text = "📋 Animations (%d/%d selected):" % [selected.size(), _anim_checkboxes.size()]

	_btn_import.disabled = not (files_ok and has_selected)
	if _btn_update:
		_btn_update.disabled = not (files_ok and has_selected and out_exists)

	if has_selected:
		_request_preview_update()
	else:
		_clear_preview()

func _clear_preview() -> void:
	if _preview_node:
		_preview_node.queue_free()
		_preview_node = null
	_preview_player = null
	if _anim_option:
		_anim_option.clear()
	if _play_btn:
		_play_btn.text = "⏸️ Pause"

func _request_preview_update() -> void:
	if _preview_debounce_timer:
		_preview_debounce_timer.start(0.2)

func _get_interp_mode_str() -> String:
	if not _interp_option: return "Linear"
	match _interp_option.selected:
		1: return "Nearest"
		2: return "Cubic"
		_: return "Linear"

func _update_preview() -> void:
	_clear_preview()
	
	var atlas_path := _atlas_edit.text.strip_edges()
	var folder_path := _folder_edit.text.strip_edges()
	var png_path := _png_edit.text.strip_edges()
	var fps_val := int(_fps_spin.value)
	var use_pivot := true
	var add_swapper := _swapper_check.button_pressed
	var filter_idx := _filter_option.selected
	var filter_mode := "Linear" if filter_idx == 0 else "Nearest"
	var interp_mode := _get_interp_mode_str()
	var selected_anims := _get_selected_animations()

	if atlas_path.is_empty() or folder_path.is_empty() or png_path.is_empty() or selected_anims.is_empty():
		return

	var importer = load("res://addons/AATTAAI/importer.gd").new()
	var anim_files_override := []
	var base_folder := folder_path
	if folder_path.ends_with(".json"):
		anim_files_override.append(folder_path)
		base_folder = folder_path.get_base_dir()

	var root_node = importer.import_in_memory(atlas_path, base_folder, png_path, fps_val, anim_files_override, selected_anims, use_pivot, add_swapper, filter_mode, interp_mode)
	if root_node:
		_preview_node = root_node
		_preview_viewport.add_child(_preview_node)
		_preview_node.position = Vector2(0, 0)
		
		if _preview_node.has_node("AnimationPlayer"):
			_preview_player = _preview_node.get_node("AnimationPlayer")
			var lib = _preview_player.get_animation_library("")
			if lib:
				var anims = lib.get_animation_list()
				var is_loop := _loop_btn.button_pressed if _loop_btn else true
				for a in anims:
					_anim_option.add_item(a)
					var anim_res: Animation = lib.get_animation(a)
					if anim_res:
						anim_res.loop_mode = Animation.LOOP_LINEAR if is_loop else Animation.LOOP_NONE
				if anims.size() > 0:
					_preview_player.play(anims[0])
					_play_btn.text = "⏸️ Pause"
			
			_preview_player.animation_finished.connect(func(_anim_name: StringName):
				if _loop_btn and not _loop_btn.button_pressed:
					_play_btn.text = "▶️ Play"
			)

func _build_dialog() -> Window:
	var dlg := Window.new()
	dlg.title = "Adobe Animate Importer (AATTAAI)"
	dlg.size = Vector2i(1080, 640)
	dlg.min_size = Vector2i(900, 520)
	dlg.exclusive = true

	var split := HSplitContainer.new()
	split.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 12)
	dlg.add_child(split)

	# ── Left Column Container (Scrollable Form + Pinned Bottom Bar) ─────
	var left_vbox := VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left_vbox)

	# Left side ScrollContainer (Form Parameters)
	var left_scroll := ScrollContainer.new()
	left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(left_scroll)

	var form_vbox := VBoxContainer.new()
	form_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_scroll.add_child(form_vbox)

	# ── Header Information ───────────────────────────────
	var header := Label.new()
	header.text = "ℹ️ Select the Spritemap JSON to auto-predict other paths."
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	form_vbox.add_child(header)
	form_vbox.add_child(HSeparator.new())

	# ── Spritemap JSON ────────────────────────────────────
	form_vbox.add_child(_label("Spritemap JSON (spritemap1.json):"))
	_atlas_edit = LineEdit.new()
	_atlas_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_atlas_edit.placeholder_text = "res://assets/spritemap1.json"
	var row_atlas := _browse_row(_atlas_edit); form_vbox.add_child(row_atlas)
	
	_atlas_val_lbl = Label.new()
	_atlas_val_lbl.text = "❌ No file selected."
	_atlas_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	form_vbox.add_child(_atlas_val_lbl)

	# ── Spritesheet PNG ──────────────────────────────────
	form_vbox.add_child(_label("Spritesheet PNG (spritemap1.png):"))
	_png_edit = LineEdit.new()
	_png_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_png_edit.placeholder_text = "res://assets/spritemap1.png"
	var row_png := _browse_row(_png_edit); form_vbox.add_child(row_png)
	
	_png_val_lbl = Label.new()
	_png_val_lbl.text = "❌ No file selected."
	_png_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	form_vbox.add_child(_png_val_lbl)

	# ── Animation JSON File or Folder ─────────────────────
	form_vbox.add_child(_label("Animation JSON File or Folder:"))
	_folder_edit = LineEdit.new()
	_folder_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_folder_edit.placeholder_text = "res://assets/Animation.json or res://assets/animations/"
	var row_folder := HBoxContainer.new(); form_vbox.add_child(row_folder)
	row_folder.add_child(_folder_edit)
	
	var btn_folder_file := Button.new(); btn_folder_file.text = "Browse File"
	row_folder.add_child(btn_folder_file)
	
	var btn_folder := Button.new(); btn_folder.text = "Browse Folder"
	row_folder.add_child(btn_folder)
	
	_folder_val_lbl = Label.new()
	_folder_val_lbl.text = "❌ No file or folder selected."
	_folder_val_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	form_vbox.add_child(_folder_val_lbl)

	# ── Animations Selection & Search Header ─────────────
	var anim_hdr := HBoxContainer.new()
	form_vbox.add_child(anim_hdr)
	
	_anim_title_lbl = Label.new()
	_anim_title_lbl.text = "📋 Animations to Import:"
	_anim_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	anim_hdr.add_child(_anim_title_lbl)
	
	_btn_select_all = Button.new()
	_btn_select_all.text = "☑️ All"
	anim_hdr.add_child(_btn_select_all)
	
	_btn_deselect_all = Button.new()
	_btn_deselect_all.text = "⬜ None"
	anim_hdr.add_child(_btn_deselect_all)

	_btn_select_filtered = Button.new()
	_btn_select_filtered.text = "🎯 Select Filtered"
	_btn_select_filtered.tooltip_text = "Select all animations matching the search filter below"
	anim_hdr.add_child(_btn_select_filtered)

	# Search Filter Bar
	_anim_search_edit = LineEdit.new()
	_anim_search_edit.placeholder_text = "🔍 Filter animations (e.g. attack, idle, walk)..."
	_anim_search_edit.clear_button_enabled = true
	form_vbox.add_child(_anim_search_edit)

	# Scrollable Grid of Checkboxes
	var anim_panel := PanelContainer.new()
	anim_panel.custom_minimum_size = Vector2(0, 130)
	anim_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form_vbox.add_child(anim_panel)

	var scroll_anim := ScrollContainer.new()
	scroll_anim.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_anim.size_flags_vertical = Control.SIZE_EXPAND_FILL
	anim_panel.add_child(scroll_anim)

	_anim_container = GridContainer.new()
	_anim_container.columns = 2
	_anim_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_anim.add_child(_anim_container)

	# ── Output scene ─────────────────────────────────────
	form_vbox.add_child(_label("Output scene path:"))
	_out_edit = LineEdit.new()
	_out_edit.text = "res://imported_character.tscn"
	_out_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row_out := _browse_row(_out_edit); form_vbox.add_child(row_out)

	# ── FPS override ─────────────────────────────────────
	var fps_row := HBoxContainer.new(); form_vbox.add_child(fps_row)
	fps_row.add_child(_label("FPS override (0 = dari JSON):"))
	_fps_spin = SpinBox.new()
	_fps_spin.min_value = 0; _fps_spin.max_value = 120; _fps_spin.value = 0
	fps_row.add_child(_fps_spin)

	# ── Texture Filter dropdown ──────────────────────────
	var filter_row := HBoxContainer.new(); form_vbox.add_child(filter_row)
	filter_row.add_child(_label("Texture Filter:"))
	_filter_option = OptionButton.new()
	_filter_option.add_item("Linear (Smooth)", 0)
	_filter_option.add_item("Nearest (Pixel Art)", 1)
	_filter_option.selected = 0
	filter_row.add_child(_filter_option)

	# ── Animation Interpolation dropdown ─────────────────
	var interp_row := HBoxContainer.new(); form_vbox.add_child(interp_row)
	interp_row.add_child(_label("Animation Interpolation:"))
	_interp_option = OptionButton.new()
	_interp_option.add_item("Linear (Smooth Tween)", 0)
	_interp_option.add_item("Nearest / Stepped (Frame-by-Frame)", 1)
	_interp_option.add_item("Cubic (Spline Curve)", 2)
	_interp_option.selected = 0
	interp_row.add_child(_interp_option)

	# ── Checkboxes ───────────────────────────────────────
	_swapper_check = CheckBox.new()
	_swapper_check.text = "Add Visual Controller Script (@tool)"
	_swapper_check.button_pressed = true
	form_vbox.add_child(_swapper_check)

	# ── PINNED BOTTOM ACTION BAR (Always visible!) ───────
	var bottom_bar := VBoxContainer.new()
	bottom_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.add_child(bottom_bar)

	bottom_bar.add_child(HSeparator.new())

	_status_lbl = Label.new()
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bottom_bar.add_child(_status_lbl)

	var btn_action_row := HBoxContainer.new()
	btn_action_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_bar.add_child(btn_action_row)

	_btn_import = Button.new()
	_btn_import.text = "⬇️ Fresh Import"
	_btn_import.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_import.custom_minimum_size = Vector2(0, 34)
	btn_action_row.add_child(_btn_import)

	_btn_update = Button.new()
	_btn_update.text = "🔄 Update Existing Scene"
	_btn_update.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_update.custom_minimum_size = Vector2(0, 34)
	btn_action_row.add_child(_btn_update)

	# ── Right side: Interactive Viewport Preview ─────────
	var right_vbox := VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.custom_minimum_size = Vector2(400, 0)
	split.add_child(right_vbox)

	var preview_title := Label.new()
	preview_title.text = "🎬 Animation Preview"
	preview_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	preview_title.add_theme_font_size_override("font_size", 14)
	right_vbox.add_child(preview_title)

	var vp_container := SubViewportContainer.new()
	vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vp_container.stretch = true
	vp_container.focus_mode = Control.FOCUS_ALL
	right_vbox.add_child(vp_container)

	_preview_viewport = SubViewport.new()
	_preview_viewport.disable_3d = true
	_preview_viewport.transparent_bg = false
	_preview_viewport.world_2d = World2D.new()
	vp_container.add_child(_preview_viewport)

	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = -100
	_preview_viewport.add_child(canvas_layer)

	var bg_rect := ColorRect.new()
	bg_rect.color = Color(0.22, 0.22, 0.24, 1.0)
	bg_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas_layer.add_child(bg_rect)

	# Add Coordinate & Floor Grid
	var preview_grid = AATTAIPreviewGrid.new()
	preview_grid.z_index = -50
	preview_grid.show_grid = true
	_preview_grid = preview_grid
	_preview_viewport.add_child(preview_grid)

	var camera := Camera2D.new()
	camera.position = Vector2(0, -100)
	camera.zoom = Vector2(1.5, 1.5)
	_preview_viewport.add_child(camera)

	# Connect panning, zooming, and reset view
	vp_container.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
				camera.zoom *= 1.15
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
				camera.zoom /= 1.15
				if camera.zoom.x < 0.1:
					camera.zoom = Vector2(0.1, 0.1)
			
			if event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
				camera.position = Vector2(0, -100)
				camera.zoom = Vector2(1.5, 1.5)
		elif event is InputEventMouseMotion:
			var right_pressed = (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0
			var middle_pressed = (event.button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0
			if right_pressed or middle_pressed:
				camera.position -= event.relative / camera.zoom
	)

	# Controls HBox
	var ctrl_row := HBoxContainer.new()
	ctrl_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(ctrl_row)

	_play_btn = Button.new()
	_play_btn.text = "⏸️ Pause"
	ctrl_row.add_child(_play_btn)

	_anim_option = OptionButton.new()
	_anim_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ctrl_row.add_child(_anim_option)

	# Loop Toggle Button (Feature 1)
	_loop_btn = Button.new()
	_loop_btn.text = "🔁 Loop"
	_loop_btn.toggle_mode = true
	_loop_btn.button_pressed = true
	_loop_btn.tooltip_text = "Toggle Animation Loop in Preview"
	ctrl_row.add_child(_loop_btn)
	_loop_btn.toggled.connect(func(is_loop: bool):
		if is_instance_valid(_preview_player):
			var lib = _preview_player.get_animation_library("")
			if lib:
				for a in lib.get_animation_list():
					var anim_res: Animation = lib.get_animation(a)
					if anim_res:
						anim_res.loop_mode = Animation.LOOP_LINEAR if is_loop else Animation.LOOP_NONE
	)

	# Grid Toggle Button
	_grid_btn = Button.new()
	_grid_btn.text = "📏 Grid"
	_grid_btn.toggle_mode = true
	_grid_btn.button_pressed = true
	_grid_btn.tooltip_text = "Toggle Origin Axes & Floor Grid"
	ctrl_row.add_child(_grid_btn)
	_grid_btn.toggled.connect(func(t: bool):
		if is_instance_valid(_preview_grid):
			_preview_grid.show_grid = t
	)

	var bg_picker := ColorPickerButton.new()
	bg_picker.color = Color(0.22, 0.22, 0.24, 1.0)
	bg_picker.custom_minimum_size = Vector2(40, 0)
	bg_picker.tooltip_text = "Change preview background color"
	ctrl_row.add_child(bg_picker)
	bg_picker.color_changed.connect(func(new_color: Color):
		bg_rect.color = new_color
	)

	# Scrubber HBox
	var scrub_row := HBoxContainer.new()
	scrub_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(scrub_row)

	scrub_row.add_child(_label("Timeline:"))
	_scrub_slider = HSlider.new()
	_scrub_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scrub_slider.min_value = 0.0
	_scrub_slider.max_value = 1.0
	_scrub_slider.step = 0.001
	scrub_row.add_child(_scrub_slider)

	# Timer for scrubber update
	_preview_timer = Timer.new()
	_preview_timer.wait_time = 0.05
	_preview_timer.autostart = true
	dlg.add_child(_preview_timer)

	# Debounce timer for preview rendering
	_preview_debounce_timer = Timer.new()
	_preview_debounce_timer.one_shot = true
	_preview_debounce_timer.wait_time = 0.25
	_preview_debounce_timer.timeout.connect(_update_preview)
	dlg.add_child(_preview_debounce_timer)

	# ── File dialogs ─────────────────────────────────────
	var fd_atlas := _make_file_dialog(dlg, "*.json", _atlas_edit)
	var fd_png   := _make_file_dialog(dlg, "*.png",  _png_edit)
	var fd_anim_file := _make_file_dialog(dlg, "*.json", _folder_edit)
	var fd_out   := _make_file_dialog(dlg, "*.tscn", _out_edit, FileDialog.FILE_MODE_SAVE_FILE)

	var fd_folder := FileDialog.new()
	fd_folder.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd_folder.access = FileDialog.ACCESS_RESOURCES
	dlg.add_child(fd_folder)

	_get_browse_btn(row_atlas).pressed.connect(func(): fd_atlas.popup_centered(Vector2i(700,500)))
	_get_browse_btn(row_png).pressed.connect(func():   fd_png.popup_centered(Vector2i(700,500)))
	_get_browse_btn(row_out).pressed.connect(func():   fd_out.popup_centered(Vector2i(700,500)))
	btn_folder_file.pressed.connect(func(): fd_anim_file.popup_centered(Vector2i(700,500)))
	btn_folder.pressed.connect(func(): fd_folder.popup_centered(Vector2i(700,500)))

	# Search Filter Listener
	_anim_search_edit.text_changed.connect(func(query: String):
		_filter_animation_checkboxes(query)
	)

	# Selection Buttons Listeners
	_btn_select_all.pressed.connect(func():
		for anim_name in _anim_checkboxes:
			var cb: CheckBox = _anim_checkboxes[anim_name]
			if is_instance_valid(cb):
				cb.set_pressed_no_signal(true)
		_on_anim_selection_changed()
	)

	_btn_deselect_all.pressed.connect(func():
		for anim_name in _anim_checkboxes:
			var cb: CheckBox = _anim_checkboxes[anim_name]
			if is_instance_valid(cb):
				cb.set_pressed_no_signal(false)
		_on_anim_selection_changed()
	)

	_btn_select_filtered.pressed.connect(func():
		for anim_name in _anim_checkboxes:
			var cb: CheckBox = _anim_checkboxes[anim_name]
			if is_instance_valid(cb) and cb.visible:
				cb.set_pressed_no_signal(true)
		_on_anim_selection_changed()
	)

	# Load settings on start
	var settings := _load_settings()
	_atlas_edit.text = settings["atlas_path"]
	_folder_edit.text = settings["folder_path"]
	_png_edit.text = settings["png_path"]
	_out_edit.text = settings["out_path"]
	_fps_spin.value = settings["fps_override"]
	_swapper_check.button_pressed = settings["add_swapper"]
	_filter_option.selected = settings["filter_mode"]
	_interp_option.selected = settings["interp_mode"]
	if _grid_btn:
		_grid_btn.button_pressed = settings["show_grid"]
		if is_instance_valid(_preview_grid):
			_preview_grid.show_grid = settings["show_grid"]
	if _loop_btn:
		_loop_btn.button_pressed = settings["preview_loop"]

	# Signals
	_atlas_edit.text_changed.connect(func(t: String):
		_auto_predict_from_atlas(t.strip_edges())
		_validate_all()
	)
	_png_edit.text_changed.connect(func(_t: String):
		_validate_all()
	)
	_folder_edit.text_changed.connect(func(_t: String):
		_last_scanned_folder = ""
		_validate_all()
	)
	_out_edit.text_changed.connect(func(_t: String):
		_validate_all()
	)
	_fps_spin.value_changed.connect(func(_v: float):
		_validate_all()
	)
	
	_swapper_check.pressed.connect(_validate_all)
	_filter_option.item_selected.connect(func(_idx): _validate_all())
	_interp_option.item_selected.connect(func(_idx): _validate_all())

	fd_atlas.file_selected.connect(func(path: String):
		_atlas_edit.text = path
		_auto_predict_from_atlas(path)
		_validate_all()
	)
	fd_png.file_selected.connect(func(path: String):
		_png_edit.text = path
		_validate_all()
	)
	fd_anim_file.file_selected.connect(func(path: String):
		_folder_edit.text = path
		_last_scanned_folder = ""
		_validate_all()
	)
	fd_folder.dir_selected.connect(func(dir: String):
		_folder_edit.text = dir
		_last_scanned_folder = ""
		_validate_all()
	)
	fd_out.file_selected.connect(func(path: String):
		_out_edit.text = path
		_validate_all()
	)

	_play_btn.pressed.connect(func():
		if not is_instance_valid(_preview_player): return
		if _preview_player.is_playing():
			_preview_player.pause()
			_play_btn.text = "▶️ Play"
		else:
			var anim_name = _preview_player.assigned_animation
			if anim_name != "":
				var anim_res = _preview_player.get_animation(anim_name)
				if anim_res and _preview_player.current_animation_position >= anim_res.length:
					_preview_player.seek(0.0, true)
			_preview_player.play()
			_play_btn.text = "⏸️ Pause"
	)

	_anim_option.item_selected.connect(func(idx: int):
		if not is_instance_valid(_preview_player): return
		var anim_name = _anim_option.get_item_text(idx)
		_preview_player.play(anim_name)
		_play_btn.text = "⏸️ Pause"
	)

	_scrub_slider.drag_started.connect(func():
		_is_scrubbing = true
		if is_instance_valid(_preview_player):
			_was_playing_before_scrub = _preview_player.is_playing()
			_preview_player.pause()
	)
	_scrub_slider.drag_ended.connect(func(_value_changed: bool):
		_is_scrubbing = false
		if is_instance_valid(_preview_player):
			var anim_name = _preview_player.assigned_animation
			if anim_name != "":
				var length = _preview_player.get_animation(anim_name).length
				_preview_player.seek(_scrub_slider.value * length, true)
				_preview_player.advance(0)
				if _was_playing_before_scrub:
					_preview_player.play()
					_play_btn.text = "⏸️ Pause"
				else:
					_play_btn.text = "▶️ Play"
	)
	_scrub_slider.value_changed.connect(func(val: float):
		if _is_updating_slider: return
		if is_instance_valid(_preview_player):
			var anim_name = _preview_player.assigned_animation
			if anim_name != "":
				var length = _preview_player.get_animation(anim_name).length
				_preview_player.seek(val * length, true)
				_preview_player.advance(0)
	)

	_preview_timer.timeout.connect(func():
		if _is_scrubbing or not is_instance_valid(_preview_player): return
		var anim_name = _preview_player.assigned_animation
		if anim_name == "": return
		var length = _preview_player.get_animation(anim_name).length
		if length > 0.0:
			_is_updating_slider = true
			_scrub_slider.value = _preview_player.current_animation_position / length
			_is_updating_slider = false
	)

	# Initial validation
	_validate_all()

	# ── Fresh Import Logic ────────────────────────────────
	_btn_import.pressed.connect(func():
		var atlas_path := _atlas_edit.text.strip_edges()
		var folder_path := _folder_edit.text.strip_edges()
		var png_path := _png_edit.text.strip_edges()
		var out_path := _out_edit.text.strip_edges()
		var fps_val := int(_fps_spin.value)
		var use_pivot := true
		var add_swapper := _swapper_check.button_pressed
		var filter_idx := _filter_option.selected
		var filter_mode := "Linear" if filter_idx == 0 else "Nearest"
		var interp_mode := _get_interp_mode_str()
		var selected_anims := _get_selected_animations()

		if atlas_path.is_empty() or folder_path.is_empty() or png_path.is_empty() or out_path.is_empty():
			_status_lbl.text = "⚠️ Fill all fields."
			return

		if selected_anims.is_empty():
			_status_lbl.text = "⚠️ Please select at least one animation to import."
			return

		_status_lbl.text = "⏳ Importing %d animation(s)..." % selected_anims.size()
		var importer = load("res://addons/AATTAAI/importer.gd").new()
		
		var anim_files_override := []
		var base_folder := folder_path
		if folder_path.ends_with(".json"):
			anim_files_override.append(folder_path)
			base_folder = folder_path.get_base_dir()

		var err: String = importer.import_folder(
			atlas_path, base_folder, png_path, out_path, fps_val, anim_files_override,
			selected_anims, use_pivot, add_swapper, filter_mode, interp_mode
		)

		if err == "":
			_status_lbl.text = "✅ Done! Imported %d animation(s) successfully.\nScene: %s" % [selected_anims.size(), out_path]
			_save_settings()
			_validate_all()
			get_editor_interface().get_resource_filesystem().scan()
		else:
			_status_lbl.text = "❌ Error: " + err
	)

	# ── Update Existing Scene Logic ───────────────────────
	_btn_update.pressed.connect(func():
		var atlas_path := _atlas_edit.text.strip_edges()
		var folder_path := _folder_edit.text.strip_edges()
		var png_path := _png_edit.text.strip_edges()
		var out_path := _out_edit.text.strip_edges()
		var fps_val := int(_fps_spin.value)
		var use_pivot := true
		var add_swapper := _swapper_check.button_pressed
		var filter_idx := _filter_option.selected
		var filter_mode := "Linear" if filter_idx == 0 else "Nearest"
		var interp_mode := _get_interp_mode_str()
		var selected_anims := _get_selected_animations()

		if atlas_path.is_empty() or folder_path.is_empty() or png_path.is_empty() or out_path.is_empty():
			_status_lbl.text = "⚠️ Fill all fields."
			return

		if selected_anims.is_empty():
			_status_lbl.text = "⚠️ Please select at least one animation to update."
			return

		_status_lbl.text = "⏳ Updating %d animation(s) in existing scene..." % selected_anims.size()
		var importer = load("res://addons/AATTAAI/importer.gd").new()
		
		var anim_files_override := []
		var base_folder := folder_path
		if folder_path.ends_with(".json"):
			anim_files_override.append(folder_path)
			base_folder = folder_path.get_base_dir()

		var err: String = importer.update_existing_scene(
			atlas_path, base_folder, png_path, out_path, fps_val, anim_files_override,
			selected_anims, use_pivot, add_swapper, filter_mode, interp_mode
		)

		if err == "":
			_status_lbl.text = "✅ Done! Updated %d animation(s) in existing scene:\n%s\n\n💡 Tip: If this scene is already open in your editor, please close and re-open its scene tab (or Project -> Reload Current Project) to refresh the AnimationPlayer in Godot." % [selected_anims.size(), out_path]
			_save_settings()
			_validate_all()
			get_editor_interface().get_resource_filesystem().scan()
		else:
			_status_lbl.text = "❌ Error: " + err
	)

	dlg.close_requested.connect(func(): 
		_clear_preview()
		dlg.hide()
	)
	return dlg

# ── Batch Set Interpolation Dialog (Feature 3) ────────────
func _build_interp_dialog() -> Window:
	var dlg := Window.new()
	dlg.title = "Batch Set Animation Interpolation (AATTAAI)"
	dlg.size = Vector2i(650, 420)
	dlg.min_size = Vector2i(550, 360)
	dlg.exclusive = true

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 12)
	dlg.add_child(margin)

	var vbox := VBoxContainer.new()
	margin.add_child(vbox)

	var header := Label.new()
	header.text = "⚡ Batch-change track interpolation on specific animations in any character scene."
	header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0))
	vbox.add_child(header)
	vbox.add_child(HSeparator.new())

	# Target Scene Path
	vbox.add_child(_label("Target Scene (.tscn):"))
	var scene_edit := LineEdit.new()
	scene_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scene_edit.placeholder_text = "res://imported_character.tscn"
	if _out_edit and not _out_edit.text.is_empty():
		scene_edit.text = _out_edit.text
	var row_scene := _browse_row(scene_edit); vbox.add_child(row_scene)

	var fd_scene := _make_file_dialog(dlg, "*.tscn", scene_edit)
	_get_browse_btn(row_scene).pressed.connect(func(): fd_scene.popup_centered(Vector2i(700, 500)))

	# Animation Name / Pattern Input
	vbox.add_child(_label("Animation Name(s) or Pattern (e.g. attack*, hit_react, *pixel*):"))
	var pattern_edit := LineEdit.new()
	pattern_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pattern_edit.placeholder_text = "e.g. attack* or punch, kick, jump"
	vbox.add_child(pattern_edit)

	# Interpolation Type Dropdown
	var interp_row := HBoxContainer.new(); vbox.add_child(interp_row)
	interp_row.add_child(_label("Target Interpolation Type:"))
	var opt_interp := OptionButton.new()
	opt_interp.add_item("Nearest / Stepped (Frame-by-Frame)", 0)
	opt_interp.add_item("Linear (Smooth Tween)", 1)
	opt_interp.add_item("Cubic (Spline Curve)", 2)
	opt_interp.selected = 0
	interp_row.add_child(opt_interp)

	vbox.add_child(HSeparator.new())

	var status_lbl := Label.new()
	status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(status_lbl)

	var btn_apply := Button.new()
	btn_apply.text = "⚡ Apply Interpolation to Matching Animations"
	btn_apply.custom_minimum_size = Vector2(0, 36)
	vbox.add_child(btn_apply)

	btn_apply.pressed.connect(func():
		var sc_path := scene_edit.text.strip_edges()
		var pat := pattern_edit.text.strip_edges()
		if sc_path.is_empty():
			status_lbl.text = "⚠️ Please select a target scene (.tscn)."
			return
		if pat.is_empty():
			pat = "*"

		var target_mode := "Nearest"
		match opt_interp.selected:
			1: target_mode = "Linear"
			2: target_mode = "Cubic"
			_: target_mode = "Nearest"

		status_lbl.text = "⏳ Processing..."
		var importer = load("res://addons/AATTAAI/importer.gd").new()
		var res: Dictionary = importer.set_animations_interpolation(sc_path, pat, target_mode)

		if res["success"]:
			status_lbl.text = "✅ Success! Updated %d animation(s) to '%s':\n• %s\n\n💡 Tip: Please reload/re-open the scene tab to see changes." % [
				res["modified_count"], target_mode, "\n• ".join(res["matched_anims"])
			]
			get_editor_interface().get_resource_filesystem().scan()
		else:
			status_lbl.text = "❌ Error: " + res.get("error", "Unknown error")
	)

	dlg.close_requested.connect(func(): dlg.hide())
	return dlg

func _label(text: String) -> Label:
	var l := Label.new(); l.text = text; return l

func _browse_row(edit: LineEdit) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_child(edit)
	var btn := Button.new(); btn.text = "Browse"
	row.add_child(btn)
	return row

func _get_browse_btn(row: HBoxContainer) -> Button:
	return row.get_child(1) as Button

func _make_file_dialog(parent: Window, filter: String, target: LineEdit, mode: FileDialog.FileMode = FileDialog.FILE_MODE_OPEN_FILE) -> FileDialog:
	var fd := FileDialog.new()
	fd.file_mode = mode
	fd.access = FileDialog.ACCESS_RESOURCES
	fd.filters = [filter]
	parent.add_child(fd)
	fd.file_selected.connect(func(path: String): target.text = path)
	return fd
