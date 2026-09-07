@tool
# AdobeAnimateImporter — core logic  (v4 — shared sprite + visible fix)
# Fix: Shared sprite — layer dengan nama sama di animasi berbeda share satu
#      Sprite2D (tidak duplikat). Layer nama duplikat dalam satu animasi tetap
#      dipisah dengan suffix "#layer_idx".
# Fix: Visible bug — keyframe false di t=0 hanya diinsert jika frame pertama
#      tidak mulai di t=0; node dari animasi lain di-hide eksplisit di t=0.
# Fix: Track rotasi pakai INTERPOLATION_LINEAR_ANGLE agar Godot selalu
#      memilih jalur terpendek.
extends RefCounted

var _symbol_map: Dictionary = {}  # "stickman/parts/arm" → {sprite, ox, oy}

# ─────────────────────────────────────────────────────────
# Entry point — SINGLE file (backward compat)
# ─────────────────────────────────────────────────────────
func import(atlas_json_path: String, anim_json_path: String,
			png_path: String, out_path: String, fps_override: int,
			use_pivot_wrappers: bool = true, add_skin_swapper: bool = true,
			texture_filter_mode: String = "Linear",
			interpolation_mode: String = "Linear") -> String:
	return import_folder(atlas_json_path, anim_json_path.get_base_dir(),
						 png_path, out_path, fps_override, [anim_json_path],
						 [], use_pivot_wrappers, add_skin_swapper, texture_filter_mode, interpolation_mode)

func get_available_animations(anim_folder_or_file: String) -> Array:
	var result: Array = []
	var path_str := anim_folder_or_file.replace("\\", "/").strip_edges()
	if path_str.is_empty():
		return result
	
	var anim_files: Array = []
	if path_str.ends_with(".json"):
		anim_files = [path_str]
	else:
		anim_files = _scan_json_files(path_str)
	
	for json_path in anim_files:
		var anim_data = _load_json(json_path)
		if anim_data == null or anim_data is String: continue
		if _is_atlas_json(anim_data): continue
		
		var has_root: bool = anim_data.has("AN") and _has_timeline_animation(anim_data.get("AN", {}).get("TL", {}))
		var master_found := false
		if _is_master_animation_json(anim_data):
			for s in anim_data.get("SD", {}).get("S", []):
				if _is_animation_symbol(s):
					master_found = true
					var raw_name: String = s.get("SN", "")
					var parts_array := raw_name.split("/")
					var anim_name: String = parts_array[parts_array.size() - 1]
					if not result.has(anim_name):
						result.append(anim_name)
		
		if not master_found:
			var root_name: String = ""
			if anim_data.has("AN"):
				root_name = str(anim_data.get("AN", {}).get("SN", anim_data.get("AN", {}).get("N", ""))).strip_edges()
			if root_name.is_empty():
				root_name = json_path.get_file().get_basename()
			if not result.has(root_name):
				result.append(root_name)
	return result

# ─────────────────────────────────────────────────────────
# Tool Helper: Batch set interpolation on specific animations in a .tscn scene
# Supports exact names, comma-separated lists, and wildcard '*' patterns (e.g. "attack*", "hit_1, hit_2")
# ─────────────────────────────────────────────────────────
func set_animations_interpolation(scene_path: String, anim_pattern: String, interpolation_mode: String) -> Dictionary:
	var res := {"success": false, "modified_count": 0, "matched_anims": [], "error": ""}
	if not FileAccess.file_exists(scene_path):
		res["error"] = "File does not exist: " + scene_path
		return res

	var scene_res := ResourceLoader.load(scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if scene_res == null:
		res["error"] = "Failed to load scene: " + scene_path
		return res

	var root: Node = scene_res.instantiate()
	if root == null:
		res["error"] = "Failed to instantiate scene: " + scene_path
		return res

	var anim_player: AnimationPlayer = null
	if root is AnimationPlayer:
		anim_player = root
	else:
		anim_player = root.get_node_or_null("AnimationPlayer")
		if anim_player == null:
			for c in root.get_children():
				if c is AnimationPlayer:
					anim_player = c
					break

	if anim_player == null:
		root.queue_free()
		res["error"] = "No AnimationPlayer found in scene: " + scene_path
		return res

	var lib: AnimationLibrary = null
	if anim_player.has_animation_library(""):
		lib = anim_player.get_animation_library("")
	if lib == null:
		root.queue_free()
		res["error"] = "No AnimationLibrary found in AnimationPlayer."
		return res

	var interp_type: Animation.InterpolationType = Animation.INTERPOLATION_LINEAR
	var lower_interp := interpolation_mode.to_lower()
	if lower_interp.contains("nearest") or lower_interp.contains("stepped"):
		interp_type = Animation.INTERPOLATION_NEAREST
	elif lower_interp.contains("cubic"):
		interp_type = Animation.INTERPOLATION_CUBIC

	var patterns := []
	for p in anim_pattern.split(","):
		var s := p.strip_edges()
		if not s.is_empty():
			patterns.append(s)

	if patterns.is_empty():
		patterns.append("*")

	var modified_anims := []
	for anim_name in lib.get_animation_list():
		var matches := false
		for pat in patterns:
			if pat == "*" or anim_name.matchn(pat) or anim_name.to_lower() == pat.to_lower():
				matches = true
				break
		
		if matches:
			var anim: Animation = lib.get_animation(anim_name)
			if anim:
				modified_anims.append(anim_name)
				for track_idx in range(anim.get_track_count()):
					var track_path := str(anim.track_get_path(track_idx))
					if track_path.ends_with(":position") or track_path.ends_with(":r_vec") or track_path.ends_with(":scale"):
						anim.track_set_interpolation_type(track_idx, interp_type)
					elif track_path.ends_with(":rotation"):
						if interp_type == Animation.INTERPOLATION_LINEAR:
							anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_LINEAR_ANGLE)
						elif interp_type == Animation.INTERPOLATION_CUBIC:
							anim.track_set_interpolation_type(track_idx, Animation.INTERPOLATION_CUBIC_ANGLE)
						else:
							anim.track_set_interpolation_type(track_idx, interp_type)

	if modified_anims.is_empty():
		root.queue_free()
		res["error"] = "No animations matched pattern '%s'." % anim_pattern
		return res

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		root.queue_free()
		res["error"] = "PackedScene.pack() failed."
		return res

	_ensure_parent_dir(scene_path)
	if ResourceSaver.save(packed, scene_path) != OK:
		root.queue_free()
		res["error"] = "Failed to save scene: " + scene_path
		return res

	root.queue_free()
	res["success"] = true
	res["modified_count"] = modified_anims.size()
	res["matched_anims"] = modified_anims
	return res

func _parse_all_animations(anim_files: Array, sprites: Dictionary, fps_override: int, selected_animations: Array = []) -> Array:
	var all_animations: Array = []
	for json_path in anim_files:
		var anim_data = _load_json(json_path)
		if anim_data is String or anim_data == null:
			continue
		if _is_atlas_json(anim_data):
			continue

		var fps: float = float(fps_override) if fps_override > 0 else _get_fps(anim_data)
		_build_symbol_map(anim_data, sprites)

		var has_master := false
		if _is_master_animation_json(anim_data):
			var anim_symbols: Array = []
			for s in anim_data.get("SD", {}).get("S", []):
				if _is_animation_symbol(s):
					anim_symbols.append(s)
			
			for anim_sym in anim_symbols:
				has_master = true
				var raw_name: String = anim_sym.get("SN", "")
				var parts_array := raw_name.split("/")
				var anim_name: String = parts_array[parts_array.size() - 1]
				if not selected_animations.is_empty() and not selected_animations.has(anim_name):
					continue
				var virtual_anim_data: Dictionary = {
					"AN": {
						"N": anim_data.get("AN", {}).get("N", "character"),
						"SN": anim_name,
						"TL": anim_sym.get("TL", {})
					},
					"SD": anim_data.get("SD", {})
				}
				var parsed := _parse_animations(virtual_anim_data, fps)
				for anim in parsed:
					anim["anim_name"] = anim_name
					all_animations.append(anim)

		if not has_master:
			var root_name: String = ""
			if anim_data.has("AN"):
				root_name = str(anim_data.get("AN", {}).get("SN", anim_data.get("AN", {}).get("N", ""))).strip_edges()
			if root_name.is_empty():
				root_name = json_path.get_file().get_basename()

			if selected_animations.is_empty() or selected_animations.has(root_name) or selected_animations.has(json_path.get_file().get_basename()):
				var parsed := _parse_animations(anim_data, fps)
				for anim in parsed:
					anim["anim_name"] = root_name
					all_animations.append(anim)
	return all_animations

