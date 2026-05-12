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
];

/**
 * Tool names that MUST be routed to the runtime (game) WebSocket slot — the
 * editor plugin cannot satisfy these. Used by godot-bridge.routeIsRuntime.
 */
export const RUNTIME_TOOL_NAMES: readonly string[] = runtimeTools.map((t) => t.name);
