# Adobe Animate → Godot 4 Importer Plugin (AATTAAI)

![Version](https://img.shields.io/badge/version-2.0.0-blue.svg)
![Godot Engine](https://img.shields.io/badge/Godot-4.x-478cbf?logo=godot-engine&logoColor=white)
![Adobe Animate](https://img.shields.io/badge/Adobe%20Animate-2020--2025+-ED2224?logo=adobe&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green.svg)

A powerful Godot 4 plugin for importing texture atlases and cut-out / symbol animations exported from Adobe Animate into clean, modular Godot scenes. Features a full `AnimationPlayer` setup, per-part transforms, dynamic Z-ordering, an advanced Visual Controller (`AATTAIController`) for seamless skin/slot equipment swapping, an interactive viewport preview with coordinate/floor grids, animation filtering, and non-destructive incremental scene updating.

---

## 🚀 What's New in Version 2.0.0

Version 2.0.0 is a major milestone release introducing powerful visual customization APIs, incremental workflow tools, performance boosts for large animation packs (80+ animations), and viewport inspection utilities:

### 1. 🎭 Standalone Visual Controller (`class_name AATTAIController`)
- **Global Reskinning**: Swap the entire character sprite atlas dynamically via `change_skin()` at runtime or in the Inspector.
- **Slot-Based Overrides**: Swap individual part textures (e.g. replacing a weapon with a standalone axe texture) via `set_slot_texture()`, with built-in reset methods (`reset_slot_texture()`, `reset_all_slots()`).
- **Equipment & Attachment API**: Attach custom nodes (VFX, 3D particles, Hitboxes `Area2D`, weapons) directly into character bone/layer slots via `equip("weapon", item_node)`.
- **Playback & Signals**: Clean animation relays (`play_anim()`, `flip_h()`, `animation_finished`, `skin_changed`, `slot_changed`).

### 2. 🔄 Incremental Scene Updating (`Update Existing Scene`)
- Update existing `.tscn` character scenes by injecting or updating only selected animations into the `AnimationPlayer` without overwriting or deleting custom user nodes (Hitboxes, CollisionShapes, AudioStreamPlayers, or custom child nodes).

### 3. 📋 Animation Checklist & Instant Search Bar (80+ Animations Ready)
- Organize 80+ animations into a neat 2-column grid.
- Instant search filter bar (`🔍`) to locate animations in real-time.
- Quick batch selection: `☑️ All`, `⬜ None`, and `🎯 Select Filtered` (select only animations matching the search query).

### 4. 🎬 Enhanced Interactive Viewport Preview
- **📏 Coordinate & Floor Grid**: World-space ground level line (Red X-axis), center symmetry line (Green Y-axis), pivot marker `(0, 0)`, and 64px/32px grid lines with a dedicated toggle button.
- **🔁 Loop / Play-Once Toggle**: Toggle preview looping on or off (plays once and stops at the final frame).
- **⚡ Real-Time FPS Override**: Instant preview update when adjusting the FPS override spinbox.
- **Debounced Viewport & Memory Safeguards**: Silky-smooth 60 FPS editor performance with strict instance validation guards preventing freed instance errors.

### 5. 🛠️ Built-in Node2D Pivot Wrappers & Zero-Sprite-Transform
- **Built-in Standard**: Every body part is automatically constructed with an intermediate `Node2D` wrapper parent (`part_name -> Sprite`).
- **Clean Separation of Concerns**: All animation transforms (`position`, `rotation`/`r_vec`, `scale`) are keyframed **exclusively** on the `Node2D` wrapper.
- **Zero Transform Tracks on Child Sprites**: Child `Sprite2D` nodes only receive `region_rect` keyframes for sprite swaps. You can freely offset or tweak sprite pivots in the Godot viewport—animations will **never** overwrite your adjustments!

### 6. 📁 Smart Directory Creation & File Browsing
- **Output Scene Browse Button**: Dedicated file browser with `*.tscn` save-dialog filters.
- **Auto-create Parent Directories**: Automatically generates missing subdirectories recursively when saving imported scenes (e.g. `res://characters/boss/boss.tscn`).
- **EDAPT & Helper Filtering**: Automatically excludes EDAPT rigging helpers (`EDAPT objects/Center Marker`, `MagnetTargets`) and single-frame root stage containers.

### 7. ⚡ Batch Set Animation Interpolation Tool
- New editor tool accessible from **Project Menu → Tools → Batch Set Animation Interpolation...**.
- Batch-modify track interpolation types (`Linear`, `Nearest / Stepped`, `Cubic`) across any character scene using exact names, comma-separated lists, or wildcard patterns (e.g. `attack*`, `hit_react`, `*pixel*`).

---

## Table of Contents
- [What's New in Version 2.0.0](#-whats-new-in-version-200)
- [Critical Adobe Animate Setup Requirements](#-critical-adobe-animate-setup-requirements)
- [Video Tutorials & Demos](#-video-tutorials--demos)
- [2D Assets & Character Packs (Bonebox)](#-2d-assets--character-packs-bonebox)
- [Key Features](#key-features)
- [Installation](#installation)
- [Usage — Via Editor Menu](#usage--via-editor-menu)
  - [1. Importer Window Overview](#1-importer-window-overview)
  - [2. Animation Checklist & Fast Search (80+ Animations)](#2-animation-checklist--fast-search-80-animations)
  - [3. Incremental Scene Update vs Fresh Import](#3-incremental-scene-update-vs-fresh-import)
  - [4. Viewport Preview with Origin & Floor Grid](#4-viewport-preview-with-origin--floor-grid)
  - [5. Batch Set Animation Interpolation Tool](#5-batch-set-animation-interpolation-tool)
- [Visual Controller & Equipment API (AATTAIController)](#visual-controller--equipment-api-aattaicontroller)
  - [Global Reskin / Texture Swap](#global-reskin--texture-swap)
  - [Slot-Based Reskin (Weapon / Armor / Cosmetic)](#slot-based-reskin-weapon--armor--cosmetic)
  - [Equipping Custom Node / VFX / Hitbox](#equipping-custom-node--vfx--hitbox)
  - [Animation Playback & Signal Relays](#animation-playback--signal-relays)
- [Usage — With AnimationTree (BlendTree)](#usage--with-animationtree-blendtree)
- [Usage — Via Script (Runtime Import)](#usage--via-script-runtime-import)
- [Generating a Texture Atlas in Adobe Animate](#generating-a-texture-atlas-in-adobe-animate)
- [Adobe Animate JSON Structure Reference](#adobe-animate-json-structure-reference)
- [Compatibility](#compatibility)

---

## 🎥 Video Tutorials & Demos

Check out these video walkthroughs and guides:

- 📺 **Plugin Overview & Tutorial (v1.6.0)**: [Watch on YouTube](https://www.youtube.com/watch?v=K_uXYJD_xFI)
- 📺 **v2.0.0 Demo & Feature Highlights**: [Watch on YouTube (Coming Soon / WIP)]()
- 📺 **Godot 4 Animation Blend Tree Tutorial (by Gwizz)**: [Watch on YouTube](https://www.youtube.com/watch?v=eQUrKp19iXE)

---

## 🎨 2D Assets & Character Packs (Bonebox)

Looking for production-ready, high-quality Adobe Animate 2D character rigs, animation packs, and game assets designed to work seamlessly with **AATTAAI**?

- 🛒 **Official Partner Assets Itch.io**: [stableimage.itch.io](https://stableimage.itch.io/) *(Character animation packs, boss monsters, weapon sets & VFX)*
- 🛠️ **Batch Export Tool (JSFL)**: [Batch-Export-Texture-Atlas](https://github.com/boneboxid/Batch-Export-Texture-Atlas) *(Batch export texture atlas symbols with one click in Adobe Animate)*
- 💬 **Community & Support**: give a STAR ⭐!

---

> [!IMPORTANT]
> ### ⚠️ Critical Adobe Animate Setup Requirements
> To ensure the importer successfully parses and imports your animations without errors, follow these rules when setting up your project in Adobe Animate:
> 
> 1. **Required Library Folder Structure**: You must organize your Library folders like this:
>    - `📁 character_name` (e.g., `boss`)
>      - `📁 anim` (MovieClip symbols for the animation states: e.g. `idle`, `walk`, `punch`)
>      - `📁 parts` (MovieClip symbols for the character parts)
> 2. **Nesting Level**: Only **Level 1** nesting is supported: `Character_Master` (Master) ➔ `Idle/Walk/etc` (Animations) ➔ `Character Symbol Parts` (Flat sprites). Any deep nesting beyond this will cause errors.
> 3. **Single Layer in Master**: All animation symbols (`Idle`, `Walk`, `Punch`) inside the `Character_Master` timeline must be placed on the **same single timeline layer**.
> 4. **MovieClips ONLY**: Both the animations and character parts **must** be created as **MovieClip** symbols.
> 5. **No Hyphens or Special Symbols**: Do not use hyphens (`-`), parentheses `()`, or other special symbols in symbol names or filenames (e.g., use `boss1_attack1` instead of `boss-1_attack(1)`).
> 6. **Consistent Part Setup**: When exporting separate animation JSON files, the symbol list and atlas spritemap must share identical part dimensions. (Using a Single Master File is recommended).

---

## Key Features

- **Dual-Mode Import**: Natively supports both multiple animation JSON files (in a folder) and single master `Animation.json` files containing nested animation symbols.
- **Incremental Scene Update (`🔄 Update Existing Scene`)**: Add or update animations in an existing `.tscn` file without deleting custom user nodes (Hitboxes `Area2D`, Hurtboxes, Particle Systems, AudioStreamPlayers, or custom sprites).
- **Animation Checklist & Search**: Fast real-time search bar (`🔍`), multi-column grid layout, and quick-filter buttons (`☑️ All`, `⬜ None`, `🎯 Select Filtered`) designed to comfortably manage packs with 80+ animations.
- **Pinned Action Bar**: Bottom action buttons and status indicators are permanently pinned at the bottom of the window—no need to resize or stretch the window.
- **Interactive Viewport Preview with Grid**: Live preview with Zoom, Pan, Reset View, Color Picker, Scrubber Timeline, toggleable Loop (`🔁 Loop`), and toggleable **Coordinate & Floor Grid (`📏 Grid`)** featuring Ground (X-axis) and Center (Y-axis) guidelines.
- **Dedicated Visual Controller (`class_name AATTAIController`)**: Built-in methods for swapping skins, overriding individual slot textures (weapons/cosmetics), and equipping custom nodes to body parts.
- **Vector2 Rotation Blending**: Rotation is keyframed using a direction vector (`r_vec`) rather than raw float angles, natively resolving 180° rotation flipping during `AnimationTree` blending.
- **Dynamic Z-Ordering & Keyframe Deduplication**: Discards redundant baked keyframes and preserves back-to-front layer draw order across all animations.
- **Built-in Node2D Pivot Wrappers**: Automatically wraps sprites in parent `Node2D` pivot nodes with transform tracks mapped strictly to the wrapper, while child `Sprite2D` nodes only keyframe `region_rect`. You can freely adjust sprite local pivots in the Godot Viewport without animation tracks overwriting them.
- **Auto-create Parent Directories & File Browser**: Includes a dedicated Browse button with `*.tscn` save dialog filters and automatically generates target subdirectories on save.
- **Texture Filter Selection**: Choose between `Linear (Smooth)` for high-res art and `Nearest (Pixel Art)` for crisp pixel graphics.
- **Animation Track Interpolation Selection**: Choose how keyframes interpolate on transform tracks (`Linear` for smooth tweening, `Nearest / Stepped` for classic stepped frame-by-frame / anime cut-out feel, or `Cubic` for natural spline curves).

---

## Installation

1. Copy the `addons/AATTAAI/` folder into your Godot project's `addons/` folder.
2. Open **Project → Project Settings → Plugins**.
3. Enable **Adobe Animate Importer (AATTAAI)**.

---

## Usage — Via Editor Menu

### 1. Importer Window Overview
Open **Project Menu → Tools → Import Adobe Animate...**:

1. **Spritemap JSON**: Select your atlas JSON (e.g. `res://assets/spritemap1.json`). The plugin will auto-predict the PNG and animation folder!
2. **Spritesheet PNG**: Select your atlas texture image (e.g. `res://assets/spritemap1.png`).
3. **Animation JSON File or Folder**: Select the master `Animation.json` or folder containing individual animation JSONs.
4. **Configure Options**:
   * **Pivot Wrapper Nodes (Built-in Standard)**: Automatically wraps each body part sprite in an intermediate `Node2D` wrapper parent. All keyframed transforms target the parent wrapper, allowing you to freely adjust the local pivot/offset of each part in the viewport without modifying source assets.
   * **Add Visual Controller Script**: Attaches an `AATTAIController` (`@tool`) script to the root node, exposing `change_skin()`, `set_slot_texture()`, `equip()`, and animation helper APIs.
   * **Texture Filter Mode**: Choose between `Linear (Smooth)` (for high-resolution assets) and `Nearest (Pixel Art)` (for clean, sharp pixel art).
   * **Animation Interpolation Mode**: Choose between `Linear (Smooth Tween)`, `Nearest / Stepped (Frame-by-Frame)`, and `Cubic (Spline Curve)`.
5. **Output scene path**: Target file path (e.g. `res://scenes/hero.tscn`). Click **Browse** to open the save file dialog; any missing folders are created automatically upon save.

---

### 2. Animation Checklist & Fast Search (80+ Animations)
Inside the form, all detected animations appear in an organized 2-column grid:
- **Search Bar**: Type any keyword (e.g. `"attack"`) to filter visible animations instantly.
- **`☑️ All`**: Check all animations.
- **`⬜ None`**: Uncheck all animations.
- **`🎯 Select Filtered`**: Check all animations currently matching the search filter.
- **Selection Counter**: Live badge shows selected count (e.g., `📋 Animations (65/80 selected):`).

---

### 3. Incremental Scene Update vs Fresh Import
The window provides two distinct action buttons pinned at the bottom:

- **`⬇️ Fresh Import`**: Generates a new scene from scratch (overwrites existing file completely).
- **`🔄 Update Existing Scene`**:
  - Automatically enabled when the output `.tscn` file already exists.
  - Adds missing layers and injects or updates selected animation tracks in the scene's `AnimationPlayer`.
  - **Preserves all custom nodes**: Custom `Area2D` hitboxes, weapons, collision shapes, cameras, or attached scripts are kept 100% intact!

---

### 4. Viewport Preview with Origin & Floor Grid
- **Play / Pause**: Play or pause current animation.
- **`🔁 Loop` Toggle**: Toggle animation looping in the preview (when unchecked, the animation plays once and stops).
- **Animation Dropdown**: Switch between selected animations.
- **`📏 Grid` Toggle**: Toggles the 64px/32px grid, Ground line (Red X Axis), Center line (Green Y Axis), and `(0,0)` pivot marker.
- **Color Picker**: Change preview background color to test light/dark contrast.
- **Timeline Scrubber**: Drag or click to scrub animation frames smoothly.
- **Navigation Controls**:
  - **Zoom**: Mouse Wheel Up / Down.
  - **Pan**: Right-Click or Middle-Click drag.
  - **Reset View**: Double-Click Left Mouse Button.

---

### 5. Batch Set Animation Interpolation Tool
Open **Project Menu → Tools → Batch Set Animation Interpolation...**:
Quickly change the interpolation type (`Linear`, `Nearest / Stepped`, `Cubic`) for specific animations in an existing scene:
- **Target Scene**: Select your `.tscn` character scene.
- **Animation Pattern**: Enter exact animation names (e.g. `hit_react`), comma-separated lists (`punch, kick, jump`), or wildcard patterns (`attack*`, `*pixel*`).
- Click **`⚡ Apply Interpolation to Matching Animations`** to batch-update all transform tracks in one click!

---

## Visual Controller & Equipment API (AATTAIController)

When **Add Visual Controller Script** is enabled, the imported root node is attached with `AATTAIController` (`addons/AATTAAI/AATTAI_controller.gd`), providing a high-level API for game logic.

### Generated Hierarchy
```text
AnimatedCharacter (Node2D)  ← [AATTAIController attached]
├── AnimationPlayer
├── head (Node2D, Pivot Wrapper)
│   └── Sprite (Sprite2D)
├── weapon (Node2D, Pivot Wrapper)
│   └── Sprite (Sprite2D)
└── ...
```

### Scripting Examples:

#### Global Reskin / Texture Swap
Swap the entire character's appearance to a new spritesheet atlas on the fly:
```gdscript
extends CharacterBody2D

@onready var visual: AATTAIController = $AnimatedCharacter

func equip_ice_skin():
    # Changes all body parts to use the new atlas texture
    visual.change_skin(preload("res://skins/hero_ice_atlas.png"))

func reset_skin():
    visual.change_skin(preload("res://assets/spritemap1.png"))
```

#### Slot-Based Reskin (Weapon / Armor / Cosmetic)
Override an individual part (e.g. `"weapon"` or `"helmet"`) with a custom standalone sprite texture:
```gdscript
func change_weapon_skin():
    # Replaces the weapon slot sprite with a standalone axe texture
    visual.set_slot_texture("weapon", preload("res://sprites/axe.png"))

func reset_weapon():
    # Restores weapon to the original atlas spritemap
    visual.reset_slot_texture("weapon")

func reset_everything():
    visual.reset_all_slots()
```

#### Equipping Custom Node / VFX / Hitbox
Attach any custom Godot node (such as a 3D effect, Particle system, or Hitbox) directly to a body part:
```gdscript
func equip_fire_sword():
    var fire_fx = preload("res://scenes/vfx_fire.tscn").instantiate()
    visual.equip("weapon", fire_fx, true) # true = replaces previous custom attachment

func remove_sword_fx():
    visual.clear_slot("weapon")
```

#### Animation Playback & Signal Relays
```gdscript
func _ready():
    visual.animation_finished.connect(_on_anim_finished)
    visual.skin_changed.connect(func(tex): print("Skin swapped!"))

func attack():
    visual.play_anim("attack_combo_1")

func take_hit():
    visual.play_anim("hit_react")

func _on_anim_finished(anim_name: StringName):
    if anim_name.begins_with("attack"):
        visual.play_anim("idle")
```

---

## Usage — With AnimationTree (BlendTree)

The importer exports rotation tracks as Vector2 direction vectors (`r_vec`). This enables smooth linear interpolation without the standard 180° angular wrap flip:

1. Add an `AnimationTree` node as a child of your character root.
2. Set **Anim Player** to `$AnimatedCharacter/AnimationPlayer`.
3. Set **Tree Root** to `AnimationNodeBlendTree` and set **Active** = `true`.
4. Add `AnimationNodeBlend2` or `AnimationNodeTransition` nodes to blend `idle` and `walk` or trigger `attack` actions.

```gdscript
extends CharacterBody2D

@onready var anim_tree: AnimationTree = $AnimatedCharacter/AnimationTree

func _physics_process(delta):
    var speed_blend = clamp(velocity.length() / max_speed, 0.0, 1.0)
    anim_tree.set("parameters/MoveBlend/blend_amount", speed_blend)

    if Input.is_action_just_pressed("attack"):
        anim_tree.set("parameters/AttackOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
```

---

## Usage — Via Script (Runtime Import)

To import and assemble Adobe Animate characters dynamically in code at runtime:

```gdscript
extends Node2D

func _ready():
    var runtime = load("res://addons/AATTAAI/AATTAI_runtime.gd").new()
    add_child(runtime)
    
    runtime.build(
        "res://assets/spritemap1.json",
        "res://assets/animations",
        "res://assets/spritemap1.png",
        "",                # anim_folder (optional if anim_path provided)
        true,              # use_pivot_wrappers
        true,              # add_skin_swapper
        "Linear",          # texture_filter_mode
        "Linear"           # interpolation_mode
    )
    
    runtime.play_anim("walk")
```

---

## Generating a Texture Atlas in Adobe Animate

### Workflow A: Single Master File (Recommended)
Packs all animations into a single `Animation.json` file and a single spritemap.

1. **Create Master Symbol**: Create a Movie Clip symbol (e.g. `Character_Master`).
2. **Nest Animations (Level 1)**: Drag instances of all animation symbols (`Idle`, `Walk`, `Jump`, `Attack`) onto the stage **on the same single timeline layer**.
3. **Export Texture Atlas**: Right-click `Character_Master` in the Library and click **Generate Texture Atlas**.
4. **Settings**:
   - **Dimensions**: Autosize (e.g. 2048×2048).
   - **Optimize Dimensions**: Enabled (crops empty pixels).
   - **Padding**: 2px.
   - **Format**: PNG (32-bit).

---

## Adobe Animate JSON Structure Reference

Adobe Animate Texture Atlas outputs:
- **`spritemap1.json`**: Atlas bounding rects (`name`, `x`, `y`, `w`, `h`).
- **`Animation.json`**: Layer hierarchy, timeline frames, symbol instances (`SI`), matrix transforms (`M3D` 4×4 row-major), and symbol dictionary (`SD`).

The importer automatically extracts `position`, `rotation` (vectorized), `scale`, `region_rect`, `visible`, and `z_index` keyframes into standard Godot `Animation` resources.

---

## Compatibility

- **Godot**: Godot 4.0 – 4.7+ (GDScript `@tool`)
- **Adobe Animate**: Adobe Animate 2020 – 2025+ (JSON Texture Atlas Format)
- **Tooling**: Fully compatible with EDAP Tools / Flash POWERTOOLS