# ─────────────────────────────────────────────────────────
# Entry point — FOLDER (semua *.json di folder)
# anim_folder: path ke folder berisi Animation JSONs
# Kalau anim_files diisi, hanya file itu saja yang dipakai (override scan).
# ─────────────────────────────────────────────────────────
func import_folder(atlas_json_path: String, anim_folder: String,
				   png_path: String, out_path: String,
				   fps_override: int, anim_files: Array = [],
				   selected_animations: Array = [],
				   use_pivot_wrappers: bool = true, add_skin_swapper: bool = true,
				   texture_filter_mode: String = "Linear",
				   interpolation_mode: String = "Linear") -> String:

	_symbol_map.clear()

	# 1. Atlas
	var atlas_data = _load_json(atlas_json_path)
	if atlas_data is String: return "Atlas JSON: " + atlas_data
	var sprites: Dictionary = _parse_atlas(atlas_data)
	if sprites.is_empty(): return "no sprite in atlas JSON."

	# 2. Texture
	var texture: Texture2D = _load_texture(png_path)
	if texture == null: return "cannot load PNG: " + png_path

	# 3. Cari semua Animation JSON di folder
	if anim_files.is_empty():
		anim_files = _scan_json_files(anim_folder)
	if anim_files.is_empty():
		return "no JSON file inside the folder: " + anim_folder

	# 4. Parse semua animasi (filter by selected_animations)
	var all_animations: Array = _parse_all_animations(anim_files, sprites, fps_override, selected_animations)

	if all_animations.is_empty():
		return "all file JSON failed to parse or no animation selected."

	# 5. Build scene
	return _build_scene(sprites, texture, all_animations, out_path,
						use_pivot_wrappers, add_skin_swapper, texture_filter_mode, interpolation_mode)

