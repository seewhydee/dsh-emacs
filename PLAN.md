# dsh-emacs — project plan

A two-way bridge between an Emacs session and a running DeepSeek Harness (`dsh`)
session. The DSH text window is small and typing-poor; Emacs is a full editor
but lacks DSH's live agent. This project lets text move in both directions
without window-switching and copy-paste.

Status: Phase 2 (auth token + robustness + unit tests) is implemented and in
review — every `/dsh-bridge` route now requires `Authorization: Bearer`, the
subagent filter is tightened, and both the plugin (Vitest) and the Emacs
package (ERT) have unit tests. The next milestone is Phase 3 — see the
[Roadmap](#roadmap-phased).

## Names (locked)

| Layer | Name |
|---|---|
| Repo / working tree | `dsh-emacs` |
| DSH plugin (npm package) | `dsh-emacs-bridge` (unscoped — `@deepseek-ai/` is reserved) |
| DSH plugin (Cordis id) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge.el` → feature `dsh-bridge`, prefix `dsh-bridge-` |

## Initial prototype (implemented)

The initial prototype provides simple data transfer to and from the DSH text
box:

- **Emacs → DSH:** submit text from an Emacs buffer as a prompt that appears in
  the DSH chat. `POST /dsh-bridge/send` → `Agent.followup()`.
- **DSH → Emacs:** pull the assistant reply back into an Emacs buffer.
  `GET /dsh-bridge/output` returns the latest assistant text for the session.

## Architecture

Two halves, one shared concept "bridge".

- **DSH plugin** (`dsh-plugin/`): a host-plane Cordis function plugin. It runs
  inside the `dsh web` Node process, so it can drive `ctx.agents`, serve an
  HTTP route, and read `session/event`. It shells out to `emacsclient` for the
  (later) edit flow.
- **DSH client plugin** (Phase 3, same npm package): a `dsh.client` browser
  plugin for the DSH-side UI affordances (message button, composer draft).
- **Emacs package** (`emacs/`): `dsh-bridge.el`, talking to the plugin over
  loopback HTTP.
- **Transport:** loopback HTTP both directions, plus (Phase 3+) a plugin-owned
  SSE channel for host→client and host→Emacs notification push.

### DSH seams (verified against `deepseek-harness` @ 0.1.1-rc.2)

| Need | Seam |
|---|---|
| Push a prompt into an agent | `Agent.followup()` (`packages/core/agent/src/runtime-types.ts`) |
| Read the assistant reply | `Session.deriveMessages()` (`packages/core/session`) — filter `content` blocks to `type === 'text'` |
| Accept inbound HTTP | `ctx.webServer.register(route)` (`packages/host/webserver`) — handler owns the raw response, so SSE/streaming works |
| Live sessions | `ctx.sessions.list()` (`SessionStore`) — **live only**, never persisted-cold ones |
| Live agents | `ctx.agents.get(id)` / `.list()` / `.roots()` (`AgentRegistry`) |
| Persisted sessions | `ctx.sessionPersistence.list()` → headers (id, cwd, createdAt, origin — **no title**); titles need folding `session/title` events from `inspect()` |
| Resume a cold session | `ctx.agents.resume()` (pattern: `ensureSession` in `packages/host/apiproxy/src/api-proxy.ts`) |
| Create a session host-side | `ctx.agents.create({ sessionId, meta: { cwd } })` — it then appears in the web UI automatically |
| Host→client / host→Emacs push | own SSE route via `webServer.register` (precedent: `client-hmr`'s `GET /plugins/events`) — **no dsh source edit needed** |
| Live event source | `ctx.on('session/event', (session, event) => …)` on the root context sees all sessions |
| Slash command (host) | `ctx.commands.register()` — handler gets `CommandInvocation { agent, rawInput, … }`; works out-of-tree |
| Message action button | client slot `conversation.chat.assistant-actions` (template: `packages/client/ui-message-feedback`) |
| Composer draft | client-side `SessionInput.setDraft` / `InputState.draft` via `ctx.conversation.input` |
| Workspace (later) | `ctx.workspaceRegistry`, `resolveByPath` (`docs/subsystems/workspace.md`) |
| Open-in-editor spawn template | `packages/host/apiproxy/src/native-path-opener.ts` (for `emacsclient`) |

The running `dsh web` binds `127.0.0.1` by default, so the HTTP route is
loopback-only — right for a local Emacs bridge. Note plugin-registered routes
get no auth or origin checking from the framework (the `/api` DNS-rebinding
fence covers only `/api`), so the bridge adds its own token (Phase 2).

### Client plugin (verified)

An out-of-tree `link:` bundle **can** ship a working `dsh.client` plugin:
`ClientModuleRegistry` (`packages/client/modules`) scans all live Loader
entries and resolves each package from the profile dir, so the existing
`dsh-bridge` row becomes dual-face by adding `dsh.client` +
`exports["./client"]` to `dsh-plugin/package.json`. The one awkward part: the
shared tsdown client-bundle preset is repo-locked (it globs
`packages/*/*/package.json` inside the dsh repo), so Phase 3 hand-rolls the
bundle artifact in our own tsdown config — factory-form CJS with the
`window.__ModuleLoader__.load({ id, factory })` banner/footer, externals =
`PLATFORM_MODULES` + `@deepseek-ai/dsh-client-runtime/client` (see
`packages/client/tsdown.client.ts` and `packages/client/web/src/platform.ts`).

## DSH plugin (`dsh-emacs-bridge`) — MVP shape (implemented)

- Function plugin: `export const name = 'dsh-bridge'`, `inject`, `apply`. No
  default export and no `Config`: the bridge rides the active session. MVP
  `inject: ['agents', 'webServer', 'sessions']`; `sessions` read via
  `ctx.get(...)`.
- Targeting: enumerate live sessions (`sessions.list()`), skip subagent
  children, pick the one whose newest event `time` is latest, and drive its
  live agent (`ctx.agents.get(id)`).
- HTTP routes (under `/dsh-bridge/`):
  - `POST /send { text }` → last-active agent → `followup()`.
  - `GET /output` → latest assistant text.

## Emacs package (`dsh-bridge.el`) — MVP shape (implemented)

- `defcustom`: `dsh-bridge-url` (base URL of the HTTP route).
- `dsh-bridge-send-region` / `dsh-bridge-send-buffer` (→ POST `/send`).
- `dsh-bridge-get-output` (→ GET `/output` into `*dsh-bridge-output*`).
- HTTP via `url-retrieve` + `json.el` (both built-in).

## Directory layout

```
dsh-emacs/
  PLAN.md
  README.md
  .gitignore
  dsh-plugin/            # unscoped npm package: dsh-emacs-bridge
    package.json         # dsh.bundle -> ./cordis.patch.yml; exports -> lib/index.js
    tsdown.config.ts     # src/index.ts -> lib/index.js (ESM)
    cordis.patch.yml     # bundle patch: inserts the dsh-bridge row
    src/index.ts         # host function plugin
    src/client/          # (Phase 3) dsh.client browser plugin
    lib/                 # build output (gitignored)
    node_modules/        # dev symlink to the checkout's node_modules (gitignored)
  emacs/
    dsh-bridge.el        # Emacs package
```

## Build & mount (done)

- **Build:** `cd dsh-plugin && pnpm install && pnpm build` → tsdown emits ESM
  `lib/index.js`. Needs `fixedExtension: false` with `"type": "module"` (the node
  default would emit `.mjs`). The dev `node_modules` is a gitignored symlink to
  the harness checkout's `node_modules`.
- **Mount shape:** a bundle — `"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }`.
  The patch inserts `id: dsh-bridge` / `name: dsh-emacs-bridge`; `id` is the
  patch/HMR target, `name` the module specifier, `export const name` the Cordis
  identity. Never `export default`.
- **Install:** `dsh plugin --profile web add link:<abs path to dsh-plugin>`, then
  restart `dsh web` (see the README for the global-install vs. `pnpm dsh`
  variants).
- **Deps:** `@deepseek-ai/cordis` is a peerDependency (one copy, or service
  injection breaks); `@deepseek-ai/dsh-*` runtime imports are peers pinned to the
  target dsh version (`^0.1.1-rc.2` here); type-only imports are devDependencies.
  The repo is pre-release with no compatibility promise — re-verify the seams
  table above on any dsh version bump.
- **Restart discipline:** edits to `cordis.patch.yml` hot-reload; bundle
  membership, plugin code, and client-bundle changes require a `dsh web`
  restart.

## Roadmap (phased)

Decisions already taken (2026-08, with the seam verification above):

- **Targeting:** single target session in the bridge (defaults to last-active)
  plus an optional per-request `sessionId` override.
- **Session scope:** target **live sessions only** for now. Persisted sessions
  are listed for visibility but not resumable from the bridge yet (resume via
  `ctx.agents.resume()` is a later phase, as is any bridge-owned session via
  `ctx.agents.create()`).
- **Auth:** a shared bearer token on all `/dsh-bridge` routes, early.
- **Testing:** Vitest for the TypeScript plugin (unit tests of extracted pure
  logic) and ERT for the Elisp helpers, introduced in Phase 2. Plugin logic
  lives in dependency-free pure modules (`src/logic.ts`) so tests never boot a
  host; `index.ts` stays thin wiring over the Cordis services.
- **DSH→Emacs push:** Emacs pulls from a host-side outbox; no `emacsclient`
  push for text transfer.
- **Host→browser push:** the plugin serves its own SSE route; the client
  plugin consumes it. Never edit `deepseek-harness` (in particular, do not
  touch the `API_REMOTE_FORWARDED_EVENTS` allowlist).
- **Streaming:** no live tail of assistant text into Emacs (that is DSH's job
  — see the README). Instead, turn-completion **notifications** over SSE, and
  Emacs pulls the full reply on notice.

### Phase 1 — Session inventory and targeting (implemented)

Every later feature needs session ids, so this came first.

- Host:
  - Added `sessionPersistence` to `inject`.
  - `GET /dsh-bridge/sessions` → merged list: live sessions (id, cwd,
    last-active, live: true) from `sessions.list()` + persisted headers (live:
    false) from `sessionPersistence.list()`. Skips subagent children.
  - Target-session state in the plugin (default: last-active, the MVP
    behavior); `/send` and `/output` accept an optional `sessionId` override.
    Overrides and `/select` reject non-live sessions (404) and live sessions
    with no live agent (409) — no resume yet. `GET /current` clears and
    reports a dead pin as null.
- Emacs:
  - `dsh-bridge-list-sessions` (tabulated list), `dsh-bridge-select-session`,
    `dsh-bridge-current-session`; send/output honor the chosen session, falling
    back to last-active.

### Phase 2 — Auth token, robustness, and unit tests (implemented)

- **Refactor first:** extract the plugin's pure, dependency-free logic into
  `src/logic.ts` — `latestAssistantText`, `mergeSessionRows`, the subagent-child
  predicate, `resolveTargetId`, and the bearer parse + constant-time compare —
  so it can be unit-tested without booting a host. `index.ts` becomes thin
  wiring.
- **Testing:** Vitest (`dsh-plugin/tests/*.spec.ts`) for the plugin, run by
  `pnpm test`; ERT (`emacs/dsh-bridge-tests.el`) for the Elisp helpers, run by
  `emacs --batch`. No system packages: Vitest is an npm devDependency and ERT
  ships with Emacs.
- **Host:** generate (or read) a shared token from `$DSH_HOME/dsh-bridge-token`
  (default `~/.dsh/dsh-bridge-token`, mode 0600); require
  `Authorization: Bearer` on every route (401 otherwise).
- **Emacs:** `dsh-bridge-token` (read from the same file by default); send the
  header on every request.
- **Robustness:** tighten subagent filtering (also skip sessions whose live
  parent owns them, matching `hasApiRemoteSubagentOwner`); surface HTTP status
  codes in Emacs error messages; handle `url-retrieve` timeouts.

### Phase 3 — Client plugin: "Send to Emacs" button and composer draft

The big rock. Splits into independently landable pieces:

1. **Build plumbing:** hand-rolled tsdown client-bundle config emitting the
   factory-form `client.js` (banner/footer/externals per
   `packages/client/tsdown.client.ts`); `dsh.client` + `exports["./client"]`
   in `package.json`. Verify the bundle loads (it boots loud on failure —
   `MissingClientBundleError`).
2. **Outbox + button:** host `POST /dsh-bridge/outbox` (deposit, with
   `sessionId` and a source label), `GET /dsh-bridge/outbox` + ack (collect).
   Client plugin registers a "Send to Emacs" button into
   `conversation.chat.assistant-actions` (copy the `ui-message-feedback`
   pattern; the slot injects `messageId`, and the component reads the message
   text from the conversation snapshot). Emacs: `dsh-bridge-pull-inbox`
   collects into a buffer.
3. **Composer draft push:** host SSE route (`GET /dsh-bridge/events`,
   HMR-style fan-out) + `POST /dsh-bridge/draft { text, sessionId? }`; client
   plugin subscribes and calls `SessionInput.setDraft` for the target session
   scope. Emacs: `dsh-bridge-send-draft` — text lands in the DSH composer for
   review instead of auto-submitting. (`POST /send` keeps its submit
   semantics.)

### Phase 4 — `/emacs edit` flow

The agent hands a file to Emacs rather than only moving text.

- Host: register `/emacs` via `ctx.commands.register()` (handler gets the
  invocation's `agent`); plus an HTTP route `POST /dsh-bridge/open { path,
  line? }`. Both shell out to `emacsclient` (spawn template:
  `native-path-opener.ts`), respecting `server-name`.
- Emacs: `dsh-bridge-open-file` (the reverse direction — ask DSH to open the
  current file's path in the session's workspace context, if wanted).

### Phase 5 — Turn-completion notifications and Emacs ergonomics

- Host: on the SSE route from Phase 3, emit a `turn-complete` notice per
  session (from `session/event` turn/step boundaries), carrying the
  `sessionId` — not the text.
- Emacs: a lightweight SSE consumer (`make-network-process` or
  `url-retrieve` on the events endpoint) that, on notice for the current
  target session, refreshes the output buffer (pull) or just messages.
- Ergonomics: `dsh-bridge-minor-mode` for sending from any buffer; a
  transcript buffer per session in a `markdown-mode`-derived major mode;
  transient keymap; buffer→session mapping.

### Deferred (revisit on demand)

- Resume of persisted sessions (`ctx.agents.resume()`) and bridge-owned
  sessions (`ctx.agents.create()`) with their own model/preset.
- Full live tail of assistant text into Emacs (rejected for now — see the
  README philosophy).
- `emacsclient` push for text transfer (pull won; push may still be wanted for
  the edit flow's file-opens).
- Binding the route beyond loopback (would need real auth, TLS, and origin
  checks).

## References

DSH (in `../deepseek-harness/`):

- `docs/architecture.md` — extension-point map ("Where new behavior goes"
  table, incl. "Add UI or editor integration").
- `docs/subsystems/core.md` — `Agent` handle (`followup`/`steer`/`inject`).
- `docs/subsystems/commands.md` — slash-command registry.
- `docs/subsystems/workspace.md` — workspace entity + `resolveByPath`.
- `docs/cookbook/extension-cookbook.md` — UI plugin pattern (`session/event`
  feed + `agent.followup`); the ACP bridge (`packages/acp/acp`) is the closest
  architectural sibling.
- `packages/host/webserver/README.md` — `ctx.webServer.register(route)`.
- `packages/client/ui-message-feedback/` — template client plugin (dual-face
  package, assistant-actions slot).
- `packages/client/tsdown.client.ts` + `packages/client/web/src/platform.ts` —
  client-bundle artifact contract and platform externals.
- `packages/host/apiproxy/src/native-path-opener.ts` — spawn template for
  `emacsclient`.
- `vendor/loader/README.md` — Loader entry shape (`id` vs `name`).

Emacs (in `../emacs-30.2/`):

- `lib-src/emacsclient.c` — emacsclient invocation/protocol (Phase 4).
- `lisp/server.el` — `server-edit`, `server-name`, `server-eval-at` (Phase 4).
- `lisp/url/url.el`, `lisp/url/url-http.el` — HTTP client.
- `lisp/autorevert.el` — `auto-revert-tail-mode` (only if the tail is ever
  revived).
