@tool
extends Node2D

@export_file("*.json") var atlas_json_path: String = ""
@export_file("*.json") var animation_json_path: String = ""
@export_dir var animation_folder_path: String = ""
@export_file("*.png")  var png_path: String = ""
@export_file("*.png")  var skin_texture: String = "":
	set(val):
		skin_texture = val
		if val != "":
			var tex: Texture2D = _load_texture(val)
			if tex is Texture2D:
				change_skin(tex)
@export var fps_override: int = 0
@export var auto_play: String = ""
@export var add_skin_swapper: bool = true
@export_enum("Linear", "Nearest") var texture_filter_mode: String = "Linear"
@export_enum("Linear", "Nearest", "Cubic") var interpolation_mode: String = "Linear"

var use_pivot_wrappers: bool = true

var _sprites: Dictionary = {}
var _symbol_map: Dictionary = {}
var _texture: Texture2D

func change_skin(new_texture: Texture2D) -> void:
	if new_texture == null:
		return
	_texture = new_texture
	_apply_skin_recursive(self, new_texture)

func change_skin_from_path(path: String) -> void:
	var tex: Texture2D = _load_texture(path)
	if tex:
		change_skin(tex)

func _apply_skin_recursive(node: Node, new_texture: Texture2D) -> void:
	for child in node.get_children():
		if child is Sprite2D:
			child.texture = new_texture
		if child.get_child_count() > 0:
			_apply_skin_recursive(child, new_texture)

func _ready() -> void:
	if atlas_json_path and png_path and (animation_json_path or animation_folder_path):
		await build(atlas_json_path, animation_json_path, png_path, animation_folder_path,
			  use_pivot_wrappers, add_skin_swapper, texture_filter_mode, interpolation_mode)
		if auto_play != "" and has_node("AnimationPlayer"):
			$AnimationPlayer.play(auto_play)

