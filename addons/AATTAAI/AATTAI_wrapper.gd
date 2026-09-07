@tool
extends Node2D

@export var r_vec: Vector2 = Vector2.RIGHT:
	set(val):
		r_vec = val
		if val.length_squared() > 0.0001:
			rotation = val.angle()
