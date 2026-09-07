@tool
class_name AATTAIController
extends Node2D

## Signals relay from AnimationPlayer & Skin events
signal animation_finished(anim_name: StringName)
signal animation_started(anim_name: StringName)
signal skin_changed(new_texture: Texture2D)
signal slot_changed(slot_name: String, new_texture: Texture2D)

## Global character atlas texture
@export_file("*.png") var skin_texture: String = "":
	set(val):
		skin_texture = val
		if val != "":
			var tex: Texture2D = _load_tex(val)
			if tex is Texture2D:
				change_skin(tex)

var _global_skin_texture: Texture2D = null
var _slot_overrides: Dictionary = {} # slot_name (lowercase) -> Texture2D
var _slot_attachments: Dictionary = {} # slot_name (lowercase) -> Node

@onready var _anim_player: AnimationPlayer = _find_anim_player()

func _ready() -> void:
	_init_anim_player()
	if _global_skin_texture == null:
		_global_skin_texture = _detect_initial_skin_texture(self)

func _detect_initial_skin_texture(node: Node) -> Texture2D:
	for child in node.get_children():
		if child is Sprite2D and child.texture != null:
			return child.texture
		if child.get_child_count() > 0:
			var sub_tex := _detect_initial_skin_texture(child)
			if sub_tex != null:
				return sub_tex
	return null

func _find_anim_player() -> AnimationPlayer:
	if has_node("AnimationPlayer"):
		return get_node("AnimationPlayer") as AnimationPlayer
	for child in get_children():
		if child is AnimationPlayer:
			return child
	return null

func _init_anim_player() -> void:
	if _anim_player == null:
		_anim_player = _find_anim_player()
	if _anim_player:
		if not _anim_player.animation_finished.is_connected(_on_anim_finished):
			_anim_player.animation_finished.connect(_on_anim_finished)
		if not _anim_player.animation_started.is_connected(_on_anim_started):
			_anim_player.animation_started.connect(_on_anim_started)

func _on_anim_finished(anim_name: StringName) -> void:
	animation_finished.emit(anim_name)

func _on_anim_started(anim_name: StringName) -> void:
	animation_started.emit(anim_name)

# ============================================================
# GLOBAL SKIN (ATLAS SWAP)
# ============================================================

## Change global character skin using a Texture2D atlas
func change_skin(new_texture: Texture2D) -> void:
	if new_texture == null:
		return
	_global_skin_texture = new_texture
	_apply_skin_recursive(self, new_texture)
	skin_changed.emit(new_texture)

## Change global character skin using file path (e.g. "res://skins/hero_blue.png")
func change_skin_from_path(path: String) -> void:
	var tex: Texture2D = _load_tex(path)
	if tex:
		change_skin(tex)

## Get currently active global skin texture
func get_global_skin() -> Texture2D:
	return _global_skin_texture

func _apply_skin_recursive(node: Node, new_texture: Texture2D) -> void:
	for child in node.get_children():
		var part_name := child.name.to_lower()
		var is_overridden := false
		for s_name in _slot_overrides:
			if s_name in part_name:
				is_overridden = true
				break
		if not is_overridden:
			if child is Sprite2D:
				child.texture = new_texture
			if child.get_child_count() > 0:
				_apply_skin_recursive(child, new_texture)

# ============================================================
# MODULAR SLOTS (WEAPONS, COSTUMES, ACCESSORIES)
# ============================================================

## Set custom texture for a specific part/slot (e.g. slot_name = "weapon")
## Set override_region = true if new_texture is a standalone non-atlas sprite
func set_slot_texture(slot_name: String, new_texture: Texture2D, override_region: bool = false) -> bool:
	var part = find_part(slot_name)
	if part == null:
		push_warning("[AATTAIController] Part/Slot not found: %s" % slot_name)
		return false
	
	var spr: Sprite2D = _get_part_sprite(part)
	if spr:
		spr.texture = new_texture
		if override_region:
			spr.region_enabled = false
		_slot_overrides[slot_name.to_lower()] = new_texture
		slot_changed.emit(slot_name, new_texture)
		return true
	return false

## Set custom texture for a specific part/slot from file path
func set_slot_texture_from_path(slot_name: String, path: String, override_region: bool = false) -> bool:
	var tex: Texture2D = _load_tex(path)
	if tex:
		return set_slot_texture(slot_name, tex, override_region)
	return false

## Reset a slot texture back to the default global atlas texture
func reset_slot_texture(slot_name: String) -> void:
	var s_key := slot_name.to_lower()
	if _slot_overrides.has(s_key):
		_slot_overrides.erase(s_key)
	var part = find_part(slot_name)
	if part:
		var spr = _get_part_sprite(part)
		if spr:
			if _global_skin_texture:
				spr.texture = _global_skin_texture
			spr.region_enabled = true

