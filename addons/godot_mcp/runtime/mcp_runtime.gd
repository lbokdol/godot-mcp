extends Node
## MCPRuntime — autoload that lives inside the user's running game and exposes
## the "runtime" tool surface to the MCP server: execution control is owned by
## the editor plugin, but everything that needs to touch the running game —
## input simulation, screenshots, scene-tree inspection, assertions, runtime
## state mutation, log capture — flows through here.
##
## Connects to the same MCP WebSocket server as the editor plugin (port 6505),
## but identifies itself with role="runtime" in its hello message so the server
## can route runtime tool calls to it.
##
## Auto-registered as an autoload by the godot_mcp editor plugin on
## _enable_plugin(); removed on _disable_plugin().
##
## ─────────────────────────────────────────────────────────────────────────
## Tool dispatch table (alphabetical):
##   add_node_runtime, assert_no_errors_in_log, assert_node_exists,
##   assert_node_visible, assert_property, call_node_method,
##   capture_screenshot, clear_debug_log, click_at, click_node, drag,
##   find_and_click, get_debug_log, get_input_state, get_node_property,
##   get_print_log, get_runtime_log, get_runtime_scene_tree, hold_action,
##   hold_key, list_actions, list_signal_connections, mouse_move,
##   press_action, press_key, query_runtime_node, release_action, release_all,
##   release_key, run_input_sequence, send_input, set_node_property,
##   take_screenshot
## ─────────────────────────────────────────────────────────────────────────

const SERVER_URL := "ws://127.0.0.1:6505"
const CACHE_SCREENSHOT_DIR := "res://addons/godot_mcp/cache/screenshots/"
const CACHE_SNAPSHOT_DIR := "res://addons/godot_mcp/cache/snapshots/"
const CACHE_BASELINE_DIR := "res://addons/godot_mcp/cache/baseline/"
const LOG_RING_CAPACITY := 500
const PRINT_RING_CAPACITY := 500
const ERROR_RING_CAPACITY := 500
const DEFAULT_WAIT_AFTER_MS := 33
# SSIM constants — c1 = (0.01*L)², c2 = (0.03*L)² with L=255 dynamic range.
const SSIM_C1 := 6.5025      # (0.01 * 255)^2
const SSIM_C2 := 58.5225     # (0.03 * 255)^2
const SSIM_BLOCK := 8        # 8×8 windowed comparison (smaller than the 11×11
                              # MATLAB default but ~2× faster — sufficient for
                              # pixel-art regression where 1-px shifts matter).

var _socket: WebSocketPeer = WebSocketPeer.new()
var _connected := false
var _reconnect_at_msec := 0
var _project_path := ""

# Circular buffers. _log_ring is the legacy free-form runtime log; _print_ring
# captures plain print() output via push_print(); _error_ring captures
# push_error / push_warning via push_engine_log(). User scripts that want
# their diagnostics visible in the agent should call MCPRuntime.push_*().
var _log_ring: Array = []
var _print_ring: Array = []
var _error_ring: Array = []
var _started_at_msec := 0

# Held-input state (used by press/hold/release and release_all). Keys map
# keycode → physical_keycode used to issue the matching release; values map
# action_name → true.
var _pressed_keys: Dictionary = {}
var _pressed_actions: Dictionary = {}


func _ready() -> void:
	_project_path = ProjectSettings.globalize_path("res://")
	_started_at_msec = Time.get_ticks_msec()
	process_mode = Node.PROCESS_MODE_ALWAYS
	push_runtime_log("info", "MCPRuntime starting (project=%s)" % _project_path)
	_attempt_connect()


func _process(_delta: float) -> void:
	_socket.poll()
	var st := _socket.get_ready_state()

	if st == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			_send({
				"type": "godot_ready",
				"role": "runtime",
				"project_path": _project_path,
				"started_at": _started_at_msec,
			})
			push_runtime_log("info", "MCPRuntime connected to MCP server.")

		while _socket.get_available_packet_count() > 0:
			var raw := _socket.get_packet().get_string_from_utf8()
			_handle_message(raw)

	elif st == WebSocketPeer.STATE_CLOSED:
		if _connected:
			_connected = false
			push_runtime_log("warn", "MCPRuntime disconnected; releasing held inputs.")
			# Zombie-input safety: if MCP server disappears mid-test we don't
			# want the game stuck with a key still down.
			_release_all_held()
		var now := Time.get_ticks_msec()
		if now >= _reconnect_at_msec:
			_attempt_connect()


func _attempt_connect() -> void:
	_socket = WebSocketPeer.new()
	_socket.outbound_buffer_size = 8 * 1024 * 1024  # screenshots can be big
	_socket.inbound_buffer_size = 256 * 1024
	var err := _socket.connect_to_url(SERVER_URL)
	_reconnect_at_msec = Time.get_ticks_msec() + 2000
	if err != OK:
		push_runtime_log("warn", "MCPRuntime connect_to_url failed: %d (%s)" % [err, error_string(err)])


func _handle_message(json_string: String) -> void:
	var msg = JSON.parse_string(json_string)
	if msg == null or not msg is Dictionary:
		return
	var msg_type: String = str(msg.get("type", ""))
	match msg_type:
		"ping":
			_send({"type": "pong"})
		"tool_invoke":
			var rid: String = str(msg.get("id", ""))
			var tool_name: String = str(msg.get("tool", ""))
			var args = msg.get("args", {})
			if not args is Dictionary:
				args = {}
			var result: Dictionary = await _dispatch(tool_name, args)
			var success: bool = bool(result.get("ok", false))
			result.erase("ok")
			_send({
				"type": "tool_result",
				"id": rid,
				"success": success,
				"result": result if success else null,
				"error": str(result.get("error", "")) if not success else "",
			})
		_:
			pass