func build(atlas_path: String, anim_path: String, tex_path: String, anim_folder: String = "",
		   p_use_pivot_wrappers: bool = true, p_add_skin_swapper: bool = true,
		   p_texture_filter_mode: String = "Linear",
		   p_interpolation_mode: String = "Linear") -> void:
	var atlas_data = _load_json(atlas_path)
	if atlas_data == null:
		push_error("[AATAIRuntime] cannot load atlas JSON")
		return

	_sprites = _parse_atlas(atlas_data)
	
	# Scan for anim files
	var anim_files: Array = []
	if not anim_path.is_empty():
		if DirAccess.dir_exists_absolute(anim_path):
			anim_files = _scan_json_files(anim_path)
		else:
			anim_files = [anim_path]
	elif not anim_folder.is_empty() and DirAccess.dir_exists_absolute(anim_folder):
		anim_files = _scan_json_files(anim_folder)

	if anim_files.is_empty():
		push_error("[AATAIRuntime] no animation JSON files found")
		return

	# Load texture
	_texture = _load_texture(tex_path)
	if _texture == null:
		push_error("[AATAIRuntime] Texture not found: " + tex_path)
		return

	# Clear old children except AnimationPlayer
	for c in get_children():
		if not c is AnimationPlayer: c.queue_free()
	await get_tree().process_frame  # wait for queue_free

	var ap: AnimationPlayer
	if has_node("AnimationPlayer"):
		ap = $AnimationPlayer
	else:
		ap = AnimationPlayer.new()
		ap.name = "AnimationPlayer"
		add_child(ap)
		if Engine.is_editor_hint():
			ap.owner = get_tree().edited_scene_root

	# Parse all animations and accumulate symbol map
	_symbol_map.clear()
	var all_animations: Array = []
	for json_path in anim_files:
		var anim_data = _load_json(json_path)
		if anim_data == null or anim_data is String or _is_atlas_json(anim_data):
			continue
		
		_build_symbol_map(anim_data)
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
				var virtual_anim_data: Dictionary = {
					"AN": {
						"N": anim_data.get("AN", {}).get("N", "character"),
						"SN": anim_name,
						"TL": anim_sym.get("TL", {})
					},
					"SD": anim_data.get("SD", {})
				}
				var parsed := _parse_animations(virtual_anim_data)
				for anim in parsed:
					anim["name"] = anim_name
					all_animations.append(anim)

		if not has_master:
			var root_name: String = ""
			if anim_data.has("AN"):
				root_name = str(anim_data.get("AN", {}).get("SN", anim_data.get("AN", {}).get("N", ""))).strip_edges()
			if root_name.is_empty():
				root_name = (json_path as String).get_file().get_basename()
			var parsed := _parse_animations(anim_data)
			for anim in parsed:
				anim["name"] = root_name
				all_animations.append(anim)

	if all_animations.is_empty():
		push_error("[AATAIRuntime] all animation JSON files failed to parse")
		return

	var lib := AnimationLibrary.new()

	# Feature 10: Texture Filter
	if p_texture_filter_mode == "Nearest":
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	else:
		texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	# Load sprite script to handle Vector2 rotation blending
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

	# Create parts
	var layer_nodes: Dictionary = {} # key -> Node (wrapper Node2D or Sprite2D)
	var anim_layer_key: Dictionary = {}

	for ai in range(all_animations.size()):
		var anim_names_used: Dictionary = {}
		for layer in all_animations[ai]["layers"]:
			var base := _sanitize(layer["name"])
			var node_key: String
			if base in anim_names_used:
				node_key = base + "#" + str(layer["layer_idx"])
			else:
				node_key = base
				anim_names_used[base] = true
			anim_layer_key[str(ai) + "#" + str(layer["layer_idx"])] = node_key

			if node_key in layer_nodes: continue

			var fname := node_key; var c2 := 2
			while has_node(NodePath(fname)):
				fname = node_key + str(c2); c2 += 1

			var init_info := _get_initial_sprite_info(node_key, all_animations)
			var init_sp_name: String = init_info.get("sprite", "")

			if p_use_pivot_wrappers:
				# Feature 3: Use Pivot Wrapper nodes
				var wrapper := Node2D.new()
				wrapper.set_script(wrapper_script)
				wrapper.name = fname
				add_child(wrapper)
				if Engine.is_editor_hint() and get_tree().edited_scene_root:
					wrapper.owner = get_tree().edited_scene_root

				var spr := Sprite2D.new()
				spr.name = "Sprite"
				spr.texture = _texture
				spr.centered = false
				spr.region_enabled = true
				
				if init_sp_name != "" and _sprites.has(init_sp_name):
					var sp = _sprites[init_sp_name]
					spr.region_rect = Rect2(sp.get("x", 0), sp.get("y", 0), sp.get("w", 1), sp.get("h", 1))
				if init_info.has("pos"):
					spr.position = init_info["pos"]
					spr.rotation = init_info.get("rot", 0.0)
					spr.scale = init_info.get("scale", Vector2.ONE)
				
				wrapper.add_child(spr)
				if Engine.is_editor_hint() and get_tree().edited_scene_root:
					spr.owner = get_tree().edited_scene_root

				layer_nodes[node_key] = wrapper
			else:
				var spr := Sprite2D.new()
				spr.set_script(spr_script)
				spr.name = fname
				spr.texture = _texture
				spr.centered = false
				spr.region_enabled = true
				
				if init_sp_name != "" and _sprites.has(init_sp_name):
					var sp = _sprites[init_sp_name]
					spr.region_rect = Rect2(sp.get("x", 0), sp.get("y", 0), sp.get("w", 1), sp.get("h", 1))
				if init_info.has("pos"):
					spr.offset = init_info["pos"]
					
				add_child(spr)
				if Engine.is_editor_hint() and get_tree().edited_scene_root:
					spr.owner = get_tree().edited_scene_root
				layer_nodes[node_key] = spr

	# Build animations
	for ai in range(all_animations.size()):
		var anim = all_animations[ai]
		var fps: float = anim["fps"]
		var animation := Animation.new()
		animation.loop_mode = Animation.LOOP_LINEAR
		animation.length = maxf(anim["length"], 1.0 / fps)

		# Active nodes set
		var active_keys := {}
		for layer in anim["layers"]:
			var lookup := str(ai) + "#" + str(layer["layer_idx"])
			var node_key: String = anim_layer_key.get(lookup, "")
			if node_key != "":
				active_keys[node_key] = true

		# Hide inactive nodes at t = 0
		for node_key in layer_nodes:
			if not active_keys.has(node_key):
				var node: Node = layer_nodes[node_key]
				var np := node.name
				var t_vis := animation.add_track(Animation.TYPE_VALUE)
				animation.track_set_path(t_vis, NodePath(str(np) + ":visible"))
				animation.track_set_interpolation_type(t_vis, Animation.INTERPOLATION_NEAREST)
				animation.track_insert_key(t_vis, 0.0, false)

		for layer in anim["layers"]:
			var lookup := str(ai) + "#" + str(layer["layer_idx"])
			var nk: String = anim_layer_key.get(lookup, "")
			if nk == "" or not layer_nodes.has(nk): continue
			var node: Node = layer_nodes[nk]
			var np := node.name

			var tp  := animation.add_track(Animation.TYPE_VALUE)
			var tr  := animation.add_track(Animation.TYPE_VALUE)
			var ts  := animation.add_track(Animation.TYPE_VALUE)
			var trc := animation.add_track(Animation.TYPE_VALUE)
			var t_vis := animation.add_track(Animation.TYPE_VALUE)
			var t_z   := animation.add_track(Animation.TYPE_VALUE)

			var sprite_path = str(np) + "/Sprite" if p_use_pivot_wrappers else str(np)

			animation.track_set_path(tp,  NodePath(str(np)+":position"))
			animation.track_set_path(tr,  NodePath(str(np)+":r_vec"))
			animation.track_set_path(ts,  NodePath(str(np)+":scale"))
			animation.track_set_path(trc, NodePath(sprite_path+":region_rect"))
			animation.track_set_path(t_vis, NodePath(str(np)+":visible"))
			animation.track_set_path(t_z,   NodePath(str(np)+":z_index"))

			var interp_type: Animation.InterpolationType = Animation.INTERPOLATION_LINEAR
			var lower_interp := p_interpolation_mode.to_lower()
			if lower_interp.contains("nearest") or lower_interp.contains("stepped"):
				interp_type = Animation.INTERPOLATION_NEAREST
			elif lower_interp.contains("cubic"):
				interp_type = Animation.INTERPOLATION_CUBIC

			animation.track_set_interpolation_type(tp,  interp_type)
			animation.track_set_interpolation_type(tr,  interp_type)
			animation.track_set_interpolation_type(ts,  interp_type)
			animation.track_set_interpolation_type(trc, Animation.INTERPOLATION_NEAREST)
			animation.track_set_interpolation_type(t_vis, Animation.INTERPOLATION_NEAREST)
			animation.track_set_interpolation_type(t_z,   Animation.INTERPOLATION_NEAREST)

			var to_ := -1

			if not p_use_pivot_wrappers:
				to_ = animation.add_track(Animation.TYPE_VALUE)
				animation.track_set_path(to_, NodePath(sprite_path+":offset"))
				animation.track_set_interpolation_type(to_, Animation.INTERPOLATION_NEAREST)

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
				var fi := int(fr["index"])
				var t  := fi / fps
				var elems: Array = fr["elements"]
				if elems.is_empty(): continue

				for elem in elems:
					var d := _decompose(elem.get("m3d", [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]))
					kf_times.append(t)
					kf_pos.append(d["pos"])
					kf_rot.append(d["rot"])
					kf_scl.append(d["scale"])

					var sprite_pos := Vector2.ZERO
					var sprite_rot := 0.0
					var sprite_scale := Vector2.ONE
					var sname := ""
					if elem.get("type") == "sprite":
						sname = elem.get("sprite_name", "")
					elif elem.get("type") == "symbol":
						var ff = elem.get("first_frame", 0)
						var info := _resolve(elem.get("symbol_name", ""), ff)
						if not info.is_empty():
							sname = info["sprite"]
							if info.has("pos"):
								sprite_pos = info["pos"]
								sprite_rot = info["rot"]
								sprite_scale = info["scale"]
							else:
								sprite_pos = Vector2(info.get("ox", 0.0), info.get("oy", 0.0))
					if sname != "" and _sprites.has(sname):
						var sp = _sprites[sname]
						var current_rect := Rect2(sp.get("x", 0), sp.get("y", 0), sp.get("w", 1), sp.get("h", 1))
						
						if last_rect_val == null or last_rect_val != current_rect:
							kf_rect.append({"t": t, "v": current_rect})
							last_rect_val = current_rect
						
						if p_use_pivot_wrappers:
							kf_sprite_pos.append({"t": t, "v": sprite_pos})
							kf_sprite_rot.append({"t": t, "v": sprite_rot})
							kf_sprite_scl.append({"t": t, "v": sprite_scale})
						else:
							var current_offset := sprite_pos
							if last_offset_val == null or last_offset_val != current_offset:
								kf_offset.append({"t": t, "v": current_offset})
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
				animation.track_insert_key(tp, 0.0, kf_pos[0])
			else:
				for i in range(kf_times.size()):
					animation.track_insert_key(tp, kf_times[i], kf_pos[i])

			if is_rot_static and kf_rot.size() > 0:
				var angle: float = kf_rot[0]
				var v := Vector2(cos(angle), sin(angle))
				animation.track_insert_key(tr, 0.0, v)
			else:
				for i in range(kf_times.size()):
					var angle: float = kf_rot[i]
					var v := Vector2(cos(angle), sin(angle))
					animation.track_insert_key(tr, kf_times[i], v)

			if is_scl_static and kf_scl.size() > 0:
				animation.track_insert_key(ts, 0.0, kf_scl[0])
			else:
				for i in range(kf_times.size()):
					animation.track_insert_key(ts, kf_times[i], kf_scl[i])

			for entry in kf_rect:
				animation.track_insert_key(trc, entry["t"], entry["v"])
			if not p_use_pivot_wrappers:
				for entry in kf_offset:
					animation.track_insert_key(to_, entry["t"], entry["v"])
			for entry in kf_vis:
				animation.track_insert_key(t_vis, entry["t"], entry["v"])

			var z_val: int = anim["layers"].size() - 1 - int(layer["layer_idx"])
			animation.track_insert_key(t_z, 0.0, z_val)

		var safe_name := _sanim(anim["name"])
		var final_anim_name := safe_name
		var ac := 2
		while lib.has_animation(final_anim_name):
			final_anim_name = safe_name + "_" + str(ac)
			ac += 1
		lib.add_animation(final_anim_name, animation)

	ap.add_animation_library("", lib)
	if lib.get_animation_list().size() > 0 and auto_play.is_empty():
		ap.autoplay = lib.get_animation_list()[0]
	print("[AATAAIRuntime] Done. Parts: %d, Animations: %d" % [layer_nodes.size(), all_animations.size()])

