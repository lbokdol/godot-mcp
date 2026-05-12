/**
 * Runtime tool definitions — exposed to MCP clients, routed to MCPRuntime
 * autoload inside the user's running game (role=runtime on the WebSocket).
 *
 * Tool naming and behaviour mirror §7 of docs/godot_ai_test_planning.md.
 * Descriptions follow the 5-section pattern (USE WHEN / DO NOT USE / COMMON
 * FAILURE / EXAMPLE) so the agent's tool-picker has a strong signal for the
 * Action > Node-click > Raw-input preference.
 */

import type { ToolDefinition } from '../types.js';

// ---------------------------------------------------------------------------
// §7.1 — Execution (handled by editor-side tools `run_scene` / `stop_scene`)
//
// Those already exist in mcp-server/src/tools/project-tools.ts. We re-expose
// them here under the canonical names `play_scene` / `stop_scene` from the
// plan so agents reading the runtime catalog find them without grepping the
// editor tool list. Their dispatchers in godot-bridge route by NAME — see
// EDITOR_FORWARD_TOOLS in index.ts.
// ---------------------------------------------------------------------------

// Shared property snippets reused across tools.
const NODE_PATH_PROP = {
  type: 'string' as const,
  description: "Absolute (/root/Main/Player) or relative (Player) node path. Relative paths resolve against current_scene first, then /root.",
};
const WAIT_AFTER_PROP = {
  type: 'number' as const,
  description: "Milliseconds to await after the input is dispatched (default 33 ≈ 2 frames at 60fps). Lets the engine apply the input before the next tool call observes state.",
  default: 33,
};

