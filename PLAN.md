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

- **Session targeting** — MVP uses exactly one session, named by config
  `sessionId` (default `dsh-emacs`), created on first send and reused while the
  process lives. *Revisit:* per-workspace / per-GUI-session selection, resume
  across restarts (persistence), the buffer→workspace→session mapping.
- **Output channel** — MVP is an on-demand HTTP pull (`GET /output`, latest
  assistant text). *Revisit:* drop-file / live-tail streaming into a running
  buffer.
- **Send semantics** — `POST /send` submits the text and opens a turn (it does
  not "set the composer draft"). *Revisit:* a "set draft only" path (needs a
  client-side gesture).
- **Model selection** — the bridge installs a one-time snapshot of the default
  model selection (`agentDefaultModel.currentSelection()` at agent creation),
  unlike the gateway's live three-tier getter. A later default-model change
  does not reach bridge sessions. *Revisit:* live selection getter, model
  switching, and the double-`installModelSelection` interaction if a browser
  client ever opens a bridge session.
- **Session durability** — bridge sessions are in-memory only: no workspace
  attach, no `mkdir` of `cwd`, no persisted-session resume after a `dsh web`
  restart (the gateway does all three). *Revisit:* adopt `ensureSession`-style
  resume once session targeting lands.

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

- Function plugin: `export const name = 'dsh-bridge'`, `inject`, `Config`,
  `apply`. No default export. MVP `inject: ['agents', 'webServer']`;
  `agentDefaultModel`, `agentPresets` read via `ctx.get(...)`.
- Config fields (no hardcoded tunables):
  - `sessionId` (default `dsh-emacs`) — the one session the MVP targets.
  - `cwd` (default `process.cwd()`) — the session's working directory.
  - `presetId` (optional) — preset to compose; absent = deployment default.
- HTTP routes (under `/dsh-bridge/`):
  - `POST /send { text }` → ensure agent → `followup()`.
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
  Verified: `lib/index.js` exports `{ apply, inject, name }`, no runtime imports
  (the type-only `Context` import is erased).
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
  `inject: ['agents']`, and ran `apply()`. `boot()` asserts every enabled entry
  activates, so a failed import/apply would have exited nonzero.
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