# ─────────────────────────────────────────────────────────
# Entry point — UPDATE EXISTING SCENE
# Menambah/memperbarui animasi pada file scene (.tscn) yang sudah ada
# tanpa merusak node kustom yang sudah dibuat user
# ─────────────────────────────────────────────────────────
func update_existing_scene(atlas_json_path: String, anim_folder: String,
						   png_path: String, out_path: String,
						   fps_override: int, anim_files: Array = [],
						   selected_animations: Array = [],
						   use_pivot_wrappers: bool = true, add_skin_swapper: bool = true,
						   texture_filter_mode: String = "Linear",
						   interpolation_mode: String = "Linear") -> String:
	if not FileAccess.file_exists(out_path):
		return import_folder(atlas_json_path, anim_folder, png_path, out_path, fps_override, anim_files, selected_animations, use_pivot_wrappers, add_skin_swapper, texture_filter_mode, interpolation_mode)

	_symbol_map.clear()

	var atlas_data = _load_json(atlas_json_path)
	if atlas_data is String: return "Atlas JSON: " + atlas_data
	var sprites: Dictionary = _parse_atlas(atlas_data)
	if sprites.is_empty(): return "no sprite in atlas JSON."

	var texture: Texture2D = _load_texture(png_path)
	if texture == null: return "cannot load PNG: " + png_path

	if anim_files.is_empty():
		anim_files = _scan_json_files(anim_folder)
	if anim_files.is_empty():
		return "no JSON file inside the folder: " + anim_folder

	var all_animations := _parse_all_animations(anim_files, sprites, fps_override, selected_animations)
	if all_animations.is_empty():
		return "No matching animations found to update."

	# Load existing scene
	var scene_res := ResourceLoader.load(out_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if scene_res == null:
		return "Failed to load existing scene: " + out_path
	var root: Node2D = scene_res.instantiate() as Node2D
	if root == null:
		return "Existing scene root is not a Node2D: " + out_path

	# Ensure AnimationPlayer exists
	var anim_player: AnimationPlayer = root.get_node_or_null("AnimationPlayer")
	if anim_player == null:
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimationPlayer"
		root.add_child(anim_player)
		anim_player.owner = root

	var anim_lib: AnimationLibrary
	if anim_player.has_animation_library(""):
		anim_lib = anim_player.get_animation_library("")
	else:
		anim_lib = AnimationLibrary.new()
		anim_player.add_animation_library("", anim_lib)

	# Scripts
	var spr_script
	var script_path = "res://addons/AATTAAI/AATTAI_sprite.gd"
	if ResourceLoader.exists(script_path):
		spr_script = load(script_path)
	else:
		spr_script = GDScript.new()
		spr_script.source_code = "@tool\nextends Sprite2D\n\n@export var r_vec: Vector2 = Vector2.RIGHT:\n\tset(val):\n\t\tr_vec = val\n\t\tif val.length_squared() > 0.0001:\n\t\t\trotation = val.angle()\n"
		spr_script.reload()

	var wrapper_script
	var wrapper_script_path = "res://addons/AATTAAI/AATTAI_wrapper.gd"
	if ResourceLoader.exists(wrapper_script_path):
		wrapper_script = load(wrapper_script_path)
	else:
		wrapper_script = GDScript.new()
		wrapper_script.source_code = "@tool\nextends Node2D\n\n@export var r_vec: Vector2 = Vector2.RIGHT:\n\tset(val):\n\t\tr_vec = val\n\t\tif val.length_squared() > 0.0001:\n\t\t\trotation = val.angle()\n"
		wrapper_script.reload()

	if add_skin_swapper and root.get_script() == null:
		var controller_script
		var controller_path = "res://addons/AATTAAI/AATTAI_controller.gd"
		if ResourceLoader.exists(controller_path):
			controller_script = load(controller_path)
		if controller_script:
			root.set_script(controller_script)

	# Collect existing layer nodes
	var layer_nodes: Dictionary = {}
	for c in root.get_children():
		if c is Node2D and not c is AnimationPlayer:
			layer_nodes[c.name] = c

	var anim_layer_key: Dictionary = {}
	for afi in range(all_animations.size()):
		var anim = all_animations[afi]
		var names_in_anim: Dictionary = {}
		for layer in anim["layers"]:
			var base_name := _sanitize_node_name(layer["name"])
			var node_key: String
			if base_name in names_in_anim:
				node_key = base_name + "#" + str(layer["layer_idx"])
			else:
				node_key = base_name
				names_in_anim[base_name] = true
			anim_layer_key[str(afi) + "#" + str(layer["layer_idx"])] = node_key

			if not layer_nodes.has(node_key) and not root.has_node(NodePath(node_key)):
				var final_name := node_key
				var init_info := _get_initial_sprite_info(node_key, all_animations)
				var init_sp_name: String = init_info.get("sprite", "")
				if use_pivot_wrappers:
					var wrapper := Node2D.new()
					if wrapper_script: wrapper.set_script(wrapper_script)
					wrapper.name = final_name
					root.add_child(wrapper)
					wrapper.owner = root

					var spr := Sprite2D.new()
					spr.name = "Sprite"
					spr.texture = texture
					spr.centered = false
					spr.region_enabled = true
					if init_sp_name != "" and sprites.has(init_sp_name):
						var sp = sprites[init_sp_name]
						spr.region_rect = Rect2(sp["x"], sp["y"], sp["w"], sp["h"])
					if init_info.has("pos"):
						spr.position = init_info["pos"]
						spr.rotation = init_info.get("rot", 0.0)
						spr.scale = init_info.get("scale", Vector2.ONE)
					wrapper.add_child(spr)
					spr.owner = root
					layer_nodes[node_key] = wrapper
				else:
					var spr := Sprite2D.new()
					if spr_script: spr.set_script(spr_script)
					spr.name = final_name
					spr.texture = texture
					spr.centered = false
					spr.region_enabled = true
					if init_sp_name != "" and sprites.has(init_sp_name):
						var sp = sprites[init_sp_name]
						spr.region_rect = Rect2(sp["x"], sp["y"], sp["w"], sp["h"])
					if init_info.has("pos"):
						spr.offset = init_info["pos"]
					root.add_child(spr)
					spr.owner = root
					layer_nodes[node_key] = spr
			else:
				if not layer_nodes.has(node_key):
					layer_nodes[node_key] = root.get_node(NodePath(node_key))

	# Build & Add/Replace Animation resources in AnimationLibrary
	for afi in range(all_animations.size()):
		var anim = all_animations[afi]
		var fps: float = anim["fps"]
		var animation := Animation.new()
		animation.loop_mode = Animation.LOOP_LINEAR
		animation.length = maxf(anim["length"], 1.0 / fps)

		# Active nodes set
		var active_keys := {}
		for layer in anim["layers"]:
			var lookup := str(afi) + "#" + str(layer["layer_idx"])
			var node_key: String = anim_layer_key.get(lookup, "")
			if node_key != "":
				active_keys[node_key] = true

		# Hide inactive animation nodes at t = 0 (do NOT hide user custom nodes)
		for node_key in anim_layer_key.values():
			if not active_keys.has(node_key) and layer_nodes.has(node_key):
				var node: Node = layer_nodes[node_key]
				var npath := node.name
				var t_vis := animation.add_track(Animation.TYPE_VALUE)
				animation.track_set_path(t_vis, NodePath(str(npath) + ":visible"))
				animation.track_set_interpolation_type(t_vis, Animation.INTERPOLATION_NEAREST)
				animation.track_insert_key(t_vis, 0.0, false)

		for layer in anim["layers"]:
			var lookup := str(afi) + "#" + str(layer["layer_idx"])
			var node_key: String = anim_layer_key.get(lookup, "")
			if node_key == "" or not layer_nodes.has(node_key): continue
			var node: Node = layer_nodes[node_key]
			var npath := node.name

			var t_pos    := animation.add_track(Animation.TYPE_VALUE)
			var t_rot    := animation.add_track(Animation.TYPE_VALUE)
			var t_scl    := animation.add_track(Animation.TYPE_VALUE)
			var t_rect   := animation.add_track(Animation.TYPE_VALUE)
			var t_vis    := animation.add_track(Animation.TYPE_VALUE)
			var t_z      := animation.add_track(Animation.TYPE_VALUE)

			var sprite_path = str(npath) + "/Sprite" if use_pivot_wrappers else str(npath)

			animation.track_set_path(t_pos,    NodePath(str(npath) + ":position"))
			animation.track_set_path(t_rot,    NodePath(str(npath) + ":r_vec"))
			animation.track_set_path(t_scl,    NodePath(str(npath) + ":scale"))
			animation.track_set_path(t_rect,   NodePath(sprite_path + ":region_rect"))
			animation.track_set_path(t_vis,    NodePath(str(npath) + ":visible"))
			animation.track_set_path(t_z,      NodePath(str(npath) + ":z_index"))

			var interp_type: Animation.InterpolationType = Animation.INTERPOLATION_LINEAR
			var lower_interp := interpolation_mode.to_lower()
			if lower_interp.contains("nearest") or lower_interp.contains("stepped"):
				interp_type = Animation.INTERPOLATION_NEAREST
			elif lower_interp.contains("cubic"):
				interp_type = Animation.INTERPOLATION_CUBIC

			animation.track_set_interpolation_type(t_pos,    interp_type)
			animation.track_set_interpolation_type(t_rot,    interp_type)
			animation.track_set_interpolation_type(t_scl,    interp_type)
			animation.track_set_interpolation_type(t_rect,   Animation.INTERPOLATION_NEAREST)
			animation.track_set_interpolation_type(t_vis,    Animation.INTERPOLATION_NEAREST)
			animation.track_set_interpolation_type(t_z,      Animation.INTERPOLATION_NEAREST)

			var t_offset := -1

			if not use_pivot_wrappers:
				t_offset = animation.add_track(Animation.TYPE_VALUE)
				animation.track_set_path(t_offset, NodePath(sprite_path + ":offset"))
				animation.track_set_interpolation_type(t_offset, Animation.INTERPOLATION_NEAREST)

			var kf_times:  Array = []
			var kf_pos:    Array = []
			var kf_rot:    Array = []
			var kf_scl:    Array = []
			var kf_rect:   Array = []
			var kf_sprite_pos: Array = []
			var kf_sprite_rot: Array = []
			var kf_sprite_scl: Array = []
			var kf_offset: Array = []
			var kf_vis:    Array = []

			var frame_activity := {}
			for fr in layer["frames"]:
				var fi := int(fr["index"])
				var du := int(fr["duration"])
				var active: bool = not fr["elements"].is_empty()
				for f_idx in range(fi, fi + du):
					frame_activity[f_idx] = active

			var total_frames := int(round(anim["length"] * fps))
			var last_vis_state := false
			if frame_activity.has(0):
				last_vis_state = frame_activity[0]
			else:
				last_vis_state = false
			kf_vis.append({"t": 0.0, "v": last_vis_state})

			for f_idx in range(1, total_frames):
				var current_state := false
				if frame_activity.has(f_idx):
					current_state = frame_activity[f_idx]
				else:
					current_state = false
				if current_state != last_vis_state:
					kf_vis.append({"t": f_idx / fps, "v": current_state})
					last_vis_state = current_state

			var last_rect_val = null
			var last_offset_val = null

			for fr in layer["frames"]:
				var fi   := int(fr["index"])
				var time := fi / fps
				var elems: Array = fr["elements"]
				if elems.is_empty(): continue

				for elem in elems:
					var m: Array = elem.get("m3d", [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
					var dec := _decompose_m3d(m)
					kf_times.append(time)
					kf_pos.append(dec["pos"])
					kf_rot.append(dec["rot"])
					kf_scl.append(dec["scale"])

					var sprite_pos := Vector2.ZERO
					var sprite_rot := 0.0
					var sprite_scale := Vector2.ONE
					var sprite_name := ""
					if elem.get("type") == "sprite":
						sprite_name = elem.get("sprite_name", "")
					elif elem.get("type") == "symbol":
						var ff = elem.get("first_frame", 0)
						var info := _resolve_symbol(elem.get("symbol_name", ""), ff)
						if not info.is_empty():
							sprite_name = info["sprite"]
							if info.has("pos"):
								sprite_pos = info["pos"]
								sprite_rot = info["rot"]
								sprite_scale = info["scale"]
							else:
								sprite_pos = Vector2(info.get("ox", 0.0), info.get("oy", 0.0))

					if sprite_name != "" and sprites.has(sprite_name):
						var sp = sprites[sprite_name]
						var current_rect := Rect2(sp["x"], sp["y"], sp["w"], sp["h"])
						if last_rect_val == null or last_rect_val != current_rect:
							kf_rect.append({"t": time, "v": current_rect})
							last_rect_val = current_rect
						
						if use_pivot_wrappers:
							kf_sprite_pos.append({"t": time, "v": sprite_pos})
							kf_sprite_rot.append({"t": time, "v": sprite_rot})
							kf_sprite_scl.append({"t": time, "v": sprite_scale})
						else:
							var current_offset := sprite_pos
							if last_offset_val == null or last_offset_val != current_offset:
								kf_offset.append({"t": time, "v": current_offset})
								last_offset_val = current_offset
					break

			kf_rot = _normalize_angle_sequence(kf_rot)

			var is_pos_static := true
			if kf_pos.size() > 1:
				var first_pos = kf_pos[0]
				for k in range(1, kf_pos.size()):
					if kf_pos[k] != first_pos:
						is_pos_static = false
						break

			var is_rot_static := true
			if kf_rot.size() > 1:
				var first_rot = kf_rot[0]
				for k in range(1, kf_rot.size()):
					if kf_rot[k] != first_rot:
						is_rot_static = false
						break

			var is_scl_static := true
			if kf_scl.size() > 1:
				var first_scl = kf_scl[0]
				for k in range(1, kf_scl.size()):
					if kf_scl[k] != first_scl:
						is_scl_static = false
						break

			if is_pos_static and kf_pos.size() > 0:
				animation.track_insert_key(t_pos, 0.0, kf_pos[0])
			else:
				for i in range(kf_times.size()):
					animation.track_insert_key(t_pos, kf_times[i], kf_pos[i])

			if is_rot_static and kf_rot.size() > 0:
				var angle: float = kf_rot[0]
				var v := Vector2(cos(angle), sin(angle))
				animation.track_insert_key(t_rot, 0.0, v)
			else:
				for i in range(kf_times.size()):
					var angle: float = kf_rot[i]
					var v := Vector2(cos(angle), sin(angle))
					animation.track_insert_key(t_rot, kf_times[i], v)

			if is_scl_static and kf_scl.size() > 0:
				animation.track_insert_key(t_scl, 0.0, kf_scl[0])
			else:
				for i in range(kf_times.size()):
					animation.track_insert_key(t_scl, kf_times[i], kf_scl[i])

			for entry in kf_rect:
				animation.track_insert_key(t_rect, entry["t"], entry["v"])
			if not use_pivot_wrappers:
				for entry in kf_offset:
					animation.track_insert_key(t_offset, entry["t"], entry["v"])
			for entry in kf_vis:
				animation.track_insert_key(t_vis, entry["t"], entry["v"])

			var z_val: int = anim["layers"].size() - 1 - int(layer["layer_idx"])
			animation.track_insert_key(t_z, 0.0, z_val)

		var safe_name := _sanitize_anim_name(anim["anim_name"])
		if anim_lib.has_animation(safe_name):
			anim_lib.remove_animation(safe_name)
		anim_lib.add_animation(safe_name, animation)

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		root.queue_free()
		return "Failed to repack updated scene."
	_ensure_parent_dir(out_path)
	if ResourceSaver.save(packed, out_path) != OK:
		root.queue_free()
		return "Failed to save updated scene: " + out_path

	root.queue_free()
	return ""

func _is_atlas_json(data: Dictionary) -> bool:
	return data.has("ATLAS") or data.has("sprites") or data.has("SPRITES")

func _has_timeline_animation(tl: Dictionary) -> bool:
	for layer in tl.get("L", []):
		if layer.get("LN", "") == "CenterMarker": continue
		for fr in layer.get("FR", []):
			if not fr.get("E", []).is_empty():
				return true
	return false

# Helper to detect if JSON is a master animation file containing nested animation symbols inside SD
func _is_master_animation_json(data: Dictionary) -> bool:
	if not data.has("SD") or not data["SD"].has("S"):
		return false
	for sym in data["SD"]["S"]:
		if _is_animation_symbol(sym):
			return true
	return false

func _is_animation_symbol(sym_def: Dictionary) -> bool:
	var sym_name: String = sym_def.get("SN", "")
	if sym_name.begins_with("EDAPT") or sym_name.contains("Center Marker") or sym_name.contains("CenterMarker") or sym_name.contains("MagnetTarget"):
		return false
	var tl = sym_def.get("TL", {})
	var layers: Array = tl.get("L", [])
	if layers.is_empty():
		return false
	var anim_layers := 0
	var total_frames := 0
	var has_sub_symbols := false
	for layer in layers:
		if layer.get("LN", "") == "CenterMarker":
			continue
		var fr_arr: Array = layer.get("FR", [])
		if fr_arr.is_empty():
			continue
		var has_elements := false
		for fr in fr_arr:
			total_frames = max(total_frames, int(fr.get("I", 0)) + int(fr.get("DU", 1)))
			for elem in fr.get("E", []):
				has_elements = true
				if elem.has("SI"):
					has_sub_symbols = true
		if has_elements:
			anim_layers += 1
	return has_sub_symbols and ((anim_layers > 1 and total_frames > 1) or total_frames > 2)

func _get_initial_sprite_info(node_key: String, all_animations: Array) -> Dictionary:
	for anim in all_animations:
		for layer in anim.get("layers", []):
			var base_name := _sanitize_node_name(layer.get("name", ""))
			var key: String = base_name
			if node_key.contains("#"):
				key = base_name + "#" + str(layer.get("layer_idx", 0))
			if key == node_key or base_name == node_key:
				for fr in layer.get("frames", []):
					for elem in fr.get("elements", []):
						if elem.get("type") == "sprite":
							return {
								"sprite": elem.get("sprite_name", ""),
								"pos": Vector2.ZERO,
								"rot": 0.0,
								"scale": Vector2.ONE
							}
						elif elem.get("type") == "symbol":
							var sym = elem.get("symbol_name", "")
							var ff = elem.get("first_frame", 0)
							var info = _resolve_symbol(sym, ff)
							if not info.is_empty():
								return info
	return {}

# ─────────────────────────────────────────────────────────
# Scan folder untuk semua *.json
# Skip: spritemap*.json (bukan animation file)
# ─────────────────────────────────────────────────────────
func _scan_json_files(folder: String) -> Array:
	var result: Array = []
	var clean_folder := folder.replace("\\", "/").strip_edges()
	if clean_folder.is_empty(): return result
	var dir := DirAccess.open(clean_folder)
	if dir == null and clean_folder.begins_with("res://"):
		var glob := ProjectSettings.globalize_path(clean_folder)
		dir = DirAccess.open(glob)
	if dir == null: return result
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var lower := fname.to_lower()
			if not lower.begins_with("spritemap") and not lower.begins_with("atlas") and not lower.begins_with("spritesheet") and not lower.contains("atlas") and not lower.contains("spritemap") and not lower.contains("spritesheet"):
				result.append(clean_folder.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result

# ─────────────────────────────────────────────────────────
# JSON loader — handle UTF-8 BOM and key normalization
# ─────────────────────────────────────────────────────────
func _load_json(path: String):
	if path.is_empty(): return "Path empty"
	if not FileAccess.file_exists(path): return "File not found: " + path
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return "can't access file"
	var text := f.get_as_text(); f.close()
	if text.begins_with("\ufeff"): text = text.substr(1)
	var result = JSON.parse_string(text)
	if result == null: return "JSON parse error: " + path
	if result is Dictionary:
		result = _normalize_json(result)
	return result

func _normalize_json(node, parent_key: String = ""):
	if node is Dictionary:
		var normalized := {}
		for key in node:
			var val = node[key]
			var norm_key = key
			
			match key:
				"ANIMATION": norm_key = "AN"
				"SYMBOL_DICTIONARY": norm_key = "SD"
				"Symbols": norm_key = "S"
				"SYMBOL_name": norm_key = "SN"
				"TIMELINE": norm_key = "TL"
				"LAYERS": norm_key = "L"
				"Layer_name": norm_key = "LN"
				"Frames": norm_key = "FR"
				"index": norm_key = "I"
				"duration": norm_key = "DU"
				"elements": norm_key = "E"
				"SYMBOL_Instance": norm_key = "SI"
				"ATLAS_SPRITE_instance": norm_key = "ASI"
				"firstFrame": norm_key = "FF"
				"loop": norm_key = "LP"
				"metadata": norm_key = "MD"
				"framerate":
					if parent_key == "metadata" or parent_key == "MD":
						norm_key = "FRT"
				"name":
					if parent_key == "ANIMATION" or parent_key == "AN" or parent_key == "ATLAS_SPRITE_instance" or parent_key == "ASI":
						norm_key = "N"
			
			var final_val = val
			if norm_key == "ASI" and val is Dictionary:
				var asi_norm := {}
				for k in val:
					var v = val[k]
					if k == "name" or k == "N":
						asi_norm["N"] = _normalize_json(v, "ASI")
					elif k == "Matrix3D" or k == "M3D" or k.to_lower() == "matrix3d" or k.to_lower() == "m3d":
						if v is Dictionary:
							asi_norm["M3D"] = _matrix_dict_to_array(v)
						else:
							asi_norm["M3D"] = _normalize_json(v, "ASI")
					else:
						asi_norm[k] = _normalize_json(v, "ASI")
				final_val = asi_norm
			elif norm_key == "SI" and val is Dictionary:
				var si_norm := {}
				for k in val:
					var v = val[k]
					if k == "firstFrame" or k == "FF":
						si_norm["FF"] = _normalize_json(v, "SI")
					elif k == "loop" or k == "LP":
						var loop_val = str(v).to_lower()
						if loop_val == "singleframe" or loop_val == "sf":
							si_norm["LP"] = "SF"
						elif loop_val == "loop" or loop_val == "lp":
							si_norm["LP"] = "LP"
						else:
							si_norm["LP"] = v
					elif k == "Matrix3D" or k == "M3D" or k.to_lower() == "matrix3d" or k.to_lower() == "m3d":
						if v is Dictionary:
							si_norm["M3D"] = _matrix_dict_to_array(v)
						else:
							si_norm["M3D"] = _normalize_json(v, "SI")
					elif k == "SYMBOL_name" or k == "SN":
						si_norm["SN"] = _normalize_json(v, "SI")
					else:
						si_norm[k] = _normalize_json(v, "SI")
				final_val = si_norm
			else:
				final_val = _normalize_json(val, norm_key)
			
			normalized[norm_key] = final_val
		return normalized
	elif node is Array:
		var normalized := []
		for item in node:
			normalized.append(_normalize_json(item, parent_key))
		return normalized
	else:
		return node

func _matrix_dict_to_array(dict: Dictionary) -> Array:
	if dict.has("a") or dict.has("tx") or dict.has("ty"):
		var a = float(dict.get("a", 1.0))
		var b = float(dict.get("b", 0.0))
		var c = float(dict.get("c", 0.0))
		var d = float(dict.get("d", 1.0))
		var tx = float(dict.get("tx", dict.get("x", 0.0)))
		var ty = float(dict.get("ty", dict.get("y", 0.0)))
		return [
			a, b, 0.0, 0.0,
			c, d, 0.0, 0.0,
			0.0, 0.0, 1.0, 0.0,
			tx, ty, 0.0, 1.0
		]
	return [
		float(dict.get("m00", 1.0)), float(dict.get("m01", 0.0)), float(dict.get("m02", 0.0)), float(dict.get("m03", 0.0)),
		float(dict.get("m10", 0.0)), float(dict.get("m11", 1.0)), float(dict.get("m12", 0.0)), float(dict.get("m13", 0.0)),
		float(dict.get("m20", 0.0)), float(dict.get("m21", 0.0)), float(dict.get("m22", 1.0)), float(dict.get("m23", 0.0)),
		float(dict.get("m30", dict.get("tx", dict.get("x", 0.0)))),
		float(dict.get("m31", dict.get("ty", dict.get("y", 0.0)))),
		float(dict.get("m32", 0.0)),
		float(dict.get("m33", 1.0))
	]

func _load_texture(path: String) -> Texture2D:
	if path.is_empty(): return null
	if ResourceLoader.exists(path):
		var res = ResourceLoader.load(path)
		if res is Texture2D:
			return res
	if not FileAccess.file_exists(path): return null
	var img := Image.new()
	if img.load(path) != OK: return null
	return ImageTexture.create_from_image(img)

# ─────────────────────────────────────────────────────────
# Atlas parser
# ─────────────────────────────────────────────────────────
func _parse_atlas(data: Dictionary) -> Dictionary:
	var result := {}
	var arr: Array = data.get("ATLAS", {}).get("SPRITES", data.get("sprites", []))
	for entry in arr:
		var sp: Dictionary = entry.get("SPRITE", entry.get("sprite", entry))
		var n := str(sp.get("name", sp.get("n", "")))
		result[n] = {
			"x": int(sp.get("x", 0)), "y": int(sp.get("y", 0)),
			"w": int(sp.get("w", 1)), "h": int(sp.get("h", 1)),
			"rotated": bool(sp.get("rotated", false))
		}
	return result

# ─────────────────────────────────────────────────────────
# FPS — root MD.FRT
# ─────────────────────────────────────────────────────────
func _get_fps(data: Dictionary) -> float:
	if data.has("MD") and data["MD"].has("FRT"): return float(data["MD"]["FRT"])
	if data.has("AN") and data["AN"].get("MD", {}).has("FRT"):
		return float(data["AN"]["MD"]["FRT"])
	return 24.0

# ─────────────────────────────────────────────────────────
# Build symbol map dari SD section
# ─────────────────────────────────────────────────────────
func _build_symbol_map(data: Dictionary, sprites: Dictionary) -> void:
	# Tidak clear() — akumulasi dari semua file (shared atlas)
	for sym_def in data.get("SD", {}).get("S", []):
		var sym_name: String = sym_def.get("SN", "")
		if sym_name.is_empty(): continue
		if _symbol_map.has(sym_name): continue  # sudah ada dari file sebelumnya
		
		var frame_map := {}
		for layer in sym_def.get("TL", {}).get("L", []):
			if layer.get("LN", "") == "CenterMarker": continue
			for fr in layer.get("FR", []):
				var frame_idx := int(fr.get("I", 0))
				for elem in fr.get("E", []):
					if not elem.has("ASI"): continue
					var asi = elem["ASI"]
					var sp_name := str(asi.get("N", ""))
					if sp_name.is_empty() or not sprites.has(sp_name): continue
					var m: Array = asi.get("M3D", [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
					var dec := _decompose_m3d(m)
					frame_map[frame_idx] = {
						"sprite": sp_name,
						"pos": dec["pos"],
						"rot": dec["rot"],
						"scale": dec["scale"]
					}
					break
		if not frame_map.is_empty():
			_symbol_map[sym_name] = frame_map

func _resolve_symbol(sym_name: String, frame_idx: int = 0) -> Dictionary:
	if not _symbol_map.has(sym_name):
		return {}
	var frame_map: Dictionary = _symbol_map[sym_name]
	if frame_map.has(frame_idx):
		return frame_map[frame_idx]
	if frame_map.has(0):
		return frame_map[0]
	if not frame_map.is_empty():
		return frame_map.values()[0]
	return {}

# ─────────────────────────────────────────────────────────
# Animation parser — returns Array of anim dicts
# anim_name akan di-override oleh caller pakai nama file
# ─────────────────────────────────────────────────────────
func _parse_animations(data: Dictionary, fps: float) -> Array:
	var anims: Array = []
	if not data.has("AN"): return anims
	var an = data["AN"]
	var raw_layers: Array = an.get("TL", {}).get("L", [])
	var parsed_layers: Array = []

	for i in range(raw_layers.size()):
		var layer = raw_layers[i]
		var layer_name: String = layer.get("LN", "Layer")
		if layer_name == "CenterMarker": continue

		var frames: Array = []
		for fr in layer.get("FR", []):
			var elems: Array = []
			for elem in fr.get("E", []):
				var e := {}
				if elem.has("SI"):
					e = {
						"type": "symbol",
						"symbol_name": elem["SI"].get("SN", ""),
						"first_frame": int(elem["SI"].get("FF", 0)),
						"m3d": elem["SI"].get("M3D", [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
					}
				elif elem.has("ASI"):
					e = {
						"type": "sprite",
						"sprite_name": str(elem["ASI"].get("N", "")),
						"m3d": elem["ASI"].get("M3D", [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
					}
				if not e.is_empty(): elems.append(e)
			frames.append({
				"index": int(fr.get("I", 0)),
				"duration": int(fr.get("DU", 1)),
				"elements": elems
			})

		parsed_layers.append({
			"name": layer_name,
			"layer_idx": i,
			"frames": frames
		})

	var max_frame := 0
	for layer in parsed_layers:
		for fr in layer["frames"]:
			max_frame = max(max_frame, int(fr["index"]) + int(fr["duration"]))
	var anim_length := maxf(max_frame / fps, 1.0 / fps)
	anims.append({
		"anim_name": an.get("SN", an.get("N", "animation")),
		"layers": parsed_layers,
		"fps": fps,
		"length": anim_length
	})
	return anims

# ─────────────────────────────────────────────────────────
# Decompose M3D
# ─────────────────────────────────────────────────────────
func _decompose_m3d(m) -> Dictionary:
	if m is Dictionary:
		m = _matrix_dict_to_array(m)
	if not m is Array:
		m = [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]

	var a := 1.0
	var b := 0.0
	var c := 0.0
	var d := 1.0
	var tx := 0.0
	var ty := 0.0

	if m.size() >= 16:
		a = float(m[0]); b = float(m[1])
		c = float(m[4]); d = float(m[5])
		tx = float(m[12]); ty = float(m[13])
	elif m.size() >= 6:
		a = float(m[0]); b = float(m[1])
		c = float(m[2]); d = float(m[3])
		tx = float(m[4]); ty = float(m[5])

	var sx := sqrt(a*a + b*b)
	var sy := sqrt(c*c + d*d)
	if (a*d - b*c) < 0.0: sy = -sy
	return {
		"pos":   Vector2(tx, ty),
		"rot":   atan2(b, a),
		"scale": Vector2(sx, sy)
	}

# ─────────────────────────────────────────────────────────
# FIX rotasi: normalisasi urutan sudut agar tidak loncat > PI antar frame
# Contoh: [170°, -170°] → [170°, 190°]  (putar 20°, bukan 340°)
# ─────────────────────────────────────────────────────────
func _normalize_angle_sequence(angles: Array) -> Array:
	if angles.size() <= 1: return angles
	var out: Array = angles.duplicate()
	for i in range(1, out.size()):
		var prev: float = out[i - 1]
		var curr: float = out[i]
		var diff: float = angle_difference(prev, curr)
		out[i] = prev + diff
	return out

# ─────────────────────────────────────────────────────────
# Build scene — MULTI-ANIMATION
#
# Key node tetap "afi#layer_idx" (TIDAK diubah ke nama).
# Alasan: satu nama layer bisa muncul lebih dari sekali dalam satu file
# (misal "leg_arm" duplikat 4x), masing-masing harus node terpisah.
# Shared texture atlas sudah ditangani lewat region_rect keyframe.
# ─────────────────────────────────────────────────────────
func _create_scene_tree(sprites: Dictionary, texture: Texture2D,
						all_animations: Array,
						use_pivot_wrappers: bool = true, add_skin_swapper: bool = true,
						texture_filter_mode: String = "Linear",
						interpolation_mode: String = "Linear") -> Node2D:

	# Load sprite script to handle Vector2 rotation blending
	var spr_script
	var script_path = "res://addons/AATTAAI/AATTAI_sprite.gd"
	if ResourceLoader.exists(script_path):
		spr_script = load(script_path)
	else:
		spr_script = GDScript.new()
		spr_script.source_code = "@tool\nextends Sprite2D\n\n@export var r_vec: Vector2 = Vector2.RIGHT:\n\tset(val):\n\t\tr_vec = val\n\t\tif val != Vector2.ZERO:\n\t\t\trotation = val.angle()\n"
		spr_script.reload()

	var wrapper_script
	var wrapper_script_path = "res://addons/AATTAAI/AATTAI_wrapper.gd"
	if ResourceLoader.exists(wrapper_script_path):
		wrapper_script = load(wrapper_script_path)
	else:
		wrapper_script = GDScript.new()
		wrapper_script.source_code = "@tool\nextends Node2D\n\n@export var r_vec: Vector2 = Vector2.RIGHT:\n\tset(val):\n\t\tr_vec = val\n\t\tif val != Vector2.ZERO:\n\t\t\trotation = val.angle()\n"
		wrapper_script.reload()

	var root := Node2D.new()
	root.name = "AnimatedCharacter"

	# Feature 10: Texture Filter
	if texture_filter_mode == "Nearest" or texture_filter_mode == "Nearest (Pixel Art)":
		root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	else:
		root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	# Feature 7: Add Visual Controller & Skin Swapper Script
	if add_skin_swapper:
		var controller_script
		var controller_path = "res://addons/AATTAAI/AATTAI_controller.gd"
		if ResourceLoader.exists(controller_path):
			controller_script = load(controller_path)
		else:
			controller_script = GDScript.new()
			controller_script.source_code = "@tool\nextends Node2D\n\n@export_file(\"*.png\") var skin_texture: String = \"\":\n\tset(val):\n\t\tskin_texture = val\n\t\tif val != \"\":\n\t\t\tvar tex: Texture2D = null\n\t\t\tif ResourceLoader.exists(val):\n\t\t\t\ttex = ResourceLoader.load(val) as Texture2D\n\t\t\telif FileAccess.file_exists(val):\n\t\t\t\tvar img := Image.new()\n\t\t\t\tif img.load(val) == OK:\n\t\t\t\t\ttex = ImageTexture.create_from_image(img)\n\t\t\tif tex is Texture2D:\n\t\t\t\tchange_skin(tex)\n\nfunc change_skin(new_texture: Texture2D) -> void:\n\tif new_texture == null:\n\t\treturn\n\t_apply_skin_recursive(self, new_texture)\n\nfunc _apply_skin_recursive(node: Node, new_texture: Texture2D) -> void:\n\tfor child in node.get_children():\n\t\tif child is Sprite2D:\n\t\t\tchild.texture = new_texture\n\t\tif child.get_child_count() > 0:\n\t\t\t_apply_skin_recursive(child, new_texture)\n"
			controller_script.reload()
		root.set_script(controller_script)

	var anim_player := AnimationPlayer.new()
	anim_player.name = "AnimationPlayer"
	root.add_child(anim_player)
	anim_player.owner = root

	var anim_lib := AnimationLibrary.new()

	# ── Pass 1: kumpulkan semua layer unik dari semua animasi ──────────────
	# Key: sanitized layer_name — shared across animations dengan nama layer sama.
	# Layer berbeda nama tetap node berbeda. Kalau dua animasi punya "arm",
	# mereka share satu Sprite2D yang sama (tidak duplikat).
	# Edge-case: layer dengan nama identik DALAM satu animasi (misal "leg" x4)
	# tetap dipisah pakai suffix "#layer_idx".
	var layer_node_map: Dictionary = {}  # key → Node2D (wrapper atau Sprite2D)
	# Juga simpan mapping key per (afi, layer_idx) untuk lookup di Pass 2
	var anim_layer_key: Dictionary = {}  # "afi#lidx" → node_key
	var ordered_keys: Array[String] = []

	for afi in range(all_animations.size()):
		var anim = all_animations[afi]
		# Lacak nama yang sudah dipakai dalam animasi ini untuk deteksi duplikat
		var names_in_anim: Dictionary = {}
		for layer in anim["layers"]:
			var base_name := _sanitize_node_name(layer["name"])
			var node_key: String
			if base_name in names_in_anim:
				# Nama duplikat dalam animasi yang sama → pisah per layer_idx
				node_key = base_name + "#" + str(layer["layer_idx"])
			else:
				node_key = base_name
				names_in_anim[base_name] = true
			anim_layer_key[str(afi) + "#" + str(layer["layer_idx"])] = node_key

			if not layer_node_map.has(node_key):
				layer_node_map[node_key] = null
				ordered_keys.append(node_key)

	# Tambahkan node ke root dalam urutan terbalik (back-to-front) agar sesuai draw order di Godot
	for i in range(ordered_keys.size() - 1, -1, -1):
		var node_key: String = ordered_keys[i]
		# Pastikan nama node unik di scene tree
		var final_name: String = node_key
		var counter := 2
		while root.has_node(NodePath(final_name)):
			final_name = node_key + str(counter)
			counter += 1

		var init_info := _get_initial_sprite_info(node_key, all_animations)
		var init_sp_name: String = init_info.get("sprite", "")

		if use_pivot_wrappers:
			# Feature 3: Use Pivot Wrapper nodes
			var wrapper := Node2D.new()
			wrapper.set_script(wrapper_script)
			wrapper.name = final_name
			root.add_child(wrapper)
			wrapper.owner = root

			var spr := Sprite2D.new()
			spr.name = "Sprite"
			spr.texture = texture
			spr.centered = false
			spr.region_enabled = true
			
			if init_sp_name != "" and sprites.has(init_sp_name):
				var sp = sprites[init_sp_name]
				spr.region_rect = Rect2(sp["x"], sp["y"], sp["w"], sp["h"])
			if init_info.has("pos"):
				spr.position = init_info["pos"]
				spr.rotation = init_info.get("rot", 0.0)
				spr.scale = init_info.get("scale", Vector2.ONE)
			
			wrapper.add_child(spr)
			spr.owner = root

			layer_node_map[node_key] = wrapper
		else:
			var spr := Sprite2D.new()
			spr.set_script(spr_script)
			spr.name = final_name
			spr.texture = texture
			spr.centered = false
			spr.region_enabled = true
			
			if init_sp_name != "" and sprites.has(init_sp_name):
				var sp = sprites[init_sp_name]
				spr.region_rect = Rect2(sp["x"], sp["y"], sp["w"], sp["h"])
			if init_info.has("pos"):
				spr.offset = init_info["pos"]
				
			root.add_child(spr)
			spr.owner = root

			layer_node_map[node_key] = spr

	# ── Pass 2: build tiap animasi ──────────────────────────────────────────
	for afi in range(all_animations.size()):
		var anim = all_animations[afi]
		var fps: float = anim["fps"]
		var animation := Animation.new()
		animation.loop_mode = Animation.LOOP_LINEAR
		animation.length = maxf(anim["length"], 1.0 / fps)

		# Lacak node mana saja yang aktif di animasi ini
		var active_keys := {}
		for layer in anim["layers"]:
			var lookup := str(afi) + "#" + str(layer["layer_idx"])
			var node_key: String = anim_layer_key.get(lookup, "")
			if node_key != "":
				active_keys[node_key] = true

		# Hide node yang tidak aktif di animasi ini di t = 0
		for node_key in layer_node_map:
			if not active_keys.has(node_key):
				var node: Node = layer_node_map[node_key]
				var npath := node.name
				var t_vis := animation.add_track(Animation.TYPE_VALUE)
				animation.track_set_path(t_vis, NodePath(str(npath) + ":visible"))
				animation.track_set_interpolation_type(t_vis, Animation.INTERPOLATION_NEAREST)
				animation.track_insert_key(t_vis, 0.0, false)

		for layer in anim["layers"]:
			var lookup := str(afi) + "#" + str(layer["layer_idx"])
			var node_key: String = anim_layer_key.get(lookup, "")
			if node_key == "" or not layer_node_map.has(node_key): continue
			var node: Node = layer_node_map[node_key]
			var npath := node.name

			var t_pos    := animation.add_track(Animation.TYPE_VALUE)
			var t_rot    := animation.add_track(Animation.TYPE_VALUE)
			var t_scl    := animation.add_track(Animation.TYPE_VALUE)
			var t_rect   := animation.add_track(Animation.TYPE_VALUE)
			var t_vis    := animation.add_track(Animation.TYPE_VALUE)
			var t_z      := animation.add_track(Animation.TYPE_VALUE)

			var sprite_path = str(npath) + "/Sprite" if use_pivot_wrappers else str(npath)

			animation.track_set_path(t_pos,    NodePath(str(npath) + ":position"))
			animation.track_set_path(t_rot,    NodePath(str(npath) + ":r_vec"))
			animation.track_set_path(t_scl,    NodePath(str(npath) + ":scale"))
			animation.track_set_path(t_rect,   NodePath(sprite_path + ":region_rect"))
			animation.track_set_path(t_vis,    NodePath(str(npath) + ":visible"))
			animation.track_set_path(t_z,      NodePath(str(npath) + ":z_index"))

			var interp_type: Animation.InterpolationType = Animation.INTERPOLATION_LINEAR
			var lower_interp := interpolation_mode.to_lower()
			if lower_interp.contains("nearest") or lower_interp.contains("stepped"):
				interp_type = Animation.INTERPOLATION_NEAREST
			elif lower_interp.contains("cubic"):
				interp_type = Animation.INTERPOLATION_CUBIC

			animation.track_set_interpolation_type(t_pos,    interp_type)
			animation.track_set_interpolation_type(t_rot,    interp_type)
			animation.track_set_interpolation_type(t_scl,    interp_type)
			animation.track_set_interpolation_type(t_rect,   Animation.INTERPOLATION_NEAREST)
			animation.track_set_interpolation_type(t_vis,    Animation.INTERPOLATION_NEAREST)
			animation.track_set_interpolation_type(t_z,      Animation.INTERPOLATION_NEAREST)

			var t_offset := -1

			if not use_pivot_wrappers:
				t_offset = animation.add_track(Animation.TYPE_VALUE)
				animation.track_set_path(t_offset, NodePath(sprite_path + ":offset"))
				animation.track_set_interpolation_type(t_offset, Animation.INTERPOLATION_NEAREST)

			# Kumpulkan keyframe dulu, normalisasi rotasi, lalu insert
			var kf_times:  Array = []
			var kf_pos:    Array = []
			var kf_rot:    Array = []
			var kf_scl:    Array = []
			var kf_rect:   Array = []
			var kf_sprite_pos: Array = []
			var kf_sprite_rot: Array = []
			var kf_sprite_scl: Array = []
			var kf_offset: Array = []
			var kf_vis:    Array = []

			# Lacak status visibilitas per frame
			var frame_activity := {}
			for fr in layer["frames"]:
				var fi := int(fr["index"])
				var du := int(fr["duration"])
				var active: bool = not fr["elements"].is_empty()
				for f_idx in range(fi, fi + du):
					frame_activity[f_idx] = active

			var total_frames := int(round(anim["length"] * fps))
			var last_vis_state := false
			if frame_activity.has(0):
				last_vis_state = frame_activity[0]
			else:
				last_vis_state = false
			kf_vis.append({"t": 0.0, "v": last_vis_state})

			for f_idx in range(1, total_frames):
				var current_state := false
				if frame_activity.has(f_idx):
					current_state = frame_activity[f_idx]
				else:
					current_state = false
				
				if current_state != last_vis_state:
					kf_vis.append({"t": f_idx / fps, "v": current_state})
					last_vis_state = current_state

			var last_rect_val = null
			var last_offset_val = null

			for fr in layer["frames"]:
				var fi   := int(fr["index"])
				var time := fi / fps
				var elems: Array = fr["elements"]
				if elems.is_empty(): continue

				for elem in elems:
					var m: Array = elem.get("m3d", [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
					var dec := _decompose_m3d(m)
					kf_times.append(time)
					kf_pos.append(dec["pos"])
					kf_rot.append(dec["rot"])
					kf_scl.append(dec["scale"])

					var sprite_pos := Vector2.ZERO
					var sprite_rot := 0.0
					var sprite_scale := Vector2.ONE
					var sprite_name := ""
					if elem.get("type") == "sprite":
						sprite_name = elem.get("sprite_name", "")
					elif elem.get("type") == "symbol":
						var ff = elem.get("first_frame", 0)
						var info := _resolve_symbol(elem.get("symbol_name", ""), ff)
						if not info.is_empty():
							sprite_name = info["sprite"]
							if info.has("pos"):
								sprite_pos = info["pos"]
								sprite_rot = info["rot"]
								sprite_scale = info["scale"]
							else:
								sprite_pos = Vector2(info.get("ox", 0.0), info.get("oy", 0.0))

					if sprite_name != "" and sprites.has(sprite_name):
						var sp = sprites[sprite_name]
						var current_rect := Rect2(sp["x"], sp["y"], sp["w"], sp["h"])
						
						if last_rect_val == null or last_rect_val != current_rect:
							kf_rect.append({"t": time, "v": current_rect})
							last_rect_val = current_rect
						
						if use_pivot_wrappers:
							kf_sprite_pos.append({"t": time, "v": sprite_pos})
							kf_sprite_rot.append({"t": time, "v": sprite_rot})
							kf_sprite_scl.append({"t": time, "v": sprite_scale})
						else:
							var current_offset := sprite_pos
							if last_offset_val == null or last_offset_val != current_offset:
								kf_offset.append({"t": time, "v": current_offset})
								last_offset_val = current_offset
					break

			# Normalisasi urutan sudut sebelum insert ke track
			kf_rot = _normalize_angle_sequence(kf_rot)

			var is_pos_static := true
			if kf_pos.size() > 1:
				var first_pos = kf_pos[0]
				for k in range(1, kf_pos.size()):
					if kf_pos[k] != first_pos:
						is_pos_static = false
						break
			
			var is_rot_static := true
			if kf_rot.size() > 1:
				var first_rot = kf_rot[0]
				for k in range(1, kf_rot.size()):
					if kf_rot[k] != first_rot:
						is_rot_static = false
						break

			var is_scl_static := true
			if kf_scl.size() > 1:
				var first_scl = kf_scl[0]
				for k in range(1, kf_scl.size()):
					if kf_scl[k] != first_scl:
						is_scl_static = false
						break

			if is_pos_static and kf_pos.size() > 0:
				animation.track_insert_key(t_pos, 0.0, kf_pos[0])
			else:
				for i in range(kf_times.size()):
					animation.track_insert_key(t_pos, kf_times[i], kf_pos[i])

			if is_rot_static and kf_rot.size() > 0:
				var angle: float = kf_rot[0]
				var v := Vector2(cos(angle), sin(angle))
				animation.track_insert_key(t_rot, 0.0, v)
			else:
				for i in range(kf_times.size()):
					var angle: float = kf_rot[i]
					var v := Vector2(cos(angle), sin(angle))
					animation.track_insert_key(t_rot, kf_times[i], v)

			if is_scl_static and kf_scl.size() > 0:
				animation.track_insert_key(t_scl, 0.0, kf_scl[0])
			else:
				for i in range(kf_times.size()):
					animation.track_insert_key(t_scl, kf_times[i], kf_scl[i])

			for entry in kf_rect:
				animation.track_insert_key(t_rect, entry["t"], entry["v"])
			if not use_pivot_wrappers:
				for entry in kf_offset:
					animation.track_insert_key(t_offset, entry["t"], entry["v"])
			for entry in kf_vis:
				animation.track_insert_key(t_vis, entry["t"], entry["v"])

			var z_val: int = anim["layers"].size() - 1 - int(layer["layer_idx"])
			animation.track_insert_key(t_z, 0.0, z_val)

		var safe_name := _sanitize_anim_name(anim["anim_name"])
		# Hindari nama duplikat di library
		var final_anim_name := safe_name
		var ac := 2
		while anim_lib.has_animation(final_anim_name):
			final_anim_name = safe_name + "_" + str(ac)
			ac += 1
		anim_lib.add_animation(final_anim_name, animation)

	anim_player.add_animation_library("", anim_lib)

	var anim_list := anim_lib.get_animation_list()
	if anim_list.size() > 0:
		anim_player.autoplay = anim_list[0]

	return root

func _build_scene(sprites: Dictionary, texture: Texture2D,
				  all_animations: Array, out_path: String,
				  use_pivot_wrappers: bool = true, add_skin_swapper: bool = true,
				  texture_filter_mode: String = "Linear",
				  interpolation_mode: String = "Linear") -> String:
	var root := _create_scene_tree(sprites, texture, all_animations, use_pivot_wrappers, add_skin_swapper, texture_filter_mode, interpolation_mode)
	if root == null:
		return "Failed to build scene tree."

	var anim_player: AnimationPlayer = root.get_node("AnimationPlayer")
	var anim_list := []
	if anim_player and anim_player.has_animation_library(""):
		anim_list = anim_player.get_animation_library("").get_animation_list()

	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		root.queue_free()
		return "PackedScene.pack() failed."
	_ensure_parent_dir(out_path)
	if ResourceSaver.save(packed, out_path) != OK:
		root.queue_free()
		return "ResourceSaver.save() failed for: " + out_path

	var sprite_count = 0
	for child in root.get_children():
		if child is Sprite2D:
			sprite_count += 1
		elif child is Node2D:
			for gc in child.get_children():
				if gc is Sprite2D:
					sprite_count += 1

	root.queue_free()
	print("[AATAAI] ✅ done!")
	print("  Scene : ", out_path)
	print("  Nodes : ", sprite_count, " Sprite2D/Wrapper")
	print("  Animation: ", anim_list)
	return ""

func import_in_memory(atlas_json_path: String, anim_folder: String,
					  png_path: String, fps_override: int, anim_files: Array = [],
					  selected_animations: Array = [],
					  use_pivot_wrappers: bool = true, add_skin_swapper: bool = true,
					  texture_filter_mode: String = "Linear",
					  interpolation_mode: String = "Linear") -> Node2D:
	_symbol_map.clear()

	var atlas_data = _load_json(atlas_json_path)
	if atlas_data is String: return null
	var sprites: Dictionary = _parse_atlas(atlas_data)
	if sprites.is_empty(): return null

	var texture: Texture2D = _load_texture(png_path)
	if texture == null: return null

	if anim_files.is_empty():
		anim_files = _scan_json_files(anim_folder)
	if anim_files.is_empty(): return null

	var all_animations: Array = _parse_all_animations(anim_files, sprites, fps_override, selected_animations)
	if all_animations.is_empty(): return null

	return _create_scene_tree(sprites, texture, all_animations,
							  use_pivot_wrappers, add_skin_swapper, texture_filter_mode, interpolation_mode)

# ─────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────
func _sanitize_node_name(n: String) -> String:
	var r := n.strip_edges().replace("/", "_").replace(" ", "_").replace(":", "_").replace("-", "_").replace(".", "_").replace("@", "_").replace("%", "_")
	if r.is_empty(): r = "Part"
	if r[0].is_valid_int(): r = "p_" + r
	return r

func _sanitize_anim_name(n: String) -> String:
	var r := n.strip_edges().replace(" ", "_").replace("/", "_").replace(":", "_").replace("-", "_").replace(".", "_").replace("@", "_").replace("%", "_")
	if r.is_empty(): r = "animation"
	if r[0].is_valid_int(): r = "anim_" + r
	return r

func _ensure_parent_dir(path: String) -> void:
	var base_dir := path.get_base_dir()
	if not base_dir.is_empty() and not DirAccess.dir_exists_absolute(base_dir):
		DirAccess.make_dir_recursive_absolute(base_dir)