export const runtimeTools: ToolDefinition[] = [
  // ─────────────────────────────────────────────────────────────────────────
  // §7.2 — Action-tier input
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'list_actions',
    description:
      "List all Action names defined in the game's InputMap.\n\n" +
      "USE WHEN: You need to know which semantic inputs the game accepts before pressing one.\n" +
      "DO NOT USE WHEN: You already know the action name — just call press_action directly.\n" +
      "COMMON FAILURE: Returns engine-internal ui_* actions hidden by default; pass include_ui=true to see them.\n" +
      "EXAMPLE: list_actions() → { actions: [{name:\"jump\", deadzone:0.2, events:1}, ...] }",
    inputSchema: {
      type: 'object',
      properties: {
        include_ui: { type: 'boolean', description: 'Include engine ui_* actions.', default: false },
      },
    },
  },
  {
    name: 'press_action',
    description:
      "Press an InputMap action and automatically release after duration_ms.\n\n" +
      "USE WHEN: The game has an InputMap entry for the desired action (e.g., 'jump', 'attack', 'pause').\n" +
      "DO NOT USE WHEN: You need raw keyboard input not mapped to any action — use press_key instead.\n" +
      "COMMON FAILURE: INVALID_ACTION when the action name doesn't exist in InputMap. Run list_actions first.\n" +
      "EXAMPLE: press_action(name='jump', duration_ms=100, wait_after_ms=50)",
    inputSchema: {
      type: 'object',
      properties: {
        name:          { type: 'string', description: 'Action name from InputMap.' },
        duration_ms:   { type: 'number', description: 'How long to hold the action down (ms).', default: 100 },
        wait_after_ms: WAIT_AFTER_PROP,
      },
      required: ['name'],
    },
  },
  {
    name: 'hold_action',
    description:
      "Press an InputMap action and KEEP it held until release_action.\n\n" +
      "USE WHEN: You need sustained input (move_right for 800ms, charging a shot).\n" +
      "DO NOT USE WHEN: A single press is enough — use press_action so release is automatic.\n" +
      "COMMON FAILURE: Forgetting release_action leaves the input stuck. release_all clears all held inputs.\n" +
      "EXAMPLE: hold_action(name='move_right'); wait; release_action(name='move_right')",
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string', description: 'Action name from InputMap.' } },
      required: ['name'],
    },
  },
  {
    name: 'release_action',
    description:
      "Release an InputMap action previously held by hold_action.\n\n" +
      "USE WHEN: Ending a sustained input started with hold_action.\n" +
      "DO NOT USE WHEN: The action was pressed by press_action — it released automatically.\n" +
      "COMMON FAILURE: Calling on an action that wasn't held returns was_held=false (not an error).\n" +
      "EXAMPLE: release_action(name='move_right')",
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string', description: 'Action name from InputMap.' } },
      required: ['name'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.3 — Node click
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'click_node',
    description:
      "Click a node by path — resolves the node's screen center at click time.\n\n" +
      "USE WHEN: Verifying UI flow (Button / Label / Control). Most reliable: no coordinate math, layout-independent.\n" +
      "DO NOT USE WHEN: Clicking world-space sprites without a Camera2D — coordinate conversion is approximate.\n" +
      "COMMON FAILURE: NODE_NOT_FOUND with `suggestions` listing nearest matches. Run get_runtime_scene_tree.\n" +
      "EXAMPLE: click_node(node_path='/root/Main/MainMenu/StartButton')",
    inputSchema: {
      type: 'object',
      properties: {
        node_path: NODE_PATH_PROP,
        button:    { type: 'string', enum: ['left', 'right', 'middle'], default: 'left' },
        double:    { type: 'boolean', default: false },
        wait_after_ms: WAIT_AFTER_PROP,
      },
      required: ['node_path'],
    },
  },
  {
    name: 'find_and_click',
    description:
      "Find a node by name or text content and click it.\n\n" +
      "USE WHEN: You don't know the exact node path but know the button text (e.g. '시작' or '확인').\n" +
      "DO NOT USE WHEN: Multiple nodes share the same text — first match wins, which may be wrong.\n" +
      "COMMON FAILURE: NODE_NOT_FOUND when nothing matches. Try get_runtime_scene_tree to discover paths.\n" +
      "EXAMPLE: find_and_click(text_or_name='Play')",
    inputSchema: {
      type: 'object',
      properties: {
        text_or_name: { type: 'string', description: 'Substring of Button.text / Label.text / node name.' },
        button:    { type: 'string', enum: ['left', 'right', 'middle'], default: 'left' },
        double:    { type: 'boolean', default: false },
        wait_after_ms: WAIT_AFTER_PROP,
      },
      required: ['text_or_name'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.4 — Raw key / mouse
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'press_key',
    description:
      "Press a raw key and automatically release after duration_ms.\n\n" +
      "USE WHEN: The key has no InputMap binding (debug keys, dev shortcuts).\n" +
      "DO NOT USE WHEN: The game has an InputMap action — prefer press_action (it survives keybind changes).\n" +
      "COMMON FAILURE: INVALID_KEY if the key string is unknown. Accepts {key:'SPACE'} or {keycode:32}.\n" +
      "EXAMPLE: press_key(key='F12', duration_ms=50, modifiers=['ctrl'])",
    inputSchema: {
      type: 'object',
      properties: {
        key:              { type: 'string', description: "Key string (e.g. 'A', 'SPACE', 'F1'). Mutually exclusive with keycode." },
        keycode:          { type: 'number', description: 'Godot Key enum value, if you have it.' },
        physical_keycode: { type: 'number', description: 'Physical key code (layout-independent).' },
        duration_ms:      { type: 'number', default: 100 },
        modifiers:        { type: 'array', items: { type: 'string', enum: ['shift', 'ctrl', 'alt', 'meta'] }, default: [] },
        wait_after_ms: WAIT_AFTER_PROP,
      },
    },
  },
  {
    name: 'hold_key',
    description:
      "Press a raw key and KEEP it held until release_key.\n\n" +
      "USE WHEN: Sustained raw input (charge / lean / debug toggle).\n" +
      "DO NOT USE WHEN: Mapped to an action — prefer hold_action.\n" +
      "COMMON FAILURE: Forgetting release_key leaves the key stuck. release_all clears all held keys.\n" +
      "EXAMPLE: hold_key(key='SHIFT'); ...; release_key(key='SHIFT')",
    inputSchema: {
      type: 'object',
      properties: {
        key: { type: 'string' }, keycode: { type: 'number' }, physical_keycode: { type: 'number' },
        modifiers: { type: 'array', items: { type: 'string' }, default: [] },
      },
    },
  },
  {
    name: 'release_key',
    description:
      "Release a raw key previously held by hold_key.\n\n" +
      "USE WHEN: Ending a hold_key.\nDO NOT USE WHEN: The key was pressed by press_key (auto-released).\n" +
      "COMMON FAILURE: Returns was_held=false if the key wasn't tracked (not an error).\n" +
      "EXAMPLE: release_key(key='SHIFT')",
    inputSchema: {
      type: 'object',
      properties: { key: { type: 'string' }, keycode: { type: 'number' }, physical_keycode: { type: 'number' } },
    },
  },
  {
    name: 'click_at',
    description:
      "Click at a viewport coordinate (default) or window/global coordinate.\n\n" +
      "USE WHEN: Coordinates are known and click_node / find_and_click can't reach the target.\n" +
      "DO NOT USE WHEN: A UI node exists at that location — click_node is layout-independent.\n" +
      "COMMON FAILURE: stretch_mode=2D/viewport offsets can confuse window-space coords. Default to space='viewport'.\n" +
      "EXAMPLE: click_at(x=200, y=300, button='left', space='viewport')",
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number' }, y: { type: 'number' },
        button: { type: 'string', enum: ['left', 'right', 'middle', 'wheel_up', 'wheel_down'], default: 'left' },
        double: { type: 'boolean', default: false },
        space:  { type: 'string', enum: ['viewport', 'window', 'global'], default: 'viewport' },
        wait_after_ms: WAIT_AFTER_PROP,
      },
      required: ['x', 'y'],
    },
  },
  {
    name: 'mouse_move',
    description:
      "Move mouse cursor without clicking. Useful for hover-only UI / aiming.\n\n" +
      "USE WHEN: Triggering hover effects, aiming a shoot direction.\n" +
      "DO NOT USE WHEN: You want to click too — click_at already sets position.\n" +
      "COMMON FAILURE: Cursor moves but tooltip doesn't appear if the game uses _input instead of _gui_input.\n" +
      "EXAMPLE: mouse_move(x=400, y=300)",
    inputSchema: {
      type: 'object',
      properties: {
        x: { type: 'number' }, y: { type: 'number' },
        space: { type: 'string', enum: ['viewport', 'window', 'global'], default: 'viewport' },
      },
      required: ['x', 'y'],
    },
  },
  {
    name: 'drag',
    description:
      "Drag from one coordinate to another with smooth interpolated motion.\n\n" +
      "USE WHEN: Slider widgets, drag-drop, gesture testing.\n" +
      "DO NOT USE WHEN: A keyboard/action equivalent exists — drag is the most flaky input.\n" +
      "COMMON FAILURE: Too few steps (default 8) makes the drag look like a teleport. Increase steps for gesture games.\n" +
      "EXAMPLE: drag(from_x=100, from_y=200, to_x=300, to_y=200, duration_ms=400, steps=16)",
    inputSchema: {
      type: 'object',
      properties: {
        from_x: { type: 'number' }, from_y: { type: 'number' },
        to_x:   { type: 'number' }, to_y:   { type: 'number' },
        duration_ms: { type: 'number', default: 200 },
        steps:       { type: 'number', default: 8 },
        button: { type: 'string', enum: ['left', 'right', 'middle'], default: 'left' },
        space:  { type: 'string', enum: ['viewport', 'window', 'global'], default: 'viewport' },
      },
      required: ['from_x', 'from_y', 'to_x', 'to_y'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.5 — Sequence
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'run_input_sequence',
    description:
      "Execute a list of input steps in one round trip. Saves agent context and gives precise inter-step timing.\n\n" +
      "USE WHEN: A test scenario needs >2 consecutive inputs — combo, dialog flow, level traversal.\n" +
      "DO NOT USE WHEN: A single input plus assertion suffices — overkill.\n" +
      "COMMON FAILURE: Step ops typo (use 'press_action' not 'pressAction'). Sequence stops on first failure by default.\n" +
      "EXAMPLE: run_input_sequence(steps=[{action:'hold_action',name:'move_right'},{action:'wait',ms:800},{action:'release_action',name:'move_right'},{action:'screenshot'}])",
    inputSchema: {
      type: 'object',
      properties: {
        steps: {
          type: 'array',
          description: 'Ordered list of step dicts. Each must have {action: "<op>"} where <op> is one of press_action, hold_action, release_action, press_key, hold_key, release_key, click_at, click_node, mouse_move, drag, wait, screenshot.',
          items: { type: 'object' },
        },
        stop_on_error: { type: 'boolean', default: true },
      },
      required: ['steps'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.6 — Safety
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'release_all',
    description:
      "Force-release every key and action currently held by hold_key / hold_action.\n\n" +
      "USE WHEN: End of a test scenario, recovering from a stuck input, before stop_scene.\n" +
      "DO NOT USE WHEN: Mid-sequence if a hold is intentional.\n" +
      "COMMON FAILURE: None — idempotent. Returns the count of inputs released.\n" +
      "EXAMPLE: release_all() → { released: 3 }",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'get_input_state',
    description:
      "List currently-held keys and actions. Pure read.\n\n" +
      "USE WHEN: Debugging why a held input doesn't seem to register, or checking before release_all.\n" +
      "DO NOT USE WHEN: As a substitute for explicit release tracking — server already tracks state.\n" +
      "COMMON FAILURE: None.\n" +
      "EXAMPLE: get_input_state() → { pressed_keys:[32], pressed_actions:['move_right'] }",
    inputSchema: { type: 'object', properties: {} },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.7 — Inspection
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'capture_screenshot',
    description:
      "Capture the running game's viewport as PNG. Alias of take_screenshot.\n\n" +
      "USE WHEN: Verifying visual state after input, before/after a change, or for debugging.\n" +
      "DO NOT USE WHEN: In headless mode without rendering — returns RENDERING_REQUIRED.\n" +
      "COMMON FAILURE: No viewport (game not running) — call run_scene first.\n" +
      "EXAMPLE: capture_screenshot(return_base64=true) → { absolute_path, width, height, base64_png }",
    inputSchema: {
      type: 'object',
      properties: {
        save_to:       { type: 'string', description: "res:// or user:// path. Defaults to res://addons/godot_mcp/cache/screenshots/screenshot_<ts>.png." },
        return_base64: { type: 'boolean', description: 'Embed base64 PNG in the response.', default: false },
      },
    },
  },
  {
    name: 'get_runtime_scene_tree',
    description:
      "Walk the running scene tree and return a JSON tree of node names / classes / paths.\n\n" +
      "USE WHEN: Discovering node paths before calling click_node / get_node_property.\n" +
      "DO NOT USE WHEN: You already know the node path — get_node_property is cheaper.\n" +
      "COMMON FAILURE: max_depth too small truncates important children — bump it for nested UI scenes.\n" +
      "EXAMPLE: get_runtime_scene_tree(root='/root', max_depth=6)",
    inputSchema: {
      type: 'object',
      properties: {
        root:      { type: 'string', default: '/root' },
        max_depth: { type: 'number', default: 10 },
      },
    },
  },
  {
    name: 'get_node_property',
    description:
      "Read a single property from a live node.\n\n" +
      "USE WHEN: Verifying state after an input (player.position, hp_bar.value).\n" +
      "DO NOT USE WHEN: You need many properties at once — use query_runtime_node with properties=[].\n" +
      "COMMON FAILURE: PROPERTY_NOT_FOUND lists nearby property names as suggestions.\n" +
      "EXAMPLE: get_node_property(node_path='/root/Main/Player', property='position')",
    inputSchema: {
      type: 'object',
      properties: { node_path: NODE_PATH_PROP, property: { type: 'string' } },
      required: ['node_path', 'property'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.8 — Assertion
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'assert_property',
    description:
      "Assert a node property compares equal / not-equal / </<=/>/>=/in/not_in against expected.\n\n" +
      "USE WHEN: Verifying game-state changed as expected after input. Failed asserts auto-attach a screenshot.\n" +
      "DO NOT USE WHEN: You want the raw value back — get_node_property already returns it.\n" +
      "COMMON FAILURE: gt/gte/lt/lte coerce strings to floats — works for numeric props only.\n" +
      "EXAMPLE: assert_property(node_path='/root/Main/Player', property='hp', op='gte', expected=50)",
    inputSchema: {
      type: 'object',
      properties: {
        node_path: NODE_PATH_PROP,
        property:  { type: 'string' },
        expected:  { description: 'Any JSON-serializable value (scalar, array for in/not_in, or {type:"Vector2",x,y}).' },
        op:        { type: 'string', enum: ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'not_in'], default: 'eq' },
      },
      required: ['node_path', 'property', 'expected'],
    },
  },
  {
    name: 'assert_node_exists',
    description:
      "Assert that a node exists at node_path.\n\n" +
      "USE WHEN: Verifying a spawn / dialog open / UI transition. Failed asserts auto-attach screenshot.\n" +
      "DO NOT USE WHEN: You just want to read the tree — get_runtime_scene_tree.\n" +
      "COMMON FAILURE: Engine-internal nodes (CanvasLayer, GUI auto-attached) may surface unexpectedly.\n" +
      "EXAMPLE: assert_node_exists(node_path='/root/Main/UI/GameOverDialog')",
    inputSchema: {
      type: 'object',
      properties: { node_path: NODE_PATH_PROP },
      required: ['node_path'],
    },
  },
  {
    name: 'assert_node_visible',
    description:
      "Assert that a node is visible — Control nodes also check viewport intersection.\n\n" +
      "USE WHEN: Verifying a UI panel opened or a sprite spawned in view.\n" +
      "DO NOT USE WHEN: visible=true is enough — use assert_property(property='visible', expected=true).\n" +
      "COMMON FAILURE: Off-screen Control nodes still report visible=true unless this helper is used.\n" +
      "EXAMPLE: assert_node_visible(node_path='/root/Main/UI/StatusBar')",
    inputSchema: {
      type: 'object',
      properties: { node_path: NODE_PATH_PROP },
      required: ['node_path'],
    },
  },
  {
    name: 'assert_no_errors_in_log',
    description:
      "Assert no ERROR/WARNING entries were captured since since_ms.\n\n" +
      "USE WHEN: Smoke test gate — confirms no exceptions / push_error from gameplay.\n" +
      "DO NOT USE WHEN: You expect a specific warning (use get_debug_log + filter).\n" +
      "COMMON FAILURE: Engine doesn't auto-capture push_error globally; user scripts opt in via MCPRuntime.push_engine_log.\n" +
      "EXAMPLE: clear_debug_log(); ... gameplay ... ; assert_no_errors_in_log(since_ms=0)",
    inputSchema: {
      type: 'object',
      properties: { since_ms: { type: 'number', default: 0 } },
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.9 — Log
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'get_debug_log',
    description:
      "Get recent error/warning log entries from the runtime ring buffer.\n\n" +
      "USE WHEN: Investigating a failed assertion or unexpected state.\n" +
      "DO NOT USE WHEN: You want print() output — use get_print_log.\n" +
      "COMMON FAILURE: Entries are only populated by MCPRuntime.push_engine_log; bare push_error/push_warning aren't intercepted automatically.\n" +
      "EXAMPLE: get_debug_log(level='error', limit=20)",
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', default: 50 },
        level: { type: 'string', enum: ['error', 'warning', 'all'], default: 'error' },
      },
    },
  },
  {
    name: 'clear_debug_log',
    description:
      "Clear all ring buffers (debug, runtime, print). Returns the cleared count.\n\n" +
      "USE WHEN: Beginning a test so subsequent assert_no_errors_in_log only sees fresh entries.\n" +
      "DO NOT USE WHEN: You still need the older log content.\n" +
      "COMMON FAILURE: None — idempotent.\n" +
      "EXAMPLE: clear_debug_log() → { cleared: 27 }",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'get_print_log',
    description:
      "Get recent print() output captured via MCPRuntime.push_print().\n\n" +
      "USE WHEN: Game scripts opted into surfacing prints with MCPRuntime.push_print(text).\n" +
      "DO NOT USE WHEN: Game scripts haven't opted in — ring will be empty. Use editor-side get_console_log instead.\n" +
      "COMMON FAILURE: Empty ring → user game didn't wire MCPRuntime.push_print. (Engine has no global print hook.)\n" +
      "EXAMPLE: get_print_log(limit=20) → { entries:[{ts_ms, text}], hint:... }",
    inputSchema: {
      type: 'object',
      properties: { limit: { type: 'number', default: 100 } },
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // §7.10 — State mutation
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'set_node_property',
    description:
      "Directly set a node property — bypasses input. ONLY USE WHEN INPUT CANNOT REACH THE STATE.\n\n" +
      "USE WHEN: Teleporting, force-setting hp for a death test, jumping past a cutscene.\n" +
      "DO NOT USE WHEN: A press_action / press_key flow would set the same property — that catches more bugs.\n" +
      "COMMON FAILURE: PROPERTY_NOT_FOUND for typos. Vector2/3/Color need {type:'Vector2',x,y} wire form.\n" +
      "EXAMPLE: set_node_property(node_path='/root/Main/Player', property='position', value={type:'Vector2', x:512, y:240})",
    inputSchema: {
      type: 'object',
      properties: {
        node_path: NODE_PATH_PROP,
        property:  { type: 'string' },
        value:     { description: 'JSON-serializable. Vector2/3/Color/Rect2 wrap with {type:..., x:..., y:..., z?, r?, g?, b?, a?, w?, h?}.' },
      },
      required: ['node_path', 'property', 'value'],
    },
  },
  {
    name: 'call_node_method',
    description:
      "Invoke a method on a live node — bypasses input. Powerful, dangerous.\n\n" +
      "USE WHEN: Triggering an internal state transition (player.take_damage, game.save_game) directly.\n" +
      "DO NOT USE WHEN: A user-facing button would call the same method — clicking it catches more bugs.\n" +
      "COMMON FAILURE: METHOD_NOT_FOUND for typos. Arg types must match the method signature; coerce Vector2/3/Color via {type,...}.\n" +
      "EXAMPLE: call_node_method(node_path='/root/Main/Player', method='take_damage', args=[10])",
    inputSchema: {
      type: 'object',
      properties: {
        node_path: NODE_PATH_PROP,
        method:    { type: 'string' },
        args:      { type: 'array', description: 'Positional arguments (JSON-serialised).', default: [] },
      },
      required: ['node_path', 'method'],
    },
  },
  {
    name: 'add_node_runtime',
    description:
      "Create and add a new Node at runtime. Use sparingly — for spawn / test fixtures.\n\n" +
      "USE WHEN: Spawning a test enemy / pickup / canvas overlay that the gameplay code can't.\n" +
      "DO NOT USE WHEN: A game spawner exists — call it via call_node_method to exercise real code.\n" +
      "COMMON FAILURE: INVALID_TYPE for non-Node classes (e.g. 'Resource'). Property setters fall through silently if the property doesn't exist.\n" +
      "EXAMPLE: add_node_runtime(parent_path='/root/Main', type='Node2D', properties={name:'TestMarker', position:{type:'Vector2', x:100, y:100}})",
    inputSchema: {
      type: 'object',
      properties: {
        parent_path: NODE_PATH_PROP,
        type:        { type: 'string', description: 'Godot ClassDB class name (Node, Node2D, Control, Label, Sprite2D, ...).' },
        properties:  { type: 'object', description: 'Properties to set after instantiation. `name` is special-cased.', default: {} },
      },
      required: ['parent_path', 'type'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // Phase 2 — Property bag snapshots (godot_ai_test_planning.md §10.1)
  //
  // A snapshot is a named JSON record of (node_path → {property → value}) for
  // a caller-defined slice of the live scene. Use snapshots to diff state
  // before/after an input sequence ("did anything change that I didn't
  // expect?") or to restore a known-good state at the start of every test.
  //
  // Storage: res://addons/godot_mcp/cache/snapshots/<name>.json — durable
  // across game restarts. In-memory cache is a thin layer above that.
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'snapshot_capture',
    description:
      "Capture a named snapshot of selected nodes' selected properties.\n\n" +
      "USE WHEN: You want a reusable 'known state' to diff against later — e.g. before opening a menu, after a save-load round-trip.\n" +
      "DO NOT USE WHEN: You only need one value — get_node_property is lighter.\n" +
      "COMMON FAILURE: name with slashes or unicode → rejected. Use [A-Za-z0-9_.-]+.\n" +
      "EXAMPLE: snapshot_capture(name='before_menu', node_paths=['/root/Main/Player','/root/Main/UI'], properties=['position','visible','modulate'])",
    inputSchema: {
      type: 'object',
      properties: {
        name:             { type: 'string', description: 'Identifier for this snapshot. Allowed: [A-Za-z0-9_.-]+. Overwrites if present.' },
        node_paths:       { type: 'array', items: { type: 'string' }, description: 'Nodes to capture. At least one required.' },
        properties:       { type: 'array', items: { type: 'string' }, description: "Properties to capture per node. Default ['position','global_position','rotation','scale','visible','modulate']." },
        include_children: { type: 'boolean', default: false, description: 'Recursively capture descendants of each node.' },
      },
      required: ['name', 'node_paths'],
    },
  },
  {
    name: 'snapshot_restore',
    description:
      "Restore a previously-captured snapshot by writing each recorded property back to its node.\n\n" +
      "USE WHEN: Resetting state at the start of a new test scenario, undoing a destructive call_node_method.\n" +
      "DO NOT USE WHEN: The snapshot is stale (entities renamed or deleted) — partial restore returns missing_nodes.\n" +
      "COMMON FAILURE: SNAPSHOT_NOT_FOUND with suggestions=available names. Run snapshot_list first.\n" +
      "EXAMPLE: snapshot_restore(name='before_menu') → { restored_assignments: 12, missing_nodes: [] }",
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string' } },
      required: ['name'],
    },
  },
  {
    name: 'snapshot_diff',
    description:
      "Diff two snapshots by name and return changed / added / removed properties.\n\n" +
      "USE WHEN: Asserting that an action only changed what you expected (turn-based: compare snapshot_before to snapshot_after).\n" +
      "DO NOT USE WHEN: Visual regression is the goal — use compare_with_baseline.\n" +
      "COMMON FAILURE: identical=true when expecting changes → check that node_paths overlap between the two snapshots.\n" +
      "EXAMPLE: snapshot_diff(name_a='before_menu', name_b='after_menu') → { change_count: 3, changes: [...], identical: false }",
    inputSchema: {
      type: 'object',
      properties: { name_a: { type: 'string' }, name_b: { type: 'string' } },
      required: ['name_a', 'name_b'],
    },
  },
  {
    name: 'snapshot_list',
    description:
      "List all stored snapshot names.\n\n" +
      "USE WHEN: Discovering snapshots after a fresh session restart.\n" +
      "DO NOT USE WHEN: You only just captured a snapshot — its name is what you passed.\n" +
      "COMMON FAILURE: None.\n" +
      "EXAMPLE: snapshot_list() → { snapshots: ['before_menu', 'after_menu'], count: 2 }",
    inputSchema: { type: 'object', properties: {} },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // Phase 2 — Visual regression baselines (§10.2)
  //
  // capture_baseline / compare_with_baseline / update_baseline / update_mask
  // / list_baselines / delete_baseline / compare_screenshots_adhoc.
  //
  // Storage: res://addons/godot_mcp/cache/baseline/<name>.{png,mask.png,meta.json}
  //
  // Algorithms ('algorithm' arg):
  //   - 'ssim'           — block-based 8×8 SSIM on luminance.
  //                        Returns ≥0..1; higher = closer. Default threshold 0.98.
  //   - 'mae'            — mean absolute pixel error.
  //                        Returns ≥0..1; LOWER = closer. Default threshold 0.02.
  //   - 'pixel_diff_pct' — fraction of pixels where any channel diff > 8/255.
  //                        Returns ≥0..1; LOWER = closer. Default threshold 0.01.
  //
  // Mask convention: a PNG sibling at <name>.mask.png. Pixels that are FULLY
  // BLACK (r<0.05 && g<0.05 && b<0.05) OR transparent are excluded from
  // comparison. White / colored pixels are compared. Use update_mask(region=…)
  // to paint a rect as masked.
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'capture_baseline',
    description:
      "Snapshot the current viewport as a named baseline image (.png + .meta.json).\n\n" +
      "USE WHEN: First time recording a scene's expected appearance. Subsequent runs use compare_with_baseline against this.\n" +
      "DO NOT USE WHEN: You want to OVERWRITE an existing baseline intentionally — use update_baseline so the intent is recorded.\n" +
      "COMMON FAILURE: RENDERING_REQUIRED if no viewport (game not running). Run run_scene with wait_for_runtime first.\n" +
      "EXAMPLE: capture_baseline(name='main_menu', algorithm='ssim', threshold=0.98)",
    inputSchema: {
      type: 'object',
      properties: {
        name:      { type: 'string', description: 'Identifier. Allowed: [A-Za-z0-9_.-]+.' },
        algorithm: { type: 'string', enum: ['ssim', 'mae', 'pixel_diff_pct'], default: 'ssim' },
        threshold: { type: 'number', description: 'Pass/fail boundary. Direction depends on algorithm — SSIM is "≥ threshold", MAE/pixel_diff_pct are "≤ threshold".' },
      },
      required: ['name'],
    },
  },
  {
    name: 'compare_with_baseline',
    description:
      "Take a fresh viewport screenshot and compare it to a stored baseline using SSIM / MAE / pixel_diff_pct.\n\n" +
      "USE WHEN: Smoke test gating after a scene/UI change to confirm rendering is still bit-similar.\n" +
      "DO NOT USE WHEN: You're still authoring the scene — false positives every save. Save baseline AFTER you're happy.\n" +
      "COMMON FAILURE: SIZE_MISMATCH if viewport changed dimensions — re-capture or resize. Excessive false positives mean you need update_mask to ignore noisy regions.\n" +
      "EXAMPLE: compare_with_baseline(name='main_menu')",
    inputSchema: {
      type: 'object',
      properties: {
        name:      { type: 'string' },
        algorithm: { type: 'string', enum: ['ssim', 'mae', 'pixel_diff_pct'], description: 'Defaults to whatever capture_baseline saved.' },
        threshold: { type: 'number', description: 'Override the saved threshold. Direction depends on algorithm.' },
      },
      required: ['name'],
    },
  },
  {
    name: 'update_baseline',
    description:
      "Overwrite an existing baseline with the current viewport.\n\n" +
      "USE WHEN: Intentional visual change to a scene — you reviewed the diff and accept it as the new ground truth.\n" +
      "DO NOT USE WHEN: An unexpected regression — investigate the cause first; update_baseline silently makes the bug invisible.\n" +
      "COMMON FAILURE: Same as capture_baseline.\n" +
      "EXAMPLE: update_baseline(name='main_menu') after a deliberate theme change.",
    inputSchema: {
      type: 'object',
      properties: {
        name:      { type: 'string' },
        algorithm: { type: 'string', enum: ['ssim', 'mae', 'pixel_diff_pct'], default: 'ssim' },
        threshold: { type: 'number' },
      },
      required: ['name'],
    },
  },
  {
    name: 'update_mask',
    description:
      "Paint a rectangular region of the baseline's mask as EXCLUDED (or clear the mask).\n\n" +
      "USE WHEN: A noisy region (animated clock, particle FX, dynamic timestamp) keeps tripping compare_with_baseline.\n" +
      "DO NOT USE WHEN: The whole image fails — fix the regression instead of hiding it.\n" +
      "COMMON FAILURE: BASELINE_NOT_FOUND. Capture the baseline first.\n" +
      "EXAMPLE: update_mask(name='main_menu', region={x:0, y:0, w:120, h:32})  → masks the top-left HUD clock",
    inputSchema: {
      type: 'object',
      properties: {
        name:   { type: 'string' },
        region: { type: 'object', description: 'Rectangle to mask out as { x, y, w, h } in pixels. Omit when clear=true.',
          properties: { x: { type: 'number' }, y: { type: 'number' }, w: { type: 'number' }, h: { type: 'number' } } },
        clear:  { type: 'boolean', default: false, description: 'Reset the mask to fully-included (all-white) before applying region.' },
      },
      required: ['name'],
    },
  },
  {
    name: 'list_baselines',
    description:
      "List all stored baseline names along with their algorithm / threshold / last comparison result.\n\n" +
      "USE WHEN: Auditing visual regression coverage, deciding which baselines need refresh.\n" +
      "DO NOT USE WHEN: You only need one baseline's details — read its meta.json directly via Read tool.\n" +
      "COMMON FAILURE: None.\n" +
      "EXAMPLE: list_baselines() → { baselines: [{name, algorithm, threshold, last_score, last_pass}, ...] }",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'delete_baseline',
    description:
      "Remove a baseline and its mask + meta.\n\n" +
      "USE WHEN: A scene was renamed or deleted — clean up stale baselines.\n" +
      "DO NOT USE WHEN: You want to RESET the baseline — use update_baseline.\n" +
      "COMMON FAILURE: BASELINE_NOT_FOUND if already removed.\n" +
      "EXAMPLE: delete_baseline(name='main_menu')",
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string' } },
      required: ['name'],
    },
  },
  {
    name: 'compare_screenshots_adhoc',
    description:
      "Compare two base64-encoded PNGs without touching any baseline storage.\n\n" +
      "USE WHEN: One-shot comparison (before-vs-after) where persisting a baseline isn't worth it.\n" +
      "DO NOT USE WHEN: You'll want to re-run this check — use capture_baseline / compare_with_baseline so the baseline is named and discoverable.\n" +
      "COMMON FAILURE: SIZE_MISMATCH if the two screenshots aren't the same dimensions.\n" +
      "EXAMPLE: compare_screenshots_adhoc(a_b64=…, b_b64=…, algorithm='ssim', threshold=0.95)",
    inputSchema: {
      type: 'object',
      properties: {
        a_b64:     { type: 'string', description: 'Base64-encoded PNG.' },
        b_b64:     { type: 'string', description: 'Base64-encoded PNG.' },
        algorithm: { type: 'string', enum: ['ssim', 'mae', 'pixel_diff_pct'], default: 'ssim' },
        threshold: { type: 'number' },
      },
      required: ['a_b64', 'b_b64'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // Phase 1.5 — Deterministic mode (godot_ai_test_planning.md §9)
  //
  // Tier 0 (Off):     default — no engine state changes.
  // Tier 1 (Soft):    seed lock + Engine.max_fps & physics_ticks pinned to
  //                   `fps` + real OS mouse/keyboard ignored. ~60% repeat.
  // Tier 2 (Stepped): Tier 1 + Engine.time_scale=0; advance only via
  //                   step_frames. ~95% repeat — the sweet spot for visual
  //                   regression and SSIM-stable baselines.
  // Tier 3 (Hooked):  Plan §9.4 future work — out of scope here.
  //
  // Known side effects under Tier 2 (recipe authors MUST account for):
  //   * AnimationPlayer / Tween / Timer(process_callback) all freeze.
  //   * Audio engine has its own thread → unaffected.
  //   * Time.get_ticks_msec() stays real-time.
  //   * physics_ticks_per_second ≠ max_fps → use step_frames(type="both").
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'enable_deterministic_mode',
    description:
      "Lock the engine into a repeatable state for stable visual regression and snapshot diffs.\n\n" +
      "USE WHEN: About to run capture_baseline or a multi-step input scenario that you want to replay bit-identically.\n" +
      "DO NOT USE WHEN: Running gameplay-feel tests — Tier 2 freezes Animation/Tween/Timer; behavior drifts from real-time play.\n" +
      "COMMON FAILURE: A scene that polls Time.get_ticks_msec() for gameplay logic will misbehave at Tier 2 (the clock stays real-time, time_scale doesn't).\n" +
      "EXAMPLE: enable_deterministic_mode(tier=2, seed=1234, fps=60) → step_frames(n=2) → capture_screenshot",
    inputSchema: {
      type: 'object',
      properties: {
        tier: { type: 'number', default: 2, description: '0=Off, 1=Soft (seed+fps+ignore real input), 2=Stepped (time_scale=0). Clamped to [0..2] server-side.' },
        seed: { type: 'number', default: 1234, description: 'Global RNG seed.' },
        fps:  { type: 'number', default: 60, description: 'Pin Engine.max_fps and physics_ticks_per_second to this value.' },
      },
    },
  },
  {
    name: 'disable_deterministic_mode',
    description:
      "Restore the engine to free-running mode (time_scale, max_fps, physics_ticks). Real OS input flows again.\n\n" +
      "USE WHEN: Done with regression checks; want the game to behave like normal play.\n" +
      "DO NOT USE WHEN: You only want to lower the tier — call enable_deterministic_mode again with the lower tier instead (it tears down cleanly).\n" +
      "COMMON FAILURE: None — idempotent.\n" +
      "EXAMPLE: disable_deterministic_mode()",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'get_deterministic_state',
    description:
      "Read the current tier / seed / frame counter / fps / time_scale.\n\n" +
      "USE WHEN: Debugging why step_frames returns MODE_CONFLICT (you forgot to enable Tier 2).\n" +
      "DO NOT USE WHEN: You just called enable_deterministic_mode — the return value of that call has the same info.\n" +
      "COMMON FAILURE: None.\n" +
      "EXAMPLE: get_deterministic_state() → { tier: 2, seed: 1234, frame_counter: 12, ... }",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'step_frames',
    description:
      "Advance N frames manually. Requires Tier 2 (Engine.time_scale=0). Lifts time_scale to 1 for exactly N frames, then re-zeroes it.\n\n" +
      "USE WHEN: Between an input and an assertion under Tier 2 — without this, the input never gets a chance to apply.\n" +
      "DO NOT USE WHEN: Not in Tier 2 — returns MODE_CONFLICT. Use wait_after_ms in input tools instead under Tier 0/1.\n" +
      "COMMON FAILURE: type='process' alone skips physics updates (collision / RigidBody). For most games use 'both'.\n" +
      "EXAMPLE: enable_deterministic_mode(tier=2); press_action(name='jump'); step_frames(n=4, type='both'); capture_screenshot()",
    inputSchema: {
      type: 'object',
      properties: {
        n:    { type: 'number', default: 1, description: 'Number of frames to advance.' },
        type: { type: 'string', enum: ['process', 'physics', 'both'], default: 'both' },
      },
    },
  },
  {
    name: 'set_test_seed',
    description:
      "Re-seed the global RNG without changing tier or other state.\n\n" +
      "USE WHEN: Between scenarios that should both be repeatable but with different random outcomes.\n" +
      "DO NOT USE WHEN: Initial seed is fine — enable_deterministic_mode already seeds.\n" +
      "COMMON FAILURE: User code calls seed() too, overriding this.\n" +
      "EXAMPLE: set_test_seed(seed=42)",
    inputSchema: {
      type: 'object',
      properties: { seed: { type: 'number', default: 0 } },
      required: ['seed'],
    },
  },
  {
    name: 'wait_until',
    description:
      "Block until a node property satisfies a comparison, or up to timeout_frames.\n\n" +
      "USE WHEN: Async game logic — fade-in finishes, dialog opens, async load completes.\n" +
      "DO NOT USE WHEN: You can predict the exact frame count — step_frames is cheaper and deterministic.\n" +
      "COMMON FAILURE: TIMEOUT after timeout_frames. Either the predicate is wrong or timeout is too short. Under Tier 2 each frame is one step_frame; under Tier 0/1 each frame is real-time so timeout is approximate.\n" +
      "EXAMPLE: wait_until(node_path='/root/Main/UI/Dialog', property='visible', expected=true, timeout_frames=120)",
    inputSchema: {
      type: 'object',
      properties: {
        node_path:      NODE_PATH_PROP,
        property:       { type: 'string' },
        expected:       { description: 'Any JSON-serializable value.' },
        op:             { type: 'string', enum: ['eq', 'neq', 'gt', 'gte', 'lt', 'lte', 'in', 'not_in'], default: 'eq' },
        timeout_frames: { type: 'number', default: 300 },
        poll:           { type: 'string', enum: ['process', 'physics', 'both'], default: 'process', description: 'Which frame to await per poll iteration (Tier 2 only).' },
      },
      required: ['node_path', 'property', 'expected'],
    },
  },

  // ─────────────────────────────────────────────────────────────────────────
  // Phase 2.5 — PackedScene full snapshot + AI vision diff (§10.5)
  // ─────────────────────────────────────────────────────────────────────────
  {
    name: 'snapshot_scene_full',
    description:
      "Pack the entire current_scene into a .tscn under the cache dir. Reusable as a save-state.\n\n" +
      "USE WHEN: Capturing a complex state that property-bag snapshots can't reproduce (newly-instantiated nodes, dynamic children).\n" +
      "DO NOT USE WHEN: A property-bag snapshot is enough — full scene packs are large and slower to restore.\n" +
      "COMMON FAILURE: PackedScene.pack rejects nodes whose owner is null. The autoload reparents on a duplicate before packing, but custom resources without ResourceFormat support may still fail.\n" +
      "EXAMPLE: snapshot_scene_full(name='before_combat')",
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string', description: 'Identifier. [A-Za-z0-9_.-]+.' } },
      required: ['name'],
    },
  },
  {
    name: 'snapshot_scene_load',
    description:
      "Swap the current scene to a previously-packed .tscn via change_scene_to_file.\n\n" +
      "USE WHEN: Returning to a known full state at the start of a new test scenario.\n" +
      "DO NOT USE WHEN: You only need to reset a few properties — snapshot_restore is faster and doesn't tear down the scene.\n" +
      "COMMON FAILURE: SCENE_SNAPSHOT_NOT_FOUND. Scene swap is deferred to the next idle frame — poll get_runtime_scene_tree to wait.\n" +
      "EXAMPLE: snapshot_scene_load(name='before_combat')",
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string' } },
      required: ['name'],
    },
  },
  {
    name: 'snapshot_scene_list',
    description:
      "List all packed scene snapshot names.\n\n" +
      "USE WHEN: Surveying available save-states.\n" +
      "DO NOT USE WHEN: You only just packed one — its name is what you passed.\n" +
      "COMMON FAILURE: None.\n" +
      "EXAMPLE: snapshot_scene_list() → { scenes: ['before_combat', 'main_menu_loaded'], count: 2 }",
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'snapshot_scene_delete',
    description:
      "Delete a packed scene snapshot.\n\n" +
      "USE WHEN: Cleaning up stale snapshots after a scene rewrite.\n" +
      "DO NOT USE WHEN: You want to REPLACE — just call snapshot_scene_full with the same name (overwrites).\n" +
      "COMMON FAILURE: SCENE_SNAPSHOT_NOT_FOUND if already removed.\n" +
      "EXAMPLE: snapshot_scene_delete(name='old_scene')",
    inputSchema: {
      type: 'object',
      properties: { name: { type: 'string' } },
      required: ['name'],
    },
  },
  {
    name: 'compare_with_ai',
    description:
      "Compare two base64 PNGs with Claude (or a configured Anthropic-API-compatible model) using a natural-language instruction. Returns the model's verdict plus a pass/fail extracted from a [[VERDICT: pass|fail]] tag the prompt asks for.\n\n" +
      "USE WHEN: SSIM is too brittle (you want \"player visible? yes/no\" not pixel-identical) or you want a human-readable explanation of a difference.\n" +
      "DO NOT USE WHEN: SSIM / MAE / pixel_diff_pct would do — those are free, fast, deterministic. AI calls cost tokens and have latency.\n" +
      "COMMON FAILURE: MISSING_API_KEY when ANTHROPIC_API_KEY isn't in the game process env — set it before launching the editor. Network/timeout returns error string from HTTPRequest.\n" +
      "EXAMPLE: compare_with_ai(a_b64=…, b_b64=…, instruction='Image A should show a victory banner. Image B should show the same banner with the same text. Position differences are OK.')",
    inputSchema: {
      type: 'object',
      properties: {
        a_b64:       { type: 'string', description: 'Base64-encoded PNG.' },
        b_b64:       { type: 'string', description: 'Base64-encoded PNG.' },
        instruction: { type: 'string', description: 'What the model should verify. Be explicit about what counts as a regression.' },
        model:       { type: 'string', description: "Anthropic model id. Default 'claude-sonnet-4-6'." },
        max_tokens:  { type: 'number', default: 1024 },
      },
      required: ['a_b64', 'b_b64', 'instruction'],
    },
  },
];

/**
 * Tool names that MUST be routed to the runtime (game) WebSocket slot — the
 * editor plugin cannot satisfy these. Used by godot-bridge.routeIsRuntime.
 */
export const RUNTIME_TOOL_NAMES: readonly string[] = runtimeTools.map((t) => t.name);