## Reset all overridden slot textures back to global atlas
func reset_all_slots() -> void:
	for s_name in _slot_overrides.keys():
		reset_slot_texture(s_name)
	_slot_overrides.clear()

## Show or hide a specific part/slot
func set_slot_visible(slot_name: String, is_visible: bool) -> void:
	var part = find_part(slot_name)
	if part:
		part.visible = is_visible

# ============================================================
# ATTACHMENT & SOCKET (EQUIP CUSTOM NODES / SCENES FROM GODOT)
# ============================================================

## Attach a custom node (Sprite, Weapon Scene, Hitbox Area2D, GPUParticles2D) to a part/slot.
## Automatically follows bone/part animation.
func equip(slot_name: String, item_node: Node, replace: bool = true) -> Node:
	var target = find_part(slot_name)
	if target:
		if replace:
			clear_slot(slot_name)
		var socket = target.get_node_or_null("Socket")
		if socket == null:
			socket = Node2D.new()
			socket.name = "Socket"
			target.add_child(socket)
		if item_node.get_parent():
			item_node.get_parent().remove_child(item_node)
		socket.add_child(item_node)
		_slot_attachments[slot_name.to_lower()] = item_node
		return item_node
	push_warning("[AATTAIController] Cannot equip, slot not found: %s" % slot_name)
	return null

## Clear attachment from a specific slot
func clear_slot(slot_name: String) -> void:
	var s_key := slot_name.to_lower()
	var target = find_part(slot_name)
	if target:
		var socket = target.get_node_or_null("Socket")
		if socket:
			for c in socket.get_children():
				c.queue_free()
	if _slot_attachments.has(s_key):
		_slot_attachments.erase(s_key)

## Get currently attached node at slot
func get_slot_attachment(slot_name: String) -> Node:
	return _slot_attachments.get(slot_name.to_lower(), null)

# ============================================================
# SMART PART LOOKUP
# ============================================================

## Find part/layer Node2D by logical name (case-insensitive fuzzy match)
func find_part(part_name: String) -> Node2D:
	var query := part_name.to_lower()
	var direct = get_node_or_null(NodePath(part_name))
	if direct is Node2D:
		return direct
	
	# Pass 1: exact and prefix matching
	for child in get_children():
		if child is Node2D and not child is AnimationPlayer:
			var cname := child.name.to_lower()
			if cname == query or cname.begins_with(query + "#") or cname.begins_with(query + "_"):
				return child

	# Pass 2: substring / fuzzy matching
	for child in get_children():
		if child is Node2D and not child is AnimationPlayer:
			var cname := child.name.to_lower()
			if query in cname:
				return child
	return null

func _get_part_sprite(part: Node) -> Sprite2D:
	if part is Sprite2D:
		return part
	if part.has_node("Sprite"):
		var s = part.get_node("Sprite")
		if s is Sprite2D:
			return s
	for c in part.get_children():
		if c is Sprite2D:
			return c
	return null

# ============================================================
# ANIMATION PLAYBACK CONTROLS
# ============================================================

## Play animation by name
func play_anim(anim_name: String, custom_blend: float = -1.0, custom_speed: float = 1.0, from_end: bool = false) -> void:
	_init_anim_player()
	if _anim_player:
		_anim_player.play(anim_name, custom_blend, custom_speed, from_end)

## Play animation backwards
func play_backwards(anim_name: String, custom_blend: float = -1.0) -> void:
	_init_anim_player()
	if _anim_player:
		_anim_player.play_backwards(anim_name, custom_blend)

## Pause current animation
func pause_anim() -> void:
	if _anim_player:
		_anim_player.pause()

## Resume current animation
func resume_anim() -> void:
	if _anim_player and _anim_player.assigned_animation != "":
		_anim_player.play()

## Stop animation playback
func stop_anim(keep_state: bool = false) -> void:
	if _anim_player:
		_anim_player.stop(keep_state)

## Check if animation is playing
func is_playing() -> bool:
	return _anim_player.is_playing() if _anim_player else false

## Get current playing animation name
func get_current_animation() -> String:
	return _anim_player.current_animation if _anim_player else ""

## Get list of available animations
func get_animation_list() -> PackedStringArray:
	return _anim_player.get_animation_list() if _anim_player else PackedStringArray()

## Set animation playback speed scale
func set_anim_speed(speed: float) -> void:
	if _anim_player:
		_anim_player.speed_scale = speed

## Flip horizontal facing direction
func flip_h(is_flipped: bool) -> void:
	scale.x = -abs(scale.x) if is_flipped else abs(scale.x)

# ============================================================
# HELPER LOADER
# ============================================================
func _load_tex(path: String) -> Texture2D:
	if path.is_empty(): return null
	if ResourceLoader.exists(path):
		var res = ResourceLoader.load(path)
		if res is Texture2D: return res
	if FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == OK:
			return ImageTexture.create_from_image(img)
	return null
