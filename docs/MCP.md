# MacHUD MCP tool server

`machud-mcp` serves MacHUD to an agent as a [Model Context Protocol](https://modelcontextprotocol.io)
tool server over stdio. It ships inside MacHUD as `Contents/Helpers/machud-mcp` (built by
`./build.sh`, `HUD_HELPERS`); in a `swift build` it is `.build/<config>/machud-mcp`. The voice host
hands it to its brain; any MCP client can run it:

```sh
claude mcp add machud -- /Applications/MacHUD.app/Contents/Helpers/machud-mcp
```

It talks to MacHUD only through the control socket ([API.md](API.md)): `MACHUD_SOCKET` when set,
else MacHUD's contract socket (`~/Library/Application Support/MacHUD/sockets/machud.sock`). stdout
carries protocol messages only; one diagnostic line goes to stderr. It exits when stdin closes.

Source: `Sources/MacHUDMCPCore` (`MCPServer` the protocol, `MacHUDTools` the tools, `AppWatcher`
the tool list's updates, `SocketTransport` the socket), `Sources/MacHUDMCP/main.swift` (the stdio
loop). Tests: `Tests/MacHUDMCPTests`, against a fake MacHUD socket, including the built binary over
real stdin/stdout.

## Protocol

Newline-delimited JSON-RPC 2.0, one message per line. Both protocol eras are served:

- **Legacy** (`2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`): `initialize` answers with the
  version the client asked for when it is one of those, else `2025-11-25`, plus `capabilities
  {tools: {listChanged: true}}`, `serverInfo {name: "machud", title: "MacHUD", version}` (the
  enclosing MacHUD's version, `dev` outside a bundle) and `instructions` (a paragraph on what
  MacHUD is and to call `machud_status` first). After `initialize`, the server sends
  `notifications/tools/list_changed` whenever the tool list differs from the one last listed.
- **Modern** (`2026-07-28`): no handshake. A request naming a version in
  `_meta["io.modelcontextprotocol/protocolVersion"]` gets `resultType: "complete"` in its result;
  an unsupported version gets error `-32022` with `data {supported, requested}`.
  `server/discover` returns `supportedVersions`, `capabilities`, the server info under
  `_meta["io.modelcontextprotocol/serverInfo"]` and `instructions`. `subscriptions/listen` with
  `notifications.toolsListChanged: true` stays open and carries `list_changed` notifications
  tagged `_meta["io.modelcontextprotocol/subscriptionId"]` (the listen request's id);
  `notifications/cancelled` for it ends the stream with a `complete` result. A listen without
  `toolsListChanged` completes at once (tools are all this server notifies about).

Also `ping`. Unknown methods get `-32601`, an unknown tool `-32602`, a line that is not JSON
`-32700`. Requests are handled concurrently (a loadout apply can take seconds), so replies can
come back in a different order than the requests.

A tool call's result is `{content: [{type: "text", text}], structuredContent?, isError}`: on
success `text` is MacHUD's reply as JSON (without `ok`) and `structuredContent` the same object; a
missing or wrong argument, MacHUD's `ok: false` (its `error` as the text) or MacHUD not running
(`MacHUD is not running (no socket at …)`) is `isError: true`, so the agent can correct itself.

Each tool carries `annotations` (`readOnlyHint`, `destructiveHint`, `idempotentHint`,
`openWorldHint: false`).

## Tools

| Tool | Arguments | MacHUD commands |
|---|---|---|
| `machud_status` | | `apps`, `panels`, `screens`, `loadouts`, `status`, `tooldock`, `park list`, `voice status` and `voice state`: `apps[] {app, name, health, running, actions[], panels[] {id, title, kind, visible, capabilities, actions}}`, `screens[] {index, name, main, builtin, w, h, spaces, currentSpace}`, `loadouts` (as `list_loadouts`), `toolDock {enabled, position, visible, autoHide, screenName}`, `parked[]`, `voice {status, connected, muted, phase, brainAvailable, brainProblem, sessionKey, sessionProvider, wakeListening}`. A part MacHUD cannot give is named in `unavailable {part: why}`; MacHUD not running fails the call |
| `list_loadouts` | | `loadouts`, `status`: `loadouts[] {name, layout?, windows, screens?, hud, hotkey?, startup, lastApplied}` (`lastApplied` is `status`'s `activeLoadout`) |
| `apply_loadout` | `name`, `clear?`, `screen?`, `dry_run?` | `apply loadout= [clear=1] [screen=] [plan=1]` |
| `capture_loadout` | `name`, `all_screens?`, `screen?`, `hud?` (`none`, `include`, `only`) | `capture name= [screens=all \| screen=] [hud=1 \| hud=only]` |
| `show_panel` / `hide_panel` | `app`, `panel?` | `summon` / `dismiss id=<app>/<panel>` (the tool dock's show and hide: remembered frames, hover panels by their button) |
| `toggle_panel` | `app`, `panel?` | `panels`, then `summon` or `dismiss` by the panel's `visible` |
| `list_app_actions` | `app` | none (the apps last read): `{app, name, health, running, actions[], panels[] {id, title, kind, capabilities, actions}}` |
| `app_action` | `app`, `verb`, `args?` (an object; values sent as strings) | `apps perform app= verb= <args>`. `verb` must be one of the app's action verbs, else a tool error that lists them; `args` may not use `action`, `_`, `perform`, `app`, `verb` or `name` |
| `tool_dock` | `action?` (`state`, `show`, `hide`, `position`), `position?` (the eight `HUDDockPosition`s), `screen?` | `tooldock action=…` |
| `park_window` | exactly one of `region`, `window`, `app` (+ `title?`); `edge?`, `peek?` | `park id=<region> \| window= \| app= [title=] [edge=] [peek=]` |
| `unpark` | `id?` | `unpark [id=]` |
| `open_session` | `id` | `sessions open id=` |
| `feed_add` | `text`, `source?` (default `Agent`), `title?` | `feed add text= source= [title=]` |
| `say` | `text` | `voice action name=say text=` |

`app` is an app's bundle id (the schema's `enum` lists the discovered apps) or its name. `panel`
defaults to the app's first panel and may be the panel id or title. An app's **action verbs** are
its manifest panels' `verbs` minus the panel verbs every app handles through `panel` (`show`,
`hide`, `toggle`, `frame`, `mode`). An app not in the list last read from MacHUD is looked up once
more before the call fails.

## The tool list follows the apps

The descriptions of `show_panel`, `hide_panel`, `toggle_panel`, `list_app_actions` and
`app_action` name the discovered apps (and `app_action` their action verbs), and `app` is an
`enum` of their ids. At start the server reads `apps` once, then follows MacHUD's `subscribe`
stream of `state` events (pushed on every panel change and whenever an app is discovered,
announced or forgotten). 0.3 s after events settle it reads `apps` again; when the apps differ and
the tool list differs from the one the client last listed, it sends `list_changed`. While MacHUD is
not running, or after the stream ends, it tries again every 5 s; tools called meanwhile answer
`MacHUD is not running`.
