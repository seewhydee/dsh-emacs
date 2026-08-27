# dsh-emacs — project plan

A two-way bridge between an Emacs session and a running DeepSeek Harness (`dsh
web`) session. The DSH text window is small and typing-poor; Emacs is a full
editor but lacks DSH's live agent. The bridge moves text in both directions
over loopback HTTP without window-switching and copy-paste. Emacs is a
*companion* to a live DSH session (the web UI stays the primary interface),
not a replacement client — see [Deferred](#deferred) for why we are not
pursuing the Emacs-as-primary-client (ACP-style) model.

## Names (locked)

| Layer | Name |
|---|---|
| Repo / working tree | `dsh-emacs` |
| DSH plugin (npm package) | `dsh-emacs-bridge` (unscoped — `@deepseek-ai/` is reserved) |
| DSH plugin (Cordis id) | `dsh-bridge` |
| Emacs feature / file | `dsh-bridge.el` → feature `dsh-bridge`, prefix `dsh-bridge-` |

## What's implemented

**Host plugin** (`dsh-plugin/src/index.ts`, thin wiring over pure logic in
`src/logic.ts`; outbox in `src/outbox.ts`):

- Loopback HTTP routes under `/dsh-bridge/` on the harness's `webServer`:
  - `POST /send { text, sessionId? }` → `Agent.followup()` (submit).
  - `POST /draft { text, sessionId? }` → push to the DSH composer via SSE
    (409 when no browser client is subscribed).
  - `GET /output?sessionId=` → latest assistant text.
  - `GET /prompts?sessionId=`, `GET /replies?sessionId=` → session history,
    newest first.
  - `GET /sessions` → merged live + persisted sessions, with titles (via the
    optional `sessionProjectionCache`, falling back to folding `session/title`
    events from `inspect()`), workspace titles, and archived flags (via the
    optional `workspaceRegistry`).
  - `GET /outbox`, `POST /outbox`, `POST /outbox/ack` → bounded, acked
    DSH→Emacs inbox; every entry is session-scoped; deposits fan an SSE
    notice out to all subscribers.
  - `GET /token` → vends the shared token (fenced to loopback peer + origin).
  - `GET /events?token=` → SSE stream (composer-draft push + outbox notices).
- Auth: shared bearer token at `$DSH_HOME/dsh-bridge-token` (generated on
  first use, mode 0600), required on every route except the two above.
- Targeting: no host-side pin. A request without `sessionId` resolves to the
  last-active live session; explicit overrides must be live, non-subagent
  sessions with a live agent (404/409 otherwise). Live-only: no resume yet.

**Client plugin** (`dsh-plugin/src/client/`, `dsh.client` browser bundle):

- "Send to Emacs" button in the `conversation.chat.assistant-actions` slot
  (GNU Emacs icon, `zh`/`en` locales) → deposits the message into the outbox.
- Token auto-vend from `/dsh-bridge/token` (cached in memory + localStorage,
  one re-vend retry on 401).
- SSE subscription that applies incoming drafts via `SessionInput.setDraft`
  for the target session scope.

**Emacs package** (`emacs/dsh-bridge.el`):

- `M-x dsh-bridge` transient dispatcher; `dsh-bridge-list-sessions` tabulated
  session list (live / live+saved / live+saved+archived cycling, default-target
  marker, peek/describe/copy-id).
- `dsh-bridge-view-mode`: read-only reply buffer with GFM font-lock (when
  markdown-mode is installed), `M-p`/`M-n` reply navigation, copy, refetch.
- `dsh-bridge-prompt-mode`: markdown-derived composition buffer with prompt
  history (`M-p`/`M-n`), `C-c C-c` send / `C-c C-d` draft.
- Session selection is Emacs-side: a default target session plus per-buffer
  session bindings; commands fall back to last-active.
- SSE notification consumer (`make-network-process`, chunked decoding,
  reconnect with retry) that auto-receives outbox pushes into the view buffer;
  `dsh-bridge-notifications` to disable, `dsh-bridge-receive` to pull manually.
- HTTP via `url-retrieve` + `json.el`, bearer token read from the token file.
- `dsh-bridge-install-plugin`: installs the bundled plugin build into a DSH
  profile (`dsh-bridge-profile`, default `web`) via `dsh plugin add file:...`.

**Tests:** Vitest for the plugin's pure logic (`pnpm test` in `dsh-plugin/`);
ERT for the Elisp helpers (`emacs --batch`).

## Build & mount

- Plugin build: `make build` (installs deps if needed; falls back to direct
  tsdown when pnpm refuses a symlinked `node_modules`) → ESM `lib/index.js`
  (host) + CJS `lib/client.js` (browser, hand-rolled `tsdown.client.config.ts`
  emitting the factory-form bundle per the harness's client-artifact contract).
- Install (dev): `dsh plugin --profile web add link:<abs path to dsh-plugin>`,
  restart `dsh web` (see README for the source-checkout variant).
- Install (packaged): `make package` → `dsh-bridge-<version>.tar` (Emacs
  package bundling the built plugin); `M-x package-install-file`, then
  `M-x dsh-bridge-install-plugin`, then restart `dsh web`.
- Mount shape: dual-face — `"dsh": { "bundle": { "patch": "./cordis.patch.yml" },
  "client": { "platform": "web" } }` plus `exports["./client"]`.
- Restart discipline: `cordis.patch.yml` edits and client-bundle changes
  hot-reload; host plugin code and manifest changes need a `dsh web` restart.
- The harness is pre-release (`^0.1.1-rc.2`) with no compatibility promise —
  re-verify the Cordis service seams and the client-bundle artifact contract
  (`packages/client/tsdown.client.ts`) on any dsh version bump.

## Next steps

In suggested order:

1. **Turn-completion notifications.** The SSE plumbing exists on both ends.
   Host: subscribe `ctx.on('session/event')`, emit `{ kind: "turn-complete",
   sessionId }` at turn/step boundaries (no text on the wire). Emacs: on
   notice for the view buffer's session, refetch the latest reply (or just
   message).
2. **Resume saved sessions.** The session list already shows persisted
   sessions, but they are inert. Use `ctx.agents.resume()` (pattern:
   `ensureSession` in `packages/host/apiproxy/src/api-proxy.ts`) so selecting
   or targeting a saved session makes it live; then fetch/prompt buffers can
   work on it. Likely the biggest functional gap.
3. **`/emacs edit` flow.** Host: register `/emacs` via
   `ctx.commands.register()` plus `POST /dsh-bridge/open { path, line? }`,
   both shelling out to `emacsclient` (spawn template:
   `packages/host/apiproxy/src/native-path-opener.ts`), respecting
   `server-name`. Emacs: optionally `dsh-bridge-open-file` for the reverse
   direction.
4. **Ergonomics, as demand warrants:** per-session transcript buffer (the
   `/prompts` + `/replies` material is already served); a
   `dsh-bridge-minor-mode` for sending from any buffer (the transient menu
   currently fills this role).

No additional DSH-interface (client plugin) features are planned for now —
candidates (full-transcript export, a user-message action, bridge-status
indicator) are parked pending a decision on what the web UI side should grow.

## Deferred

- **Headless / profile-agnostic mode.** The shipped `headless` profile is
  one-shot task mode (no listening port, exits after one task), so "headless
  support" would mean a long-lived custom profile (`dsh-base` + the bridge
  bundle, via the existing `dsh plugin --profile <name> add` mechanism — no
  harness changes). The known path: drop the `webServer` injection and open
  the plugin's own loopback HTTP listener in `index.ts` (the route/auth/Emacs
  stack is unchanged; `workspaceRegistry` and `sessionProjectionCache` are
  already optional `ctx.get` reads). Deferred because: live sessions are
  per-process, so it could not attach to web-UI sessions anyway (only
  persisted ones); process lifecycle becomes a user support burden; and the
  resulting Emacs ↔ agent prompt/response core overlaps with the ACP
  ecosystem — the harness ships an ACP bridge (`packages/acp/acp`, fresh
  sessions only, committed text only) and agent-shell/acp.el are mature MELPA
  packages. Our differentiator is the companion-to-a-live-session model
  (attach, session inventory, draft review, cross-surface push), not
  Emacs-as-primary-client.