# =============================================================================
# Dispatch table
# =============================================================================
func _dispatch(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		# Legacy / overlap names — kept for backward compat with v0.5.
		"take_screenshot":          return _take_screenshot(args)
		"send_input":               return _send_input(args)
		"query_runtime_node":       return _query_runtime_node(args)
		"get_runtime_log":          return _get_runtime_log(args)
		"list_signal_connections":  return _list_signal_connections(args)
		# §7.2 — Action-tier input
		"list_actions":             return _list_actions(args)
		"press_action":             return await _press_action(args)
		"hold_action":              return _hold_action(args)
		"release_action":           return _release_action(args)
		# §7.3 — Node click
		"click_node":               return await _click_node(args)
		"find_and_click":           return await _find_and_click(args)
		# §7.4 — Raw key / mouse
		"press_key":                return await _press_key(args)
		"hold_key":                 return _hold_key(args)
		"release_key":              return _release_key(args)
		"click_at":                 return await _click_at(args)
		"mouse_move":               return _mouse_move(args)
		"drag":                     return await _drag(args)
		# §7.5 — Sequence
		"run_input_sequence":       return await _run_input_sequence(args)
		# §7.6 — Safety
		"release_all":              return _release_all(args)
		"get_input_state":          return _get_input_state(args)
		# §7.7 — Inspection
		"capture_screenshot":       return _take_screenshot(args)
		"get_runtime_scene_tree":   return _get_runtime_scene_tree(args)
		"get_node_property":        return _get_node_property(args)
		# §7.8 — Assertion
		"assert_property":          return _assert_property(args)
		"assert_node_exists":       return _assert_node_exists(args)
		"assert_node_visible":      return _assert_node_visible(args)
		"assert_no_errors_in_log":  return _assert_no_errors_in_log(args)
		# §7.9 — Log
		"get_debug_log":            return _get_debug_log(args)
		"clear_debug_log":          return _clear_debug_log(args)
		"get_print_log":            return _get_print_log(args)
		# §7.10 — State mutation
		"set_node_property":        return _set_node_property(args)
		"call_node_method":         return _call_node_method(args)
		"add_node_runtime":         return _add_node_runtime(args)
		# Phase 2 — Property bag snapshots
		"snapshot_capture":         return _snapshot_capture(args)
		"snapshot_restore":         return _snapshot_restore(args)
		"snapshot_diff":            return _snapshot_diff(args)
		"snapshot_list":            return _snapshot_list(args)
		# Phase 2 — Visual regression baselines
		"capture_baseline":         return _capture_baseline(args)
		"compare_with_baseline":    return _compare_with_baseline(args)
		"update_baseline":          return _update_baseline(args)
		"update_mask":              return _update_mask(args)
		"list_baselines":           return _list_baselines(args)
		"delete_baseline":          return _delete_baseline(args)
		"compare_screenshots_adhoc": return _compare_screenshots_adhoc(args)
		_:
			return {"ok": false, "error": "Unknown runtime tool: %s" % tool_name}


# =============================================================================
# §7.7 / legacy take_screenshot — capture viewport
# =============================================================================
func _take_screenshot(args: Dictionary) -> Dictionary:
	var save_to: String = str(args.get("save_to", "")).strip_edges()
	var return_base64: bool = bool(args.get("return_base64", false))

	var viewport := get_viewport()
	if viewport == null:
		return {"ok": false, "error": "No viewport available", "code": "RENDERING_REQUIRED"}
	var img: Image = viewport.get_texture().get_image()
	if img == null:
		return {"ok": false, "error": "Viewport returned no image", "code": "RENDERING_REQUIRED"}

	var resource_path := ""
	if save_to.is_empty():
		_ensure_cache_dir()
		resource_path = "%sscreenshot_%d.png" % [CACHE_SCREENSHOT_DIR, Time.get_ticks_msec()]
	else:
		if not save_to.begins_with("res://") and not save_to.begins_with("user://"):
			save_to = "res://" + save_to
		resource_path = save_to

	var abs_path := ProjectSettings.globalize_path(resource_path)
	var dir := abs_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var err := img.save_png(abs_path)
	if err != OK:
		return {"ok": false, "error": "save_png failed: %d (%s) at %s" % [err, error_string(err), abs_path]}

	var out := {
		"ok": true,
		"resource_path": resource_path,
		"absolute_path": abs_path,
		"width": img.get_width(),
		"height": img.get_height(),
	}
	if return_base64:
		out["base64_png"] = Marshalls.raw_to_base64(FileAccess.get_file_as_bytes(abs_path))
	return out


# =============================================================================
# legacy send_input — low-level event builder, kept for advanced callers
# =============================================================================
func _send_input(args: Dictionary) -> Dictionary:
	var event_desc: Dictionary = args.get("event", {})
	if event_desc.is_empty():
		return {"ok": false, "error": "Missing 'event' dictionary"}
	var event := _build_input_event(event_desc)
	if event == null:
		return {"ok": false, "error": "Could not construct InputEvent from: %s" % str(event_desc)}
	Input.parse_input_event(event)
	return {
		"ok": true,
		"dispatched": event.get_class(),
		"event": event_desc,
	}


func _build_input_event(desc: Dictionary) -> InputEvent:
	var t: String = str(desc.get("type", ""))
	match t:
		"key":
			var k := InputEventKey.new()
			k.pressed = bool(desc.get("pressed", true))
			if desc.has("keycode"):
				k.keycode = int(desc["keycode"])
			if desc.has("physical_keycode"):
				k.physical_keycode = int(desc["physical_keycode"])
			if desc.has("key"):
				var keystr := str(desc["key"]).to_upper()
				k.physical_keycode = OS.find_keycode_from_string(keystr)
			if desc.has("shift"): k.shift_pressed = bool(desc["shift"])
			if desc.has("ctrl"): k.ctrl_pressed = bool(desc["ctrl"])
			if desc.has("alt"): k.alt_pressed = bool(desc["alt"])
			if desc.has("meta"): k.meta_pressed = bool(desc["meta"])
			return k
		"mouse_button":
			var mb := InputEventMouseButton.new()
			mb.pressed = bool(desc.get("pressed", true))
			mb.button_index = int(desc.get("button_index", MOUSE_BUTTON_LEFT))
			if desc.has("position"):
				mb.position = _to_vec2(desc["position"])
				mb.global_position = mb.position
			if desc.has("double_click"):
				mb.double_click = bool(desc["double_click"])
			return mb
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			if desc.has("position"):
				mm.position = _to_vec2(desc["position"])
				mm.global_position = mm.position
			if desc.has("relative"):
				mm.relative = _to_vec2(desc["relative"])
			return mm
		"action":
			var act := InputEventAction.new()
			act.action = str(desc.get("action", ""))
			act.pressed = bool(desc.get("pressed", true))
			act.strength = float(desc.get("strength", 1.0 if act.pressed else 0.0))
			return act
		_:
			return null


func _to_vec2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Dictionary:
		return Vector2(float(v.get("x", 0)), float(v.get("y", 0)))
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


# =============================================================================
# §7.2 — Action-tier input
# =============================================================================
func _list_actions(_args: Dictionary) -> Dictionary:
	var actions: Array = []
	for a in InputMap.get_actions():
		if str(a).begins_with("ui_"):
			# Engine-internal UI actions are usually noise for game-test agents.
			# Caller can pass include_ui=true to opt in.
			if not bool(_args.get("include_ui", false)):
				continue
		actions.append({
			"name": str(a),
			"deadzone": InputMap.action_get_deadzone(str(a)),
			"events": InputMap.action_get_events(str(a)).size(),
		})
	return {"ok": true, "actions": actions, "count": actions.size()}


func _press_action(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	if not InputMap.has_action(name):
		return {"ok": false, "code": "INVALID_ACTION",
				"error": "Action not in InputMap: %s" % name,
				"suggestions": _suggest_actions(name)}
	var duration_ms: int = int(args.get("duration_ms", 100))
	var wait_after_ms: int = int(args.get("wait_after_ms", DEFAULT_WAIT_AFTER_MS))
	Input.action_press(name)
	_pressed_actions[name] = true
	await _wait_ms(duration_ms)
	Input.action_release(name)
	_pressed_actions.erase(name)
	await _wait_ms(wait_after_ms)
	return {"ok": true, "name": name, "held_ms": duration_ms}


func _hold_action(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	if not InputMap.has_action(name):
		return {"ok": false, "code": "INVALID_ACTION",
				"error": "Action not in InputMap: %s" % name,
				"suggestions": _suggest_actions(name)}
	Input.action_press(name)
	_pressed_actions[name] = true
	return {"ok": true, "name": name, "holding": true}


func _release_action(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	if not _pressed_actions.has(name):
		return {"ok": true, "name": name, "was_held": false}
	Input.action_release(name)
	_pressed_actions.erase(name)
	return {"ok": true, "name": name, "was_held": true}


# =============================================================================
# §7.3 — Node click (UI-safe: resolves the node's screen rect at click time)
# =============================================================================
func _click_node(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path'"}
	var node := _resolve_node(node_path)
	if node == null:
		return {"ok": false, "code": "NODE_NOT_FOUND",
				"error": "Node not found: %s" % node_path,
				"suggestions": _suggest_node_paths(node_path)}
	var center := _node_screen_center(node)
	if center == Vector2.INF:
		return {"ok": false, "error": "Cannot determine screen rect for %s (class %s)" % [node_path, node.get_class()]}
	return await _click_at({
		"x": center.x, "y": center.y,
		"button": args.get("button", "left"),
		"double": args.get("double", false),
		"wait_after_ms": args.get("wait_after_ms", DEFAULT_WAIT_AFTER_MS),
		"space": "viewport",
	})


func _find_and_click(args: Dictionary) -> Dictionary:
	var query: String = str(args.get("text_or_name", "")).strip_edges()
	if query.is_empty():
		return {"ok": false, "error": "Missing 'text_or_name'"}
	var tree := get_tree()
	if tree == null:
		return {"ok": false, "code": "GAME_NOT_RUNNING", "error": "SceneTree unavailable"}
	var root := tree.current_scene if tree.current_scene else tree.root
	var hit := _find_matching_descendant(root, query)
	if hit == null:
		return {"ok": false, "code": "NODE_NOT_FOUND",
				"error": "No node with name or text matching '%s'" % query}
	return await _click_node({
		"node_path": str(hit.get_path()),
		"button": args.get("button", "left"),
		"double": args.get("double", false),
		"wait_after_ms": args.get("wait_after_ms", DEFAULT_WAIT_AFTER_MS),
	})


func _find_matching_descendant(root: Node, query: String) -> Node:
	if root == null:
		return null
	var q := query.to_lower()
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if str(n.name).to_lower() == q:
			return n
		# Control / Label / Button text attributes
		if n is Button or n is Label or n is RichTextLabel or n is LineEdit:
			var txt := str(n.get("text"))
			if txt.to_lower().find(q) >= 0:
				return n
		for c in n.get_children():
			stack.push_back(c)
	return null


func _node_screen_center(node: Node) -> Vector2:
	if node is Control:
		var rect: Rect2 = node.get_global_rect()
		return rect.position + rect.size * 0.5
	if node is Node2D:
		var cam := get_viewport().get_camera_2d()
		var world: Vector2 = node.global_position
		if cam:
			# Convert world → viewport using the camera transform.
			return get_viewport().get_canvas_transform() * world
		return world
	# Node3D / unknown → unsupported for now.
	return Vector2.INF


# =============================================================================
# §7.4 — Raw key / mouse
# =============================================================================
func _press_key(args: Dictionary) -> Dictionary:
	var info := _resolve_keycode(args)
	if not info.has("keycode"):
		return {"ok": false, "code": "INVALID_KEY",
				"error": "Could not resolve keycode from args: %s" % str(args)}
	var duration_ms: int = int(args.get("duration_ms", 100))
	var wait_after_ms: int = int(args.get("wait_after_ms", DEFAULT_WAIT_AFTER_MS))
	var modifiers: Array = args.get("modifiers", [])
	_dispatch_key(info, modifiers, true)
	_pressed_keys[info["keycode"]] = info
	await _wait_ms(duration_ms)
	_dispatch_key(info, modifiers, false)
	_pressed_keys.erase(info["keycode"])
	await _wait_ms(wait_after_ms)
	return {"ok": true, "keycode": info["keycode"], "held_ms": duration_ms}


func _hold_key(args: Dictionary) -> Dictionary:
	var info := _resolve_keycode(args)
	if not info.has("keycode"):
		return {"ok": false, "code": "INVALID_KEY", "error": "Could not resolve keycode"}
	var modifiers: Array = args.get("modifiers", [])
	_dispatch_key(info, modifiers, true)
	info["modifiers"] = modifiers
	_pressed_keys[info["keycode"]] = info
	return {"ok": true, "keycode": info["keycode"], "holding": true}


func _release_key(args: Dictionary) -> Dictionary:
	var info := _resolve_keycode(args)
	if not info.has("keycode"):
		return {"ok": false, "code": "INVALID_KEY", "error": "Could not resolve keycode"}
	if not _pressed_keys.has(info["keycode"]):
		return {"ok": true, "keycode": info["keycode"], "was_held": false}
	var saved: Dictionary = _pressed_keys[info["keycode"]]
	_dispatch_key(saved, saved.get("modifiers", []), false)
	_pressed_keys.erase(info["keycode"])
	return {"ok": true, "keycode": info["keycode"], "was_held": true}


func _resolve_keycode(args: Dictionary) -> Dictionary:
	var out := {}
	if args.has("keycode"):
		out["keycode"] = int(args["keycode"])
	if args.has("physical_keycode"):
		out["physical_keycode"] = int(args["physical_keycode"])
	if args.has("key"):
		var s := str(args["key"]).to_upper()
		var c := OS.find_keycode_from_string(s)
		if c != 0:
			out["physical_keycode"] = c
			if not out.has("keycode"):
				out["keycode"] = c
	return out


func _dispatch_key(info: Dictionary, modifiers: Array, pressed: bool) -> void:
	var k := InputEventKey.new()
	k.pressed = pressed
	if info.has("keycode"): k.keycode = int(info["keycode"])
	if info.has("physical_keycode"): k.physical_keycode = int(info["physical_keycode"])
	for m in modifiers:
		var ms := str(m).to_lower()
		match ms:
			"shift": k.shift_pressed = true
			"ctrl", "control": k.ctrl_pressed = true
			"alt":   k.alt_pressed = true
			"meta", "cmd", "super": k.meta_pressed = true
	Input.parse_input_event(k)


func _click_at(args: Dictionary) -> Dictionary:
	var x: float = float(args.get("x", 0.0))
	var y: float = float(args.get("y", 0.0))
	var space: String = str(args.get("space", "viewport"))
	var btn: int = _mouse_button_code(str(args.get("button", "left")))
	var double_click: bool = bool(args.get("double", false))
	var wait_after_ms: int = int(args.get("wait_after_ms", DEFAULT_WAIT_AFTER_MS))
	var pos := _transform_point(Vector2(x, y), space)

	var down := InputEventMouseButton.new()
	down.pressed = true
	down.button_index = btn
	down.position = pos
	down.global_position = pos
	down.double_click = double_click
	Input.parse_input_event(down)

	var up := InputEventMouseButton.new()
	up.pressed = false
	up.button_index = btn
	up.position = pos
	up.global_position = pos
	Input.parse_input_event(up)

	await _wait_ms(wait_after_ms)
	return {"ok": true, "viewport_x": pos.x, "viewport_y": pos.y, "button": btn}


func _mouse_move(args: Dictionary) -> Dictionary:
	var x: float = float(args.get("x", 0.0))
	var y: float = float(args.get("y", 0.0))
	var space: String = str(args.get("space", "viewport"))
	var pos := _transform_point(Vector2(x, y), space)
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	mm.global_position = pos
	Input.parse_input_event(mm)
	return {"ok": true, "viewport_x": pos.x, "viewport_y": pos.y}


func _drag(args: Dictionary) -> Dictionary:
	var fx: float = float(args.get("from_x", 0.0))
	var fy: float = float(args.get("from_y", 0.0))
	var tx: float = float(args.get("to_x", 0.0))
	var ty: float = float(args.get("to_y", 0.0))
	var space: String = str(args.get("space", "viewport"))
	var duration_ms: int = int(args.get("duration_ms", 200))
	var steps: int = max(2, int(args.get("steps", 8)))
	var btn: int = _mouse_button_code(str(args.get("button", "left")))
	var from_p := _transform_point(Vector2(fx, fy), space)
	var to_p   := _transform_point(Vector2(tx, ty), space)

	# Press at start.
	var down := InputEventMouseButton.new()
	down.pressed = true
	down.button_index = btn
	down.position = from_p
	down.global_position = from_p
	Input.parse_input_event(down)

	# Interpolate motion across `steps` frames.
	var step_wait := max(1, int(duration_ms / steps))
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var here := from_p.lerp(to_p, t)
		var mm := InputEventMouseMotion.new()
		mm.position = here
		mm.global_position = here
		mm.relative = here - (from_p if i == 1 else from_p.lerp(to_p, float(i - 1) / float(steps)))
		Input.parse_input_event(mm)
		await _wait_ms(step_wait)

	# Release at end.
	var up := InputEventMouseButton.new()
	up.pressed = false
	up.button_index = btn
	up.position = to_p
	up.global_position = to_p
	Input.parse_input_event(up)
	return {"ok": true, "from": [from_p.x, from_p.y], "to": [to_p.x, to_p.y], "steps": steps}


func _mouse_button_code(name: String) -> int:
	match name.to_lower():
		"left":   return MOUSE_BUTTON_LEFT
		"right":  return MOUSE_BUTTON_RIGHT
		"middle": return MOUSE_BUTTON_MIDDLE
		"wheel_up":   return MOUSE_BUTTON_WHEEL_UP
		"wheel_down": return MOUSE_BUTTON_WHEEL_DOWN
		_: return MOUSE_BUTTON_LEFT


func _transform_point(p: Vector2, space: String) -> Vector2:
	match space:
		"viewport": return p
		"window":
			# Window → viewport via the canvas transform inverse.
			var ct: Transform2D = get_viewport().get_canvas_transform()
			return ct.affine_inverse() * p
		"global":
			# World → viewport using current canvas transform (covers Camera2D).
			var ct2: Transform2D = get_viewport().get_canvas_transform()
			return ct2 * p
		_: return p


# =============================================================================
# §7.5 — Sequence: bundle multiple input steps in one round trip
# =============================================================================
func _run_input_sequence(args: Dictionary) -> Dictionary:
	var steps: Array = args.get("steps", [])
	if steps.is_empty():
		return {"ok": false, "error": "Missing 'steps' array"}
	var results: Array = []
	for i in steps.size():
		var step = steps[i]
		if not step is Dictionary:
			results.append({"index": i, "ok": false, "error": "step not a dict"})
			continue
		var step_dict: Dictionary = step
		var op: String = str(step_dict.get("action", ""))
		var r: Dictionary
		match op:
			"press_action":     r = await _press_action(step_dict)
			"hold_action":      r = _hold_action(step_dict)
			"release_action":   r = _release_action(step_dict)
			"press_key":        r = await _press_key(step_dict)
			"hold_key":         r = _hold_key(step_dict)
			"release_key":      r = _release_key(step_dict)
			"click_at":         r = await _click_at(step_dict)
			"click_node":       r = await _click_node(step_dict)
			"mouse_move":       r = _mouse_move(step_dict)
			"drag":             r = await _drag(step_dict)
			"wait":
				await _wait_ms(int(step_dict.get("ms", 100)))
				r = {"ok": true, "waited_ms": int(step_dict.get("ms", 100))}
			"screenshot":
				r = _take_screenshot(step_dict)
			_:
				r = {"ok": false, "error": "Unknown sequence op: %s" % op}
		r["index"] = i
		results.append(r)
		if not bool(r.get("ok", false)) and bool(args.get("stop_on_error", true)):
			return {"ok": false, "results": results, "error": "Step %d failed" % i}
	return {"ok": true, "results": results, "count": results.size()}


# =============================================================================
# §7.6 — Safety
# =============================================================================
func _release_all(_args: Dictionary) -> Dictionary:
	var n := _release_all_held()
	return {"ok": true, "released": n}


func _release_all_held() -> int:
	var n := 0
	for kc in _pressed_keys.keys():
		var info: Dictionary = _pressed_keys[kc]
		_dispatch_key(info, info.get("modifiers", []), false)
		n += 1
	_pressed_keys.clear()
	for act in _pressed_actions.keys():
		Input.action_release(str(act))
		n += 1
	_pressed_actions.clear()
	return n


func _get_input_state(_args: Dictionary) -> Dictionary:
	return {
		"ok": true,
		"pressed_keys":    _pressed_keys.keys(),
		"pressed_actions": _pressed_actions.keys(),
	}


# =============================================================================
# §7.7 — Inspection (extended versions of query_runtime_node)
# =============================================================================
func _get_runtime_scene_tree(args: Dictionary) -> Dictionary:
	var root_path: String = str(args.get("root", "/root"))
	var max_depth: int = clampi(int(args.get("max_depth", 10)), 1, 50)
	var node := _resolve_node(root_path)
	if node == null:
		return {"ok": false, "code": "NODE_NOT_FOUND", "error": "Root not found: %s" % root_path}
	var tree := _walk(node, 0, max_depth)
	return {"ok": true, "root": root_path, "tree": tree}


func _walk(node: Node, depth: int, max_depth: int) -> Dictionary:
	var d := {
		"name": str(node.name),
		"class": node.get_class(),
		"path": str(node.get_path()),
	}
	if node is CanvasItem:
		d["visible"] = (node as CanvasItem).visible
	if depth < max_depth and node.get_child_count() > 0:
		var kids: Array = []
		for c in node.get_children():
			kids.append(_walk(c, depth + 1, max_depth))
		d["children"] = kids
	elif node.get_child_count() > 0:
		d["children_truncated"] = node.get_child_count()
	return d


func _get_node_property(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	var prop: String = str(args.get("property", "")).strip_edges()
	if node_path.is_empty() or prop.is_empty():
		return {"ok": false, "error": "Missing 'node_path' or 'property'"}
	var node := _resolve_node(node_path)
	if node == null:
		return {"ok": false, "code": "NODE_NOT_FOUND",
				"error": "Node not found: %s" % node_path,
				"suggestions": _suggest_node_paths(node_path)}
	var v = node.get(prop)
	if v == null and not _node_has_property(node, prop):
		return {"ok": false, "code": "PROPERTY_NOT_FOUND",
				"error": "Property '%s' not on %s" % [prop, node.get_class()],
				"suggestions": _list_node_properties(node)}
	return {"ok": true, "node_path": str(node.get_path()), "property": prop, "value": _serialize(v)}


# =============================================================================
# §7.8 — Assertion
# =============================================================================
func _assert_property(args: Dictionary) -> Dictionary:
	var op: String = str(args.get("op", "eq"))
	var expected = args.get("expected")
	var node_path: String = str(args.get("node_path", ""))
	var prop: String = str(args.get("property", ""))
	var got_result := _get_node_property({"node_path": node_path, "property": prop})
	if not bool(got_result.get("ok", false)):
		got_result["assert"] = "fail_pre"
		_attach_assert_screenshot(got_result)
		return got_result
	var got = got_result["value"]
	var ok := _compare(got, expected, op)
	var out := {
		"ok": ok,
		"node_path": node_path,
		"property": prop,
		"op": op,
		"got": got,
		"expected": expected,
	}
	if not ok:
		out["error"] = "assertion failed: %s %s %s (got %s)" % [prop, op, str(expected), str(got)]
		_attach_assert_screenshot(out)
	return out


func _assert_node_exists(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", ""))
	var node := _resolve_node(node_path)
	if node == null:
		var r := {"ok": false, "code": "NODE_NOT_FOUND",
				"error": "Node not found: %s" % node_path,
				"suggestions": _suggest_node_paths(node_path)}
		_attach_assert_screenshot(r)
		return r
	return {"ok": true, "node_path": str(node.get_path())}


func _assert_node_visible(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", ""))
	var node := _resolve_node(node_path)
	if node == null:
		var r := {"ok": false, "code": "NODE_NOT_FOUND",
				"error": "Node not found: %s" % node_path}
		_attach_assert_screenshot(r)
		return r
	var visible := false
	if node is Control:
		var c := node as Control
		visible = c.visible and c.get_viewport_rect().intersects(c.get_global_rect())
	elif node is CanvasItem:
		visible = (node as CanvasItem).visible
	else:
		visible = true  # non-canvas → considered visible
	var r := {"ok": visible, "node_path": str(node.get_path()), "visible": visible}
	if not visible:
		r["error"] = "Node not visible: %s" % node_path
		_attach_assert_screenshot(r)
	return r


func _assert_no_errors_in_log(args: Dictionary) -> Dictionary:
	var since_ms: int = int(args.get("since_ms", 0))
	var errors: Array = []
	for entry in _error_ring:
		if int(entry.get("ts_ms", 0)) >= since_ms and str(entry.get("level", "")) in ["error", "warn"]:
			errors.append(entry)
	# Legacy _log_ring also carries level entries.
	for entry in _log_ring:
		if int(entry.get("ts_ms", 0)) >= since_ms and str(entry.get("level", "")) == "error":
			errors.append(entry)
	if errors.size() > 0:
		var r := {"ok": false, "errors": errors, "count": errors.size(),
				  "error": "Log contains %d error/warning entries since ts_ms=%d" % [errors.size(), since_ms]}
		_attach_assert_screenshot(r)
		return r
	return {"ok": true, "count": 0}


func _compare(got: Variant, expected: Variant, op: String) -> bool:
	match op:
		"eq":     return got == expected
		"neq":    return got != expected
		"gt":     return _num(got) > _num(expected)
		"gte":    return _num(got) >= _num(expected)
		"lt":     return _num(got) < _num(expected)
		"lte":    return _num(got) <= _num(expected)
		"in":
			return expected is Array and (expected as Array).has(got)
		"not_in":
			return expected is Array and not (expected as Array).has(got)
		_: return false


func _num(v: Variant) -> float:
	if v is int or v is float: return float(v)
	if v is bool: return 1.0 if v else 0.0
	if v is String: return v.to_float()
	return NAN


func _attach_assert_screenshot(out: Dictionary) -> void:
	# Best-effort — failed assertion auto-captures so the agent has visual ctx.
	var shot := _take_screenshot({"return_base64": false})
	if bool(shot.get("ok", false)):
		out["screenshot_resource_path"] = shot["resource_path"]
		out["screenshot_absolute_path"] = shot["absolute_path"]


# =============================================================================
# §7.9 — Log
# =============================================================================
func _get_debug_log(args: Dictionary) -> Dictionary:
	var limit: int = clampi(int(args.get("limit", 50)), 1, LOG_RING_CAPACITY)
	var level: String = str(args.get("level", "error"))
	var filtered: Array = []
	for entry in _error_ring:
		if level == "all" or str(entry.get("level", "")) == level or (level == "error" and str(entry.get("level", "")) == "error"):
			filtered.append(entry)
	if filtered.size() > limit:
		filtered = filtered.slice(filtered.size() - limit, filtered.size())
	return {"ok": true, "entries": filtered, "count": filtered.size(), "level": level}


func _clear_debug_log(_args: Dictionary) -> Dictionary:
	var n := _error_ring.size() + _log_ring.size() + _print_ring.size()
	_error_ring.clear()
	_log_ring.clear()
	_print_ring.clear()
	return {"ok": true, "cleared": n}


func _get_print_log(args: Dictionary) -> Dictionary:
	var limit: int = clampi(int(args.get("limit", 100)), 1, PRINT_RING_CAPACITY)
	var entries := _print_ring.duplicate()
	if entries.size() > limit:
		entries = entries.slice(entries.size() - limit, entries.size())
	return {"ok": true, "entries": entries, "count": entries.size(),
			"hint": "Engine print() is not auto-captured by Godot. Use MCPRuntime.push_print(text) from your game scripts to surface a line here."}


# =============================================================================
# §7.10 — State mutation (bypasses input — use only when input simulation
# cannot reach the intended state e.g. teleport / spawn / direct heal).
# =============================================================================
func _set_node_property(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", ""))
	var prop: String = str(args.get("property", ""))
	var value = args.get("value")
	var node := _resolve_node(node_path)
	if node == null:
		return {"ok": false, "code": "NODE_NOT_FOUND", "error": "Node not found: %s" % node_path,
				"suggestions": _suggest_node_paths(node_path)}
	if not _node_has_property(node, prop):
		return {"ok": false, "code": "PROPERTY_NOT_FOUND",
				"error": "Property '%s' not on %s" % [prop, node.get_class()],
				"suggestions": _list_node_properties(node)}
	# Deserialize Vector2/3/Color if the caller passed our {type,x,y,…} format.
	var coerced := _deserialize(value)
	node.set(prop, coerced)
	return {"ok": true, "node_path": str(node.get_path()), "property": prop, "set_to": _serialize(node.get(prop))}


func _call_node_method(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", ""))
	var method: String = str(args.get("method", ""))
	var call_args: Array = args.get("args", [])
	var node := _resolve_node(node_path)
	if node == null:
		return {"ok": false, "code": "NODE_NOT_FOUND", "error": "Node not found: %s" % node_path}
	if not node.has_method(method):
		return {"ok": false, "code": "METHOD_NOT_FOUND",
				"error": "Method '%s' not on %s" % [method, node.get_class()]}
	var coerced: Array = []
	for a in call_args:
		coerced.append(_deserialize(a))
	var ret = node.callv(method, coerced)
	return {"ok": true, "node_path": str(node.get_path()), "method": method, "returned": _serialize(ret)}


func _add_node_runtime(args: Dictionary) -> Dictionary:
	var parent_path: String = str(args.get("parent_path", ""))
	var type_name: String = str(args.get("type", ""))
	var props: Dictionary = args.get("properties", {})
	var parent := _resolve_node(parent_path)
	if parent == null:
		return {"ok": false, "code": "NODE_NOT_FOUND", "error": "Parent not found: %s" % parent_path}
	if not ClassDB.class_exists(type_name):
		return {"ok": false, "code": "INVALID_TYPE", "error": "Class not found: %s" % type_name}
	var inst = ClassDB.instantiate(type_name)
	if inst == null or not inst is Node:
		return {"ok": false, "error": "Could not instantiate %s as Node" % type_name}
	var node: Node = inst
	if props.has("name"):
		node.name = str(props["name"])
	for k in props.keys():
		if str(k) == "name": continue
		node.set(str(k), _deserialize(props[k]))
	parent.add_child(node)
	# add_child does not set owner — for editor inspect we leave owner null.
	return {"ok": true, "added_path": str(node.get_path()), "type": type_name}


# =============================================================================
# Existing tools (query_runtime_node, get_runtime_log, list_signal_connections)
# =============================================================================
func _query_runtime_node(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path' (e.g. /root/Main/Player or relative path from current_scene)"}
	var properties: Array = args.get("properties", [])
	var include_children: bool = bool(args.get("include_children", false))
	var include_groups: bool = bool(args.get("include_groups", true))

	var node := _resolve_node(node_path)
	if node == null:
		return {"ok": false, "code": "NODE_NOT_FOUND",
				"error": "Node not found: %s" % node_path,
				"suggestions": _suggest_node_paths(node_path)}

	var info := {
		"ok": true,
		"name": str(node.name),
		"class": node.get_class(),
		"path": str(node.get_path()),
		"valid": true,
	}
	if include_groups:
		info["groups"] = node.get_groups()

	if properties.is_empty():
		properties = ["position", "global_position", "rotation", "scale", "visible", "modulate"]
	var prop_values := {}
	for pname_v in properties:
		var pname := str(pname_v)
		var v = node.get(pname)
		if v != null:
			prop_values[pname] = _serialize(v)
	info["properties"] = prop_values

	if include_children:
		var kids: Array = []
		for c in node.get_children():
			kids.append({"name": str(c.name), "class": c.get_class()})
		info["children"] = kids
	return info


func _get_runtime_log(args: Dictionary) -> Dictionary:
	var limit: int = clampi(int(args.get("limit", 200)), 1, LOG_RING_CAPACITY)
	var since_ms: int = int(args.get("since_ms", 0))
	var filtered: Array = []
	for entry in _log_ring:
		if entry.get("ts_ms", 0) >= since_ms:
			filtered.append(entry)
	if filtered.size() > limit:
		filtered = filtered.slice(filtered.size() - limit, filtered.size())
	return {
		"ok": true,
		"entries": filtered,
		"count": filtered.size(),
		"started_at_ms": _started_at_msec,
		"now_ms": Time.get_ticks_msec(),
	}


func _list_signal_connections(args: Dictionary) -> Dictionary:
	var node_path: String = str(args.get("node_path", "")).strip_edges()
	if node_path.is_empty():
		return {"ok": false, "error": "Missing 'node_path'"}
	var node := _resolve_node(node_path)
	if node == null:
		return {"ok": false, "code": "NODE_NOT_FOUND", "error": "Node not found: %s" % node_path}
	var outgoing: Array = []
	for sig in node.get_signal_list():
		var sig_name := str(sig["name"])
		for conn in node.get_signal_connection_list(sig_name):
			var callable: Callable = conn["callable"]
			var dst = callable.get_object()
			outgoing.append({
				"signal": sig_name,
				"to_object": str(dst.get_path()) if dst is Node else "<%s>" % (dst.get_class() if dst else "null"),
				"method": callable.get_method(),
				"flags": int(conn.get("flags", 0)),
			})
	return {
		"ok": true,
		"source": "runtime",
		"node_path": node_path,
		"outgoing": outgoing,
		"outgoing_count": outgoing.size(),
	}


# =============================================================================
# Helpers
# =============================================================================
func _resolve_node(node_path: String) -> Node:
	var tree := get_tree()
	if tree == null: return null
	var node: Node = null
	if node_path.begins_with("/"):
		node = tree.root.get_node_or_null(NodePath(node_path))
	else:
		var current := tree.current_scene
		if current:
			node = current.get_node_or_null(NodePath(node_path))
		if node == null:
			node = tree.root.get_node_or_null(NodePath(node_path))
	return node


func _suggest_node_paths(query: String) -> Array:
	# Cheap heuristic: enumerate the running scene tree up to depth 4, return
	# up to 5 paths that fuzzily match the requested basename.
	var tree := get_tree()
	if tree == null: return []
	var basename := query.get_file()
	var matches: Array = []
	var stack: Array = [tree.root]
	while stack.size() > 0 and matches.size() < 5:
		var n: Node = stack.pop_back()
		if str(n.name).find(basename) >= 0 and str(n.get_path()) != query:
			matches.append(str(n.get_path()))
		for c in n.get_children():
			stack.push_back(c)
	return matches


func _suggest_actions(query: String) -> Array:
	var out: Array = []
	var q := query.to_lower()
	for a in InputMap.get_actions():
		if str(a).to_lower().find(q) >= 0:
			out.append(str(a))
		if out.size() >= 8: break
	return out


func _node_has_property(node: Node, prop: String) -> bool:
	for p in node.get_property_list():
		if str(p.get("name", "")) == prop:
			return true
	return false


func _list_node_properties(node: Node) -> Array:
	var out: Array = []
	for p in node.get_property_list():
		var name := str(p.get("name", ""))
		if name.is_empty() or name.begins_with("_"): continue
		out.append(name)
		if out.size() >= 20: break
	return out


func _wait_ms(ms: int) -> void:
	if ms <= 0:
		return
	await get_tree().create_timer(ms / 1000.0).timeout


func _serialize(v: Variant) -> Variant:
	match typeof(v):
		TYPE_VECTOR2: return {"type": "Vector2", "x": v.x, "y": v.y}
		TYPE_VECTOR3: return {"type": "Vector3", "x": v.x, "y": v.y, "z": v.z}
		TYPE_COLOR: return {"type": "Color", "r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_RECT2: return {"type": "Rect2", "x": v.position.x, "y": v.position.y, "w": v.size.x, "h": v.size.y}
		TYPE_OBJECT:
			if v == null:
				return null
			return "<%s>" % v.get_class() if v.has_method("get_class") else "<Object>"
		_: return v


func _deserialize(v: Variant) -> Variant:
	# Inverse of _serialize for the JSON-roundtrippable container types. Plain
	# scalars pass through unchanged.
	if v is Dictionary and v.has("type"):
		match str(v["type"]):
			"Vector2": return Vector2(float(v.get("x", 0)), float(v.get("y", 0)))
			"Vector3": return Vector3(float(v.get("x", 0)), float(v.get("y", 0)), float(v.get("z", 0)))
			"Color":   return Color(float(v.get("r", 0)), float(v.get("g", 0)), float(v.get("b", 0)), float(v.get("a", 1)))
			"Rect2":   return Rect2(float(v.get("x", 0)), float(v.get("y", 0)), float(v.get("w", 0)), float(v.get("h", 0)))
	return v


# =============================================================================
# Public push_* helpers — user scripts call these to surface diagnostics
# =============================================================================
func push_runtime_log(level: String, text: String) -> void:
	if _log_ring.size() >= LOG_RING_CAPACITY:
		_log_ring.pop_front()
	_log_ring.append({"ts_ms": Time.get_ticks_msec(), "level": level, "text": text})


func push_print(text: String) -> void:
	if _print_ring.size() >= PRINT_RING_CAPACITY:
		_print_ring.pop_front()
	_print_ring.append({"ts_ms": Time.get_ticks_msec(), "text": text})


func push_engine_log(level: String, text: String) -> void:
	# `level` ∈ "info"/"warn"/"error". Errors/warnings feed
	# assert_no_errors_in_log; info routes into the legacy _log_ring.
	var entry := {"ts_ms": Time.get_ticks_msec(), "level": level, "text": text}
	if level in ["warn", "error"]:
		if _error_ring.size() >= ERROR_RING_CAPACITY:
			_error_ring.pop_front()
		_error_ring.append(entry)
	else:
		push_runtime_log(level, text)


# =============================================================================
# Phase 2 — Property bag snapshots
# =============================================================================
# A snapshot is a JSON file recording (node_path → {property → serialized_value})
# for a caller-supplied set of nodes and properties. Stored under
# CACHE_SNAPSHOT_DIR/<name>.json. Two pieces of state:
#   1. on-disk file (durable across sessions)
#   2. in-memory mirror (faster diff/restore — repopulated on first touch)
var _snapshots: Dictionary = {}


func _snapshot_capture(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	if not _is_safe_filename(name):
		return {"ok": false, "error": "name must match [A-Za-z0-9_.-]+ (got %s)" % name}
	var node_paths: Array = args.get("node_paths", [])
	var properties: Array = args.get("properties", [])
	var include_children: bool = bool(args.get("include_children", false))
	if node_paths.is_empty():
		return {"ok": false, "error": "Missing 'node_paths' (at least one required)"}
	if properties.is_empty():
		# Sensible default subset that covers most regression checks.
		properties = ["position", "global_position", "rotation", "scale", "visible", "modulate"]

	var entries := {}
	for raw_path_v in node_paths:
		var raw_path := str(raw_path_v)
		var targets: Array = []
		var node := _resolve_node(raw_path)
		if node == null:
			continue
		targets.append(node)
		if include_children:
			_collect_descendants(node, targets)
		for t in targets:
			var node_data := {}
			for pname_v in properties:
				var pname := str(pname_v)
				var v = t.get(pname)
				if v != null:
					node_data[pname] = _serialize(v)
			if not node_data.is_empty():
				entries[str(t.get_path())] = node_data

	var snapshot := {
		"name": name,
		"captured_at_ms": Time.get_ticks_msec(),
		"properties": properties,
		"entries": entries,
	}
	_snapshots[name] = snapshot
	var path := _persist_snapshot(name, snapshot)
	return {
		"ok": true,
		"name": name,
		"node_count": entries.size(),
		"property_count": properties.size(),
		"path": path,
	}


func _snapshot_restore(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	var snapshot := _load_snapshot(name)
	if snapshot.is_empty():
		return {"ok": false, "code": "SNAPSHOT_NOT_FOUND",
				"error": "No snapshot named '%s'" % name,
				"suggestions": _list_snapshot_names()}
	var entries: Dictionary = snapshot.get("entries", {})
	var restored := 0
	var missing: Array = []
	for node_path_v in entries.keys():
		var node_path := str(node_path_v)
		var node := _resolve_node(node_path)
		if node == null:
			missing.append(node_path)
			continue
		var props: Dictionary = entries[node_path]
		for pname_v in props.keys():
			var pname := str(pname_v)
			node.set(pname, _deserialize(props[pname]))
			restored += 1
	return {
		"ok": true,
		"name": name,
		"restored_assignments": restored,
		"missing_nodes": missing,
	}


func _snapshot_diff(args: Dictionary) -> Dictionary:
	var name_a: String = str(args.get("name_a", ""))
	var name_b: String = str(args.get("name_b", ""))
	if name_a.is_empty() or name_b.is_empty():
		return {"ok": false, "error": "Missing 'name_a' or 'name_b'"}
	var a := _load_snapshot(name_a)
	var b := _load_snapshot(name_b)
	if a.is_empty():
		return {"ok": false, "code": "SNAPSHOT_NOT_FOUND", "error": "Missing snapshot: %s" % name_a}
	if b.is_empty():
		return {"ok": false, "code": "SNAPSHOT_NOT_FOUND", "error": "Missing snapshot: %s" % name_b}

	var entries_a: Dictionary = a.get("entries", {})
	var entries_b: Dictionary = b.get("entries", {})
	var changes: Array = []
	var only_in_a: Array = []
	var only_in_b: Array = []
	for k in entries_a.keys():
		if not entries_b.has(k):
			only_in_a.append(str(k)); continue
		var pa: Dictionary = entries_a[k]
		var pb: Dictionary = entries_b[k]
		for pname in pa.keys():
			if not pb.has(pname):
				changes.append({"node_path": str(k), "property": str(pname), "a": pa[pname], "b": null, "kind": "removed"})
				continue
			if not _deep_equal(pa[pname], pb[pname]):
				changes.append({"node_path": str(k), "property": str(pname), "a": pa[pname], "b": pb[pname], "kind": "changed"})
		for pname in pb.keys():
			if not pa.has(pname):
				changes.append({"node_path": str(k), "property": str(pname), "a": null, "b": pb[pname], "kind": "added"})
	for k in entries_b.keys():
		if not entries_a.has(k):
			only_in_b.append(str(k))
	return {
		"ok": true,
		"name_a": name_a,
		"name_b": name_b,
		"changes": changes,
		"only_in_a": only_in_a,
		"only_in_b": only_in_b,
		"change_count": changes.size(),
		"identical": changes.is_empty() and only_in_a.is_empty() and only_in_b.is_empty(),
	}


func _snapshot_list(_args: Dictionary) -> Dictionary:
	var names := _list_snapshot_names()
	return {"ok": true, "snapshots": names, "count": names.size()}


# =============================================================================
# Snapshot helpers
# =============================================================================
func _persist_snapshot(name: String, snapshot: Dictionary) -> String:
	_ensure_dir(CACHE_SNAPSHOT_DIR)
	var path := "%s%s.json" % [CACHE_SNAPSHOT_DIR, name]
	var abs := ProjectSettings.globalize_path(path)
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(snapshot, "  "))
	f.close()
	return path


func _load_snapshot(name: String) -> Dictionary:
	if _snapshots.has(name):
		return _snapshots[name]
	var path := "%s%s.json" % [CACHE_SNAPSHOT_DIR, name]
	var abs := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs):
		return {}
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null: return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if parsed is Dictionary:
		_snapshots[name] = parsed
		return parsed
	return {}


func _list_snapshot_names() -> Array:
	var out: Array = []
	var abs := ProjectSettings.globalize_path(CACHE_SNAPSHOT_DIR)
	if not DirAccess.dir_exists_absolute(abs):
		return out
	var dir := DirAccess.open(abs)
	if dir == null: return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".json"):
			out.append(f.get_basename())
		f = dir.get_next()
	dir.list_dir_end()
	return out


func _collect_descendants(node: Node, out: Array) -> void:
	for c in node.get_children():
		out.append(c)
		_collect_descendants(c, out)


func _deep_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b): return false
	if a is Dictionary:
		var ad: Dictionary = a; var bd: Dictionary = b
		if ad.size() != bd.size(): return false
		for k in ad.keys():
			if not bd.has(k): return false
			if not _deep_equal(ad[k], bd[k]): return false
		return true
	if a is Array:
		var aa: Array = a; var ba: Array = b
		if aa.size() != ba.size(): return false
		for i in aa.size():
			if not _deep_equal(aa[i], ba[i]): return false
		return true
	if a is float and b is float:
		return absf(float(a) - float(b)) < 0.0001
	return a == b


# =============================================================================
# Phase 2 — Visual regression
# =============================================================================
# Baselines live under CACHE_BASELINE_DIR/<name>.{png,mask.png,meta.json}.
# meta.json records {algorithm, threshold, created_at_ms, width, height,
# sha256, last_compared}. mask.png is optional; black/transparent pixels there
# are excluded from comparison so animated regions (clocks, particle FX) can
# be ignored.

func _capture_baseline(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	if not _is_safe_filename(name):
		return {"ok": false, "error": "name must match [A-Za-z0-9_.-]+ (got %s)" % name}
	var algorithm: String = str(args.get("algorithm", "ssim"))
	var threshold: float = float(args.get("threshold", _default_threshold(algorithm)))
	var img := _grab_viewport_image()
	if img == null:
		return {"ok": false, "code": "RENDERING_REQUIRED", "error": "No viewport image (game not running?)"}
	_ensure_dir(CACHE_BASELINE_DIR)
	var png_path := "%s%s.png" % [CACHE_BASELINE_DIR, name]
	var meta_path := "%s%s.meta.json" % [CACHE_BASELINE_DIR, name]
	var abs_png := ProjectSettings.globalize_path(png_path)
	var save_err := img.save_png(abs_png)
	if save_err != OK:
		return {"ok": false, "error": "save_png failed: %s" % error_string(save_err)}
	var meta := {
		"name": name,
		"algorithm": algorithm,
		"threshold": threshold,
		"created_at_ms": Time.get_ticks_msec(),
		"width": img.get_width(),
		"height": img.get_height(),
		"sha256": _file_sha256(abs_png),
	}
	_write_json(meta_path, meta)
	return {
		"ok": true, "name": name, "png_path": png_path, "meta_path": meta_path,
		"width": img.get_width(), "height": img.get_height(),
		"algorithm": algorithm, "threshold": threshold,
	}


func _compare_with_baseline(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	var meta := _read_baseline_meta(name)
	if meta.is_empty():
		return {"ok": false, "code": "BASELINE_NOT_FOUND",
				"error": "No baseline named '%s'" % name,
				"suggestions": _list_baseline_names()}
	var algorithm: String = str(args.get("algorithm", meta.get("algorithm", "ssim")))
	var threshold: float = float(args.get("threshold", meta.get("threshold", _default_threshold(algorithm))))
	var baseline_path := "%s%s.png" % [CACHE_BASELINE_DIR, name]
	var baseline_img := _load_image(baseline_path)
	if baseline_img == null:
		return {"ok": false, "error": "Could not read baseline PNG: %s" % baseline_path}
	var current_img := _grab_viewport_image()
	if current_img == null:
		return {"ok": false, "code": "RENDERING_REQUIRED", "error": "No viewport image"}

	if current_img.get_size() != baseline_img.get_size():
		return {"ok": false, "code": "SIZE_MISMATCH",
				"error": "Current %s vs baseline %s — update_baseline or resize the viewport"
				 % [str(current_img.get_size()), str(baseline_img.get_size())]}

	var mask_img: Image = null
	var mask_path := "%s%s.mask.png" % [CACHE_BASELINE_DIR, name]
	var abs_mask := ProjectSettings.globalize_path(mask_path)
	if FileAccess.file_exists(abs_mask):
		mask_img = _load_image(mask_path)

	var score := _compare_images(baseline_img, current_img, mask_img, algorithm)
	var pass_check := _passes_threshold(algorithm, score, threshold)
	# Save diff visualization for fail cases — helpful for the agent.
	var diff_png_path := ""
	if not pass_check:
		diff_png_path = _save_diff_viz(name, baseline_img, current_img, mask_img)

	# Touch meta with last comparison stats.
	meta["last_compared_at_ms"] = Time.get_ticks_msec()
	meta["last_score"] = score
	meta["last_pass"] = pass_check
	_write_json("%s%s.meta.json" % [CACHE_BASELINE_DIR, name], meta)

	return {
		"ok": pass_check,
		"name": name, "algorithm": algorithm,
		"score": score, "threshold": threshold,
		"size": [current_img.get_width(), current_img.get_height()],
		"mask_used": mask_img != null,
		"diff_png_path": diff_png_path,
		"error": "" if pass_check else "Visual regression: %s score=%.4f vs threshold=%.4f" % [algorithm, score, threshold],
	}


func _update_baseline(args: Dictionary) -> Dictionary:
	# Same flow as capture_baseline; semantically distinct so the agent can
	# audit which scenes it "agreed to drift on".
	return _capture_baseline(args)


func _update_mask(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	var region = args.get("region", null)
	var clear: bool = bool(args.get("clear", false))
	var meta := _read_baseline_meta(name)
	if meta.is_empty():
		return {"ok": false, "code": "BASELINE_NOT_FOUND", "error": "No baseline named '%s'" % name}
	var w: int = int(meta.get("width", 0))
	var h: int = int(meta.get("height", 0))
	var mask_path := "%s%s.mask.png" % [CACHE_BASELINE_DIR, name]
	var abs_mask := ProjectSettings.globalize_path(mask_path)

	var mask: Image
	if FileAccess.file_exists(abs_mask) and not clear:
		mask = _load_image(mask_path)
	else:
		# Default mask = fully WHITE (everything compared). Painting black =
		# excluded keeps the convention from the plan §10.2.
		mask = Image.create(w, h, false, Image.FORMAT_RGBA8)
		mask.fill(Color(1, 1, 1, 1))

	if region != null and region is Dictionary:
		var rx: int = int(region.get("x", 0))
		var ry: int = int(region.get("y", 0))
		var rw: int = int(region.get("w", 0))
		var rh: int = int(region.get("h", 0))
		var rect := Rect2i(rx, ry, rw, rh).intersection(Rect2i(0, 0, w, h))
		for y in range(rect.position.y, rect.position.y + rect.size.y):
			for x in range(rect.position.x, rect.position.x + rect.size.x):
				mask.set_pixel(x, y, Color(0, 0, 0, 1))

	_ensure_dir(CACHE_BASELINE_DIR)
	var err := mask.save_png(abs_mask)
	if err != OK:
		return {"ok": false, "error": "save_png failed: %s" % error_string(err)}
	return {"ok": true, "name": name, "mask_path": mask_path, "cleared": clear}


func _list_baselines(_args: Dictionary) -> Dictionary:
	var names := _list_baseline_names()
	var rows: Array = []
	for n in names:
		var m := _read_baseline_meta(str(n))
		if not m.is_empty():
			rows.append({
				"name": str(n),
				"algorithm": m.get("algorithm", ""),
				"threshold": m.get("threshold", 0.0),
				"width": m.get("width", 0),
				"height": m.get("height", 0),
				"created_at_ms": m.get("created_at_ms", 0),
				"last_score": m.get("last_score"),
				"last_pass": m.get("last_pass"),
			})
	return {"ok": true, "baselines": rows, "count": rows.size()}


func _delete_baseline(args: Dictionary) -> Dictionary:
	var name: String = str(args.get("name", "")).strip_edges()
	if name.is_empty():
		return {"ok": false, "error": "Missing 'name'"}
	var deleted: Array = []
	for suffix in [".png", ".mask.png", ".meta.json"]:
		var rel := "%s%s%s" % [CACHE_BASELINE_DIR, name, suffix]
		var abs := ProjectSettings.globalize_path(rel)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)
			deleted.append(rel)
	if deleted.is_empty():
		return {"ok": false, "code": "BASELINE_NOT_FOUND", "error": "No baseline named '%s'" % name}
	return {"ok": true, "name": name, "deleted": deleted}


func _compare_screenshots_adhoc(args: Dictionary) -> Dictionary:
	var a_b64: String = str(args.get("a_b64", ""))
	var b_b64: String = str(args.get("b_b64", ""))
	if a_b64.is_empty() or b_b64.is_empty():
		return {"ok": false, "error": "Missing 'a_b64' or 'b_b64' (base64-encoded PNG)"}
	var algorithm: String = str(args.get("algorithm", "ssim"))
	var threshold: float = float(args.get("threshold", _default_threshold(algorithm)))
	var a_img := _image_from_b64(a_b64)
	var b_img := _image_from_b64(b_b64)
	if a_img == null or b_img == null:
		return {"ok": false, "error": "Could not decode base64 PNG"}
	if a_img.get_size() != b_img.get_size():
		return {"ok": false, "code": "SIZE_MISMATCH",
				"error": "Image A %s vs B %s" % [str(a_img.get_size()), str(b_img.get_size())]}
	var score := _compare_images(a_img, b_img, null, algorithm)
	var pass_check := _passes_threshold(algorithm, score, threshold)
	return {
		"ok": pass_check, "algorithm": algorithm, "score": score, "threshold": threshold,
		"size": [a_img.get_width(), a_img.get_height()],
		"error": "" if pass_check else "Ad-hoc compare: %s score=%.4f vs threshold=%.4f" % [algorithm, score, threshold],
	}


# =============================================================================
# Image comparison algorithms
# =============================================================================
func _compare_images(a: Image, b: Image, mask: Image, algorithm: String) -> float:
	# Normalize to RGB8 — alpha channel is irrelevant for visual regression.
	var aa := a.duplicate() as Image
	var bb := b.duplicate() as Image
	if aa.get_format() != Image.FORMAT_RGB8: aa.convert(Image.FORMAT_RGB8)
	if bb.get_format() != Image.FORMAT_RGB8: bb.convert(Image.FORMAT_RGB8)
	match algorithm:
		"mae":            return _alg_mae(aa, bb, mask)
		"pixel_diff_pct": return _alg_pixel_diff_pct(aa, bb, mask, 8)
		"ssim":           return _alg_ssim(aa, bb, mask)
		_:                return _alg_ssim(aa, bb, mask)


func _alg_mae(a: Image, b: Image, mask: Image) -> float:
	# Mean Absolute Error per channel, normalized to [0,1]. Lower = closer.
	var w := a.get_width(); var h := a.get_height()
	var total := 0.0
	var counted := 0
	for y in h:
		for x in w:
			if not _pixel_unmasked(mask, x, y): continue
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			counted += 1
	if counted == 0: return 0.0
	return total / (counted * 3.0)


func _alg_pixel_diff_pct(a: Image, b: Image, mask: Image, channel_threshold: int) -> float:
	# Fraction of pixels where any channel differs by more than the threshold
	# (out of 255). Returns 0.0 for identical, up to 1.0 for fully different.
	var w := a.get_width(); var h := a.get_height()
	var diff := 0
	var counted := 0
	var ct := channel_threshold / 255.0
	for y in h:
		for x in w:
			if not _pixel_unmasked(mask, x, y): continue
			counted += 1
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) > ct or absf(ca.g - cb.g) > ct or absf(ca.b - cb.b) > ct:
				diff += 1
	if counted == 0: return 0.0
	return float(diff) / float(counted)


func _alg_ssim(a: Image, b: Image, mask: Image) -> float:
	# Block-based SSIM on luminance — 8×8 non-overlapping blocks. Returns 1.0
	# for identical images, decreasing toward 0 / negative for very different.
	# Simplification vs the canonical 11×11 Gaussian — we use uniform 8×8
	# windows which is ~2× faster and well-suited to pixel-art regression.
	var w := a.get_width(); var h := a.get_height()
	var blocks_x: int = w / SSIM_BLOCK
	var blocks_y: int = h / SSIM_BLOCK
	if blocks_x == 0 or blocks_y == 0: return _alg_mae(a, b, mask)  # tiny images
	var sum_ssim := 0.0
	var counted := 0
	for by in blocks_y:
		for bx in blocks_x:
			var x0 := bx * SSIM_BLOCK
			var y0 := by * SSIM_BLOCK
			if not _block_unmasked(mask, x0, y0, SSIM_BLOCK): continue
			var stats_a := _block_luma_stats(a, x0, y0)
			var stats_b := _block_luma_stats(b, x0, y0)
			var cov := _block_luma_cov(a, b, x0, y0, stats_a.mean, stats_b.mean)
			var num := (2.0 * stats_a.mean * stats_b.mean + SSIM_C1) * (2.0 * cov + SSIM_C2)
			var den := (stats_a.mean * stats_a.mean + stats_b.mean * stats_b.mean + SSIM_C1) \
					 * (stats_a.var_ + stats_b.var_ + SSIM_C2)
			if den == 0.0: continue
			sum_ssim += num / den
			counted += 1
	if counted == 0: return 1.0
	return sum_ssim / float(counted)


func _block_luma_stats(img: Image, x0: int, y0: int) -> Dictionary:
	# Rec. 601 luma weights × 255 (work in 0..255 space so c1/c2 land correctly).
	var n := float(SSIM_BLOCK * SSIM_BLOCK)
	var sum := 0.0
	var sq_sum := 0.0
	for y in range(y0, y0 + SSIM_BLOCK):
		for x in range(x0, x0 + SSIM_BLOCK):
			var c := img.get_pixel(x, y)
			var l := (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) * 255.0
			sum += l
			sq_sum += l * l
	var mean := sum / n
	var var_ := (sq_sum / n) - (mean * mean)
	return {"mean": mean, "var_": var_}


func _block_luma_cov(a: Image, b: Image, x0: int, y0: int, mean_a: float, mean_b: float) -> float:
	var n := float(SSIM_BLOCK * SSIM_BLOCK)
	var sum := 0.0
	for y in range(y0, y0 + SSIM_BLOCK):
		for x in range(x0, x0 + SSIM_BLOCK):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var la := (0.299 * ca.r + 0.587 * ca.g + 0.114 * ca.b) * 255.0
			var lb := (0.299 * cb.r + 0.587 * cb.g + 0.114 * cb.b) * 255.0
			sum += (la - mean_a) * (lb - mean_b)
	return sum / n


func _pixel_unmasked(mask: Image, x: int, y: int) -> bool:
	if mask == null: return true
	var c := mask.get_pixel(x, y)
	# Excluded if pixel is fully black (per plan §10.2). We treat alpha=0 the
	# same way so user can paint a transparent mask in a paint app.
	return not (c.r < 0.05 and c.g < 0.05 and c.b < 0.05) and c.a > 0.05


func _block_unmasked(mask: Image, x0: int, y0: int, size: int) -> bool:
	if mask == null: return true
	# Block is considered unmasked if ANY pixel in it is unmasked. Conservative
	# — partial masks still contribute (a stricter alternative would require all
	# pixels unmasked, but that throws away too much signal).
	for y in range(y0, y0 + size):
		for x in range(x0, x0 + size):
			if _pixel_unmasked(mask, x, y):
				return true
	return false


func _save_diff_viz(name: String, a: Image, b: Image, mask: Image) -> String:
	# Pixel-difference visualization: max(|a-b|) per channel scaled ×4 for
	# visibility, masked pixels rendered semi-transparent red.
	var w := a.get_width(); var h := a.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in h:
		for x in w:
			if not _pixel_unmasked(mask, x, y):
				out.set_pixel(x, y, Color(0.4, 0.0, 0.0))
				continue
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := Color(
				clampf(absf(ca.r - cb.r) * 4.0, 0.0, 1.0),
				clampf(absf(ca.g - cb.g) * 4.0, 0.0, 1.0),
				clampf(absf(ca.b - cb.b) * 4.0, 0.0, 1.0))
			out.set_pixel(x, y, d)
	_ensure_dir(CACHE_BASELINE_DIR)
	var rel := "%sdiff_%s_%d.png" % [CACHE_BASELINE_DIR, name, Time.get_ticks_msec()]
	var abs := ProjectSettings.globalize_path(rel)
	out.save_png(abs)
	return rel


# =============================================================================
# Baseline helpers
# =============================================================================
func _grab_viewport_image() -> Image:
	var vp := get_viewport()
	if vp == null: return null
	return vp.get_texture().get_image()


func _read_baseline_meta(name: String) -> Dictionary:
	var rel := "%s%s.meta.json" % [CACHE_BASELINE_DIR, name]
	var abs := ProjectSettings.globalize_path(rel)
	if not FileAccess.file_exists(abs): return {}
	var f := FileAccess.open(abs, FileAccess.READ)
	if f == null: return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	return parsed if parsed is Dictionary else {}


func _list_baseline_names() -> Array:
	var out: Array = []
	var abs := ProjectSettings.globalize_path(CACHE_BASELINE_DIR)
	if not DirAccess.dir_exists_absolute(abs): return out
	var dir := DirAccess.open(abs)
	if dir == null: return out
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not dir.current_is_dir() and f.ends_with(".meta.json"):
			out.append(f.substr(0, f.length() - ".meta.json".length()))
		f = dir.get_next()
	dir.list_dir_end()
	return out


func _default_threshold(algorithm: String) -> float:
	# Direction of the test depends on the algorithm — see _passes_threshold.
	match algorithm:
		"mae":            return 0.02   # ≤ 2% mean absolute pixel error
		"pixel_diff_pct": return 0.01   # ≤ 1% pixels differ noticeably
		"ssim":           return 0.98   # ≥ 0.98 structural similarity
		_:                return 0.98


func _passes_threshold(algorithm: String, score: float, threshold: float) -> bool:
	match algorithm:
		"mae":            return score <= threshold
		"pixel_diff_pct": return score <= threshold
		"ssim":           return score >= threshold
		_:                return score >= threshold


func _load_image(rel_path: String) -> Image:
	var abs := ProjectSettings.globalize_path(rel_path)
	var img := Image.new()
	if img.load(abs) != OK:
		return null
	return img


func _image_from_b64(b64: String) -> Image:
	var bytes := Marshalls.base64_to_raw(b64)
	if bytes.is_empty(): return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	return img


func _file_sha256(abs_path: String) -> String:
	if not FileAccess.file_exists(abs_path): return ""
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null: return ""
	while not f.eof_reached():
		var chunk := f.get_buffer(65536)
		if chunk.size() > 0: h.update(chunk)
	f.close()
	return h.finish().hex_encode()


# =============================================================================
# Common file helpers
# =============================================================================
func _is_safe_filename(name: String) -> bool:
	# Match [A-Za-z0-9_.-]+, no leading dot. Guards against `../escape`,
	# hidden-file weirdness, and JSON-key-collision via slashes.
	if name.is_empty() or name.begins_with("."):
		return false
	for c in name:
		var ch: int = c.unicode_at(0)
		var ok := \
			(ch >= 0x30 and ch <= 0x39) or \
			(ch >= 0x41 and ch <= 0x5A) or \
			(ch >= 0x61 and ch <= 0x7A) or \
			ch == 0x2E or ch == 0x2D or ch == 0x5F  # . - _
		if not ok: return false
	return true


func _write_json(rel_path: String, data: Dictionary) -> bool:
	_ensure_dir(rel_path.get_base_dir() + "/")
	var abs := ProjectSettings.globalize_path(rel_path)
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f == null: return false
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return true


func _ensure_dir(rel_dir: String) -> void:
	var abs := ProjectSettings.globalize_path(rel_dir)
	if not DirAccess.dir_exists_absolute(abs):
		DirAccess.make_dir_recursive_absolute(abs)


# =============================================================================
func _ensure_cache_dir() -> void:
	_ensure_dir(CACHE_SCREENSHOT_DIR)


func _send(msg: Dictionary) -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(msg))
