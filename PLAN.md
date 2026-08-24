# dsh-emacs — project plan

A two-way bridge between an Emacs session and a running DeepSeek Harness (`dsh`)
session. The DSH text window is small and typing-poor; Emacs is a full editor
but lacks DSH's live agent. This project lets text move in both directions
without window-switching and copy-paste.

Status: working plan. The mount/build question is resolved and smoke-tested; the
next milestone is the minimal working prototype (MVP).

## Names (locked)

| Layer | Name |
|---|---|
| Repo / working tree | `dsh-emacs` |
| DSH plugin (npm package) | `dsh-emacs-bridge` (unscoped — `@deepseek-ai/` is reserved) |
| DSH plugin (Cordis id) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge.el` → feature `dsh-bridge`, prefix `dsh-bridge-` |

## MVP scope (initial prototype)

Jettison everything except **data transfer to and from the DSH text box**:

- **Emacs → DSH:** submit text from an Emacs buffer as a prompt that appears in
  the DSH chat. `POST /dsh-bridge/send` → `Agent.followup()`.
- **DSH → Emacs:** pull the assistant reply back into an Emacs buffer.
  `GET /dsh-bridge/output` returns the latest assistant text for the session.

Everything else is a later phase: the `/emacs` edit command, the composer
button, buffer→workspace→session targeting, drop-file/live streaming, auth.
The initial commit is this MVP working end-to-end.

### Scope-reducing decisions (decided — revisit later)

These deliberately cut scope to reach the MVP. Each is a later phase, not a
permanent answer.

- **Session targeting** — the bridge targets the session that is currently
  active in DSH (the live session whose event log is newest, ignoring subagent
  children); it does not create or configure a session. *Revisit:* pull a
  session list into Emacs and let the user choose which conversation to move
  text in/out of, plus resume across restarts
  (persistence), the buffer→workspace→session mapping.
- **Output channel** — MVP is an on-demand HTTP pull (`GET /output`, latest
  assistant text). *Revisit:* drop-file / live-tail streaming into a running
  buffer.
- **Send semantics** — `POST /send` submits the text and opens a turn (it does
  not "set the composer draft"). *Revisit:* a "set draft only" path so the
  prompt lands in the composer and the user submits it by hand. This needs a
  client-side (browser) hook, because the composer draft is browser-owned and
  the host has no handle into it. Two viable routes: (a) extend the harness's
  host→client `host/remote-event` allowlist (`API_REMOTE_FORWARDED_EVENTS`) and
  add a client draft handler — clean, but edits reference-only
  `deepseek-harness`; or (b) ship a `dsh.client` plugin from this repo that
  polls a host draft route and calls `SessionInput.setDraft` — no harness
  source change, but polling and the client-plugin plumbing. Decided: defer.
- **Model selection** — the bridge reuses the active session's existing agent,
  so it never composes an agent or installs a model selection of its own; model
  and preset decisions stay with the session the GUI created. *Revisit:* none
  until the bridge can open its own session.
- **Session durability** — the bridge owns no session, so there is nothing to
  persist or resume; it rides whatever session the GUI keeps live. *Revisit:*
  none until the bridge can open its own session.

## Architecture

Two halves, one shared concept "bridge".

- **DSH plugin** (`dsh-plugin/`): a host-plane Cordis function plugin. It runs
  inside the `dsh web` Node process, so it can drive `ctx.agents`, serve an
  HTTP route, and read `session/event`. It shells out to `emacsclient` for the
  (later) edit flow.
- **Emacs package** (`emacs/`): `dsh-bridge.el`, talking to the plugin over
  loopback HTTP.
- **Transport (MVP):** loopback HTTP both directions.

### DSH seams used (verified against `deepseek-harness/`)

| Need | Seam |
|---|---|
| Push a prompt into an agent | `Agent.followup()` (`packages/core/agent`) |
| Read the assistant reply | `session/event` / `Session.deriveMessages()` (`packages/core/session`) |
| Accept inbound HTTP | `ctx.webServer.register(route)` (`packages/host/webserver`) |
| Resolve workspace/session (later) | `ctx.workspaceRegistry` (`docs/subsystems/workspace.md`) |
| Host-side slash command (later) | `ctx.commands.register()` (`docs/subsystems/commands.md`) |

The running `dsh web` binds `127.0.0.1` by default, so the HTTP route is
loopback-only — right for a local Emacs bridge.

## DSH plugin (`dsh-emacs-bridge`) — MVP shape

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

## Emacs package (`dsh-bridge.el`) — MVP shape

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
    src/index.ts         # function-plugin skeleton
    lib/                 # build output (gitignored)
    node_modules/        # dev symlink to the checkout's node_modules (gitignored)
  emacs/
    dsh-bridge.el        # Elisp skeleton (stub)
```

