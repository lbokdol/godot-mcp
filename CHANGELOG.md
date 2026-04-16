# Changelog

## [0.4.4] - 2026-04-16

### Fixed
- **`modify_node_property` schema missing `items` on array type** — the `value` parameter's `oneOf` included `{ type: 'array' }` without the `items` field required by strict JSON Schema validators, causing the tool to fail to register in clients like GitHub Copilot ([#44](https://github.com/tomyud1/godot-mcp/issues/44))

## [0.4.3] - 2026-04-14

### Added
- **`set_mesh` tool** — assign primitive meshes (BoxMesh, SphereMesh, CylinderMesh, CapsuleMesh, PlaneMesh, PrismMesh, TorusMesh, QuadMesh, TextMesh) or file-based meshes to MeshInstance3D nodes, making 3D geometry visible from MCP
- **`set_material` tool** — create and assign StandardMaterial3D (albedo, metallic, roughness, emission, transparency) or load materials from file; supports MeshInstance3D, CSG, and GeometryInstance3D nodes
- **`instance_scene` tool** — add scene instances (prefabs) as child nodes with live references to the source `.tscn`, enabling composable scene building from MCP
- **`get_node_spatial_info` tool** — query computed 3D spatial data (local/global transforms, positions, scales, rotation quaternions, subtree bounding boxes) for Node3D nodes
- **`measure_node_distance` tool** — measure world-space 3D distance and horizontal XZ distance between two Node3D nodes
- **`snap_node_to_grid` tool** — snap a Node3D position to a grid in local or global space, with per-axis control
- **VariantCodec** — shared serialization/parsing for Godot variant types, adding support for Quaternion, Basis, Transform3D, and AABB across all tools
- **TS/GDScript alignment test** — test suite now verifies that every MCP tool definition has a matching handler in the Godot plugin executor