# ── helpers ──────────────────────────────────────────────
func _load_json(path: String):
	if not FileAccess.file_exists(path): return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null: return null
	var text := f.get_as_text(); f.close()
	if text.begins_with("\ufeff"): text = text.substr(1)
	var result = JSON.parse_string(text)
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

func _parse_atlas(data: Dictionary) -> Dictionary:
	var r := {}
	var arr: Array = data.get("ATLAS", {}).get("SPRITES", data.get("sprites",[]))
	for e in arr:
		var sp = e.get("SPRITE", e)
		var n := str(sp.get("name",""))
		r[n] = {x=int(sp.get("x",0)), y=int(sp.get("y",0)), w=int(sp.get("w",1)), h=int(sp.get("h",1))}
	return r

func _get_fps(data: Dictionary) -> float:
	if data.has("MD") and data["MD"].has("FRT"): return float(data["MD"]["FRT"])
	if data.has("AN") and data["AN"].get("MD",{}).has("FRT"): return float(data["AN"]["MD"]["FRT"])
	return 24.0

func _build_symbol_map(data: Dictionary) -> void:
	for sym in data.get("SD", {}).get("S", []):
		var sn: String = sym.get("SN","")
		if sn.is_empty(): continue
		if _symbol_map.has(sn): continue
		
		var frame_map := {}
		for layer in sym.get("TL",{}).get("L",[]):
			if layer.get("LN","") == "CenterMarker": continue
			for fr in layer.get("FR",[]):
				var frame_idx := int(fr.get("I", 0))
				for elem in fr.get("E",[]):
					if not elem.has("ASI"): continue
					var asi = elem["ASI"]
					var sp_name := str(asi.get("N",""))
					if sp_name.is_empty() or not _sprites.has(sp_name): continue
					var m: Array = asi.get("M3D",[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
					var dec := _decompose(m)
					frame_map[frame_idx] = {
						"sprite": sp_name,
						"pos": dec["pos"],
						"rot": dec["rot"],
						"scale": dec["scale"]
					}
					break
		if not frame_map.is_empty():
			_symbol_map[sn] = frame_map

func _resolve(sym: String, frame_idx: int = 0) -> Dictionary:
	if not _symbol_map.has(sym):
		return {}
	var frame_map: Dictionary = _symbol_map[sym]
	if frame_map.has(frame_idx):
		return frame_map[frame_idx]
	if frame_map.has(0):
		return frame_map[0]
	if not frame_map.is_empty():
		return frame_map.values()[0]
	return {}

func _parse_animations(data: Dictionary) -> Array:
	var anims := []
	if not data.has("AN"): return anims
	var an = data["AN"]
	var parsed_layers := []
	var raw = an.get("TL",{}).get("L",[])
	for i in range(raw.size()):
		var layer = raw[i]
		if layer.get("LN","") == "CenterMarker": continue
		var frames := []
		for fr in layer.get("FR",[]):
			var elems := []
			for elem in fr.get("E",[]):
				var e := {}
				if elem.has("SI"):
					e = {"type":"symbol","symbol_name":elem["SI"].get("SN",""),"first_frame":int(elem["SI"].get("FF",0)),"m3d":elem["SI"].get("M3D",[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])}
				elif elem.has("ASI"):
					e = {"type":"sprite","sprite_name":str(elem["ASI"].get("N","")),"m3d":elem["ASI"].get("M3D",[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])}
				if not e.is_empty(): elems.append(e)
			frames.append({"index":int(fr.get("I",0)),"duration":int(fr.get("DU",1)),"elements":elems})
		parsed_layers.append({"name":layer.get("LN","Layer"),"layer_idx":i,"frames":frames})
	
	var max_frame := 0
	for layer in parsed_layers:
		for fr in layer["frames"]:
			max_frame = max(max_frame, int(fr["index"]) + int(fr["duration"]))
	
	var fps := float(fps_override) if fps_override > 0 else _get_fps(data)
	anims.append({
		"name": an.get("SN", an.get("N", "animation")),
		"layers": parsed_layers,
		"fps": fps,
		"length": max_frame / fps
	})
	return anims

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

func _decompose(m) -> Dictionary:
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

func _normalize_angle_sequence(angles: Array) -> Array:
	if angles.size() <= 1: return angles
	var out: Array = angles.duplicate()
	for i in range(1, out.size()):
		var prev: float = out[i - 1]
		var curr: float = out[i]
		var diff: float = angle_difference(prev, curr)
		out[i] = prev + diff
	return out

func _sanitize(s: String) -> String:
	var r := s.strip_edges().replace("/", "_").replace(" ", "_").replace(":", "_").replace("-", "_").replace(".", "_").replace("@", "_").replace("%", "_")
	if r.is_empty(): r = "Part"
	if r[0].is_valid_int(): r = "p_" + r
	return r

func _sanim(s: String) -> String:
	var r := s.strip_edges().replace(" ", "_").replace("/", "_").replace(":", "_").replace("-", "_").replace(".", "_").replace("@", "_").replace("%", "_")
	if r.is_empty(): r = "animation"
	if r[0].is_valid_int(): r = "anim_" + r
	return r

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

func _is_atlas_json(data: Dictionary) -> bool:
	return data.has("ATLAS") or data.has("sprites") or data.has("SPRITES")

func _has_timeline_animation(tl: Dictionary) -> bool:
	for layer in tl.get("L", []):
		if layer.get("LN", "") == "CenterMarker": continue
		for fr in layer.get("FR", []):
			if not fr.get("E", []).is_empty():
				return true
	return false

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
			var base_name := _sanitize(layer.get("name", ""))
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
							var info = _resolve(sym, ff)
							if not info.is_empty():
								return info
	return {}