- Bridge-owned sessions via `ctx.agents.create()` with their own model/preset.
- Full live tail of assistant text into Emacs (rejected — that is DSH's job;
  see the README). Turn-completion notices (next step 1) are the substitute.
- `emacsclient` push for text transfer (pull won; push may still be wanted for
  the edit flow's file-opens).
- Binding the route beyond loopback (would need real auth, TLS, origin checks).

## References

DSH (in `../deepseek-harness/`):

- `docs/architecture.md` — extension-point map.
- `docs/cookbook/extension-cookbook.md` — plugin patterns; the ACP bridge
  (`packages/acp/acp`) is the closest architectural sibling.
- `docs/subsystems/core.md` — `Agent` handle (`followup`/`steer`/`inject`).
- `docs/subsystems/commands.md` — slash-command registry (edit flow).
- `packages/host/webserver/README.md` — `ctx.webServer.register(route)`.
- `packages/client/ui-message-feedback/` — template client plugin.
- `packages/client/tsdown.client.ts` + `packages/client/web/src/platform.ts` —
  client-bundle artifact contract.
- `packages/host/apiproxy/src/native-path-opener.ts` — spawn template for
  `emacsclient`.
- `packages/host/apiproxy/src/api-proxy.ts` (`ensureSession`) — resume pattern.

Emacs (in `../emacs-30.2/`):

- `lib-src/emacsclient.c`, `lisp/server.el` — edit flow.
- `lisp/url/url.el`, `lisp/url/url-http.el` — HTTP client.