## Build & mount (resolved + smoke-tested)

- **Build:** tsdown bundles `src/index.ts` → ESM `lib/index.js`. Requires
  `fixedExtension: false` with `"type": "module"` (tsdown's default is
  `fixedExtension = platform === "node"` = true, which would emit `.mjs`).
  Verified: `lib/index.js` exports `{ apply, inject, name }`, runtime import
  `createUserMessage` from `@deepseek-ai/dsh-llm` (the type-only `Context`,
  `Agent`, and `Session` imports are erased).
- **Build tooling (dev):** tsdown is invoked from the checkout's `node_modules`
  via a gitignored `dsh-plugin/node_modules` symlink; a later `pnpm install` in
  the plugin replaces that.
- **Mount shape:** a bundle — `"dsh": { "bundle": { "patch": "./cordis.patch.yml" } }`;
  the patch inserts `- id: dsh-bridge` / `name: dsh-emacs-bridge`. `id` is the
  patch/HMR target, `name` the module specifier, and the function plugin's
  `export const name` its Cordis identity. Never `export default` (postmortem
  0001).
- **Smoke-tested (isolated `DSH_HOME`):** a `--patch` overlay inserting the row
  with a `file://…/lib/index.js` name. `--dump-config` showed the `dsh-bridge`
  row; a `--no-open --port 3099` boot settled and served HTTP 200 with no
  import/apply error — the Loader imported `lib/index.js`, resolved
  `inject: ['agents', 'webServer', 'sessions']`, and ran `apply()`. `boot()`
  asserts every enabled entry activates, so a failed import/apply would have
  exited nonzero.
- **Real install (to exercise next):** `dsh plugin --profile web add
  link:../dsh-emacs/dsh-plugin` (pnpm symlinks the checkout), then the bare
  `name: dsh-emacs-bridge` resolves via the internal module loader from the
  profile directory. Requires restarting the running `dsh web`, which will be
  coordinated with the user (it is the live GUI).
- **CLI gotcha:** launcher flags (`--profile`, `--patch`, `--dump-config`) must
  precede app arguments (`--no-open`, `--port`) — the launcher stops parsing its
  own flags at the first token it does not recognize.
- **Deps:** `@deepseek-ai/cordis` is a peerDependency (one copy, or service
  injection breaks); `@deepseek-ai/dsh-*` runtime imports are peers pinned to the
  target dsh version (`^0.1.1-rc.2` here); type-only imports are devDependencies.
- **Restart discipline:** config edits to `cordis.patch.yml` hot-reload; bundle
  membership and plugin code changes require a restart.

## Open questions / next steps

1. **First commit scope.** Implement MVP (send + output) end-to-end, then the
   initial commit.

## References

DSH (in `../deepseek-harness/`):

- `docs/architecture.md` — extension-point map ("Add UI or editor integration").
- `docs/subsystems/core.md` — `Agent` handle (`followup`/`steer`/`inject`).
- `docs/subsystems/commands.md` — slash-command registry (later phase).
- `docs/subsystems/workspace.md` — workspace entity + `resolveByPath` (later).
- `docs/cookbook/extension-cookbook.md` — UI/editor plugin pattern.
- `packages/host/webserver/README.md` — `ctx.webServer.register(route)`.
- `vendor/loader/README.md` — Loader entry shape (`id` vs `name`).

Emacs (in `../emacs-30.2/`):

- `lib-src/emacsclient.c` — emacsclient invocation/protocol (later phase).
- `lisp/server.el` — `server-edit`, `server-name`, `server-eval-at` (later).
- `lisp/url/url.el`, `lisp/url/url-http.el` — HTTP client.
- `lisp/autorevert.el` — `auto-revert-tail-mode` (later phase).