### Fixed
- **Stale primary server breaks new tools after updates** — when a new MCP server instance detected an existing primary, it blindly proxied to it even if the primary was running old code. New instances now compare both version and tool count; mismatched primaries are automatically replaced ([#43](https://github.com/tomyud1/godot-mcp/pull/43))
- **`read_scene` root node self-reference** — the root node no longer reports a spurious `instance` field pointing to its own scene file; instance field now only appears on actual child instances
- **`add_node` name reporting** — `add_node` now uses readable names (`add_child(node, true)`) and reports the actual assigned name (which may differ from the requested name if there was a conflict)
- **`set_collision_shape` size parsing** — size parameter now uses the shared `_parse_value` instead of manual dict parsing, supporting the same type inference as other tools
- **`modify_node_property` now supports 3D types** — Quaternion, Basis, Transform3D, and AABB values can now be set via `modify_node_property`, not just vectors and colors
- **Duplicate `_parse_value`/`_serialize_value`** — extracted into shared VariantCodec, eliminating duplicated code between `scene_tools.gd` and `project_tools.gd`
- **Inherited scene instantiation** — `_load_scene` now uses `GEN_EDIT_STATE_MAIN_INHERITED` for inherited scenes and `GEN_EDIT_STATE_INSTANCE` for scene instances, fixing editor-aware PackedScene handling

## [0.4.2] - 2026-04-09

### Added
- **Automated test suite** — 49 tests using Vitest covering GodotBridge (lifecycle, connection management, WebSocket protocol), PrimaryHttpServer (lifecycle, all HTTP endpoints), proxy client (probe, tool forwarding, register/unregister), and tool registry (schema validation, uniqueness). Run with `cd mcp-server && npm test`. ([#37](https://github.com/tomyud1/godot-mcp/issues/37))
- **TESTING.md** — comprehensive test checklist (automated + manual pre-release) at the repo root, designed to be extended over time

### Fixed
- **Zombie process on non-EADDRINUSE startup failure** — if the WebSocket or HTTP server failed to start for a reason other than port conflict (e.g., invalid port, permission error), the process continued running but could never accept connections. Now the server exits with code 1 and a clear error message when the WebSocket server fails to bind. HTTP-only failure logs a warning but continues (direct client still works). Added `isListening()` to both `GodotBridge` and `PrimaryHttpServer` for post-startup health checks. ([#36](https://github.com/tomyud1/godot-mcp/issues/36))
- **`sendClientStatus` type safety** — added `ClientStatusMessage` to the `WebSocketMessage` union type and removed the `as unknown as WebSocketMessage` double cast in `GodotBridge.sendClientStatus()`. The message is now properly type-checked.

## [0.4.1] - 2026-04-04

### Added
- **AI agent connection status in editor toolbar** — the toolbar indicator now distinguishes between three states: `MCP: Connecting...` (yellow, no server), `MCP: No Agent` (orange, server running but no AI client attached), and `MCP: Agent Active` (green, AI client connected). Previously "Connected" showed green even when the server was running with no AI client open. Supports multiple simultaneous agents (`MCP: Agents (N)`).

### Fixed
- **`get_input_map` missing project-defined actions** — custom actions (`jump`, `sprint`, etc.) were never returned because the editor's `InputMap` object only contains built-ins and actions added during the current session; project-defined actions live in `ProjectSettings`. The fix merges both sources so all actions are returned.
- **`get_input_map` incorrect deadzone for project actions** — all actions were returning `0.2` (the built-in default) instead of the actual value from `project.godot`. Deadzones for project-defined actions are now read directly from `ProjectSettings` rather than from the editor's stale `InputMap`.
- **`configure_input_map` deadzone ignored** — deadzone parameter is now correctly applied and persisted to `project.godot`
- **`update_project_settings` corrupted input mappings** — `input/*` keys are now merged with existing settings (preserving the `events` array) instead of overwriting the whole entry; deadzone-only updates no longer wipe key bindings
- **`list_settings` stale data documented** — description now explicitly states that values reflect the editor's in-memory state and direct edits to `project.godot` on disk are not reflected until the editor restarts (`rescan_filesystem` does not help)

## [0.4.0] - 2026-04-01

### Added
- **Multi-session support (connect-or-spawn architecture)** — multiple AI clients (Claude, Cursor, Codex, etc.) can now use Godot tools simultaneously. The first instance becomes the primary server; subsequent instances automatically detect it and enter proxy mode, forwarding tool calls via HTTP. Zero configuration change — same stdio setup as before. ([#24](https://github.com/tomyud1/godot-mcp/issues/24))
- **HTTP bridge for proxy communication** — primary server exposes a lightweight HTTP API on port 6506 (configurable via `GODOT_MCP_HTTP_PORT`) with health check and tool forwarding endpoints
- **`GODOT_MCP_HTTP_PORT` env var** — configure the HTTP bridge port (default: 6506)
- **`GODOT_MCP_IDLE_TIMEOUT_MS` env var** — configure how long the primary server stays alive after all clients and Godot disconnect (default: 30000ms)

### Fixed
- **"Transport closed" on Windows/Codex** — primary mode no longer exits when stdin closes; the server stays alive for proxy clients and Godot, only shutting down after an idle timeout when all connections are gone ([#16](https://github.com/tomyud1/godot-mcp/issues/16))
- **Cross-platform `killProcessOnPort`** — replaced `execSync('sleep 1')` with async `setTimeout`, fixing the missing post-kill delay on Windows that caused `EADDRINUSE` race conditions
- **Smarter zombie detection** — the server now probes for a healthy primary before killing anything on the port; only genuinely unresponsive processes get terminated, preventing one AI session from killing another's server
- **Startup race condition** — when two instances start simultaneously and both try to become primary, the loser re-probes and falls back to proxy mode instead of killing the winner

## [0.3.0] - 2026-03-31

### Added
- **`classdb_query` tool** — query Godot's ClassDB for class properties, methods, signals, and inheritance; lets the AI verify real API signatures before writing code instead of guessing from training data (suggested by [@elfensky](https://github.com/elfensky), [#19](https://github.com/tomyud1/godot-mcp/issues/19))
- **`run_scene` / `stop_scene` / `is_playing` tools** — run, stop, and check scene status from the AI, enabling autonomous edit→run→debug loops without user intervention (suggested by [@elfensky](https://github.com/elfensky), [#18](https://github.com/tomyud1/godot-mcp/issues/18))
- **Configurable timeout and port** — `GODOT_MCP_TIMEOUT_MS` and `GODOT_MCP_PORT` environment variables to override the 30s tool timeout and 6505 WebSocket port (suggested by [@elfensky](https://github.com/elfensky), [#20](https://github.com/tomyud1/godot-mcp/issues/20))
- **`rescan_filesystem` tool** — trigger a full filesystem rescan from the AI after creating or modifying files externally
- **Tool description cross-references** — `get_errors`, `edit_script`, and `create_script` descriptions now guide the AI to use `classdb_query` for API verification and `run_scene` for testing after changes

### Improved
- **`get_errors` now reads both sources** — reads the Output panel *and* the Debugger > Errors tab in a single call, returning runtime errors with stack traces that were previously invisible; each error includes a `source` field (`"output"` or `"debugger"`) (debugger scraping based on [@byronhulcher](https://github.com/byronhulcher)'s approach, [PR #15](https://github.com/tomyud1/godot-mcp/pull/15))
- **Tool executor null guard** — tools that crash at runtime now return a clear error instead of silently timing out (based on [@elfensky](https://github.com/elfensky)'s approach, [PR #22](https://github.com/tomyud1/godot-mcp/pull/22))

### Fixed
- **WebSocket buffer sizes increased** — outbound buffer raised to 4 MB, inbound to 1 MB; fixes `map_project` and other large responses being silently dropped on non-trivial projects (reported by [@rconlan](https://github.com/rconlan), [#14](https://github.com/tomyud1/godot-mcp/issues/14))
- **WebSocket server binds to IPv4** — explicitly binds to `127.0.0.1` instead of letting the `ws` library default to `::` (IPv6); fixes silent connection failures on systems without IPv6 dual-stack (reported by [@elfensky](https://github.com/elfensky), [#17](https://github.com/tomyud1/godot-mcp/issues/17))
- **WebSocket reconnection fix** — creates a fresh `WebSocketPeer` on every reconnect attempt instead of reusing a closed peer that can get stuck in `STATE_CONNECTING` forever (Godot issue #81839) (based on [@elfensky](https://github.com/elfensky)'s fix, [PR #22](https://github.com/tomyud1/godot-mcp/pull/22))
- **Reconnection after failed retries** — the plugin now retries indefinitely with exponential backoff when the server is unreachable, instead of silently giving up after the first failed attempt
- **JSON string args auto-parsed** — tool arguments that arrive as JSON strings (e.g. `"{\"key\": \"value\"}"` instead of a Dictionary) are now automatically parsed at the executor level, fixing `update_project_settings` and protecting all tools from MCP clients that serialize nested objects as strings (reported by [@elfensky](https://github.com/elfensky), [#26](https://github.com/tomyud1/godot-mcp/issues/26))

## [0.2.8] - 2026-03-14

### Fixed
- **Server survives MCP client exit** — the server now shuts down when stdin closes, so closing Claude/Cursor properly terminates the process, releases port 6505, and lets the Godot plugin detect the disconnect (status turns red). Previously the server stayed alive as a zombie, blocking reconnection on next launch ([#10](https://github.com/tomyud1/godot-mcp/issues/10))

## [0.2.7] - 2026-03-11

### Fixed
- **Zombie server port conflicts** — the server now auto-kills any existing process on port 6505 before starting; MCP clients (Claude Desktop, Cursor) often leave old server processes alive when restarting, which silently blocked the new instance from binding
- **EADDRINUSE error now loud and clear** — instead of silently falling back, the server logs an actionable error message explaining exactly what happened and how to fix it

### Removed
- **Mock mode** — tools no longer return fake data when Godot isn't connected; they return a clear error with instructions to connect

### Changed
- **Pinned `@modelcontextprotocol/sdk` to `~1.25.2`** — version 1.27.x introduced stdio transport instability for npx users
- **Faster Godot plugin reconnect** — backoff reduced from 3–30s to 2–10s

## [0.2.6] - 2026-03-08

### Added
- **`list_settings` tool** — browse project settings by category; returns current values, types, and valid options (enums, ranges)
- **`update_project_settings` tool** — write project settings by path; tool description guides the AI to use `list_settings` first
- **`configure_input_map` tool** — add, remove, or replace input actions and key/button bindings with live editor UI refresh
- **`setup_autoload` tool** — register, unregister, or list autoload singletons

### Fixed
- **Input Map editor refreshes live** — calls the editor's internal `_update_action_map_editor()` after changes so the Project Settings UI stays in sync

## [0.2.5] - 2026-03-06

### Changed
- **StringName dictionary keys** across all GDScript files — avoids per-frame string allocations for dictionary lookups
- **Typed for loops** — explicit type annotations on loop variables throughout all tool files
- **Bulk file read in `search_project`** — reads whole file and does a quick `find()` before line-by-line scanning, skipping non-matching files entirely
- **`_SKIP_EXTENSIONS` Dictionary** — O(1) extension filtering in `_collect_files_recursive` (was O(n) array scan)
- **`_SKIP_PROPS` Dictionary** — O(1) property filtering in `get_node_properties` and `get_scene_node_properties`
- **`PackedStringArray`** for `list_dir` results, `_collect_files`, and `_dump_node` tree building
- **`MAX_TRAVERSAL_DEPTH` guard** — prevents runaway recursion in `_collect_files_recursive` (cap at 20 levels)
- **`MAX_PACKETS_PER_FRAME` cap** — limits WebSocket packet processing to 32 per frame to prevent editor stalls
- **`127.0.0.1` instead of `localhost`** — avoids DNS lookup on every connection attempt
- **`_parse_value` improvement** — uses `value is Dictionary` instead of `typeof()` check, single `.get()` for type field

### Fixed
- **`SERVER_VERSION` constant** now matches `package.json` (was stuck at `0.2.0`)

## [0.2.4] - 2026-02-23

### Changed
- **Published to official MCP registry** — `godot-mcp-server` is now listed at `registry.modelcontextprotocol.io` as `io.github.tomyud1/godot-mcp`
- **Updated npm README** — fully reflects current features, tools, visualizer screenshot, and npx-based install
- **Added `server.json`** — MCP registry manifest for automated discovery
- **Updated `package.json`** — added `mcpName` and `repository` fields required by the MCP registry

## [0.2.3] - 2026-02-23

### Changed
- Minor package metadata update (intermediate release during registry setup)

## [0.2.2] - 2026-02-23

### Fixed
- **`create_scene` schema now valid for strict MCP clients** — added missing `items` field to the `nodes` array property, fixing Windsurf/Cascade rejecting the tool with "array schema missing items"

## [0.2.1] - 2026-02-17

### Changed
- **Moved plugin to repo root** — `addons/godot_mcp/` is now at the repo root instead of nested under `godot-plugin/`, matching the Godot Asset Library expected layout
- **Added `.gitattributes`** — Asset Library downloads now only include the `addons/` folder
- **Updated install instructions** — README and SUMMARY reflect the new path

## [0.2.0] - 2026-02-11

### Fixed
- **Console log and error tools now work reliably** — reads directly from the editor's Output panel instead of the buffered log file on disk, which was returning stale/incomplete data
- **`get_errors` returns newest errors first** — previously returned oldest errors from the start of the log
- **`get_errors` uses proper Godot error patterns** — matches `ERROR:`, `SCRIPT ERROR:`, `WARNING:`, etc. instead of naively matching any line containing the word "error"
- **`clear_console_log` actually clears the Output panel** — previously was a no-op that returned a fake "acknowledged" message
- **`validate_script` bypasses resource cache** — creates a fresh GDScript instance from the file on disk so edits are validated correctly, not stale cached versions
- **`validate_script` returns actual error details** — extracts parse errors from the Output panel instead of just saying "check Godot console"

### Changed
- **Renamed `apply_diff_preview` to `edit_script`** — clearer name for the code editing tool
- **`scene_tree_dump` description corrected** — now accurately says it dumps the scene open in the editor, not a "running" scene
- **Removed dead code** — cleaned up unused `_console_buffer` and `MAX_CONSOLE_LINES`

### Removed
- **Removed `search_comfyui_nodes` tool** — was a non-functional stub that cluttered the tool list
- **Hidden RunningHub tools from MCP** — `inspect_runninghub_workflow` and `customize_and_run_workflow` are not exposed until properly documented (GDScript implementations preserved)

## [0.1.0] - 2025-01-28

### Added
- Initial release
- 32 MCP tools across 6 categories
- Godot editor plugin with WebSocket bridge
- Interactive browser-based project visualizer
