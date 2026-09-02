# dsh-emacs-bridge UX improvement plan

Status: **partially implemented.** Sections 1–4 (turn-following view,
blank-on-send, jump-to-view on `C-c C-c`, live pulse + boundary echo) are
implemented and tested. Section 5 (ask-user handling) is the remaining second
phase.

This plan is scoped to **`dsh-emacs-bridge` only**. No change to the
DeepSeek Harness (DSH) sources is permitted: the package must stay a drop-in,
redistributable-to-the-public Emacs package, so it cannot reasonably require a
harness-side modification.

---

## Guiding principle ("feel Emacs-y, not a chat clone")

Everything below lives in the **header line / mode line, the echo area, and
edit buffers** — the places Emacs users already expect status and prompts.
Concretely:

- **No fake chat bubbles and no token-by-token streaming** into the view. The
  bridge deliberately keeps voluminous model output out of Emacs (see README);
  we do not reverse that.
- **The echo area is the "something happened" channel**, in the spirit of Gnus
  reporting "Checking new news..." or `package.el` announcing a process. A turn
  starting/ending *messages*; it doesn't spawn a popup.
- **The header/mode line is the "busy" channel**, in the spirit of `magit` /
  `nrepl` showing a process state and Gnus showing unread counts. A running
  session gets a live, data-driven pulse.
- **`M-p`/`M-n` are history navigation**, both for prompts and replies, rather
  than a scrollback that mimics a chat widget.

The core UX change is giving the DSH-View **three explicit states** and making
the DSH-Prompt a **compose-then-blank** buffer:

| DSH-View state | `dsh-bridge--view-follow` | `dsh-bridge--view-replies-index` | Behavior when a new turn lands |
|---|---|---|---|
| **at rest** | nil | nil | refresh reply cache only; refill on `turn-complete` (today's behavior) |
| **following** | t | nil (newest) | **auto-refill to newest** on `replies-changed` *and* `turn-complete`; live pulse in the header |
| **cycling** | nil | integer | navigate history; no refill (today's behavior) |

`C-c C-c` becomes the connective tissue: it hands the prompt to the session and
drops the user into the view **in following state**, so "I sent the prompt and
it's now being worked on" is concrete and immediate.

---

## 1. Turn-following DSH-View state

Add a buffer-local `dsh-bridge--view-follow` (default nil) plus a small set of
helpers, and wire it through the existing reply-navigation state machine
(`dsh-bridge--view-show-reply`, `dsh-bridge-view-previous-reply`,
`dsh-bridge-view-next-reply`, `dsh-bridge--view-next-reply-from-rest`).

- **`dsh-bridge--view-following-p`** = at rest and `dsh-bridge--view-follow` is t.
- **Enter following:** set `follow` t, `index` nil, refill to the newest reply.
  Entering following **discards `dsh-bridge--view-replies-anchor`**: the anchor
  exists to restore pre-cycling content, and following by definition shows the
  newest reply, so a stale anchor could only jump the view backward on a later
  `M-n`.
- **Leave following:** `M-p` (previous reply) clears `follow` and then runs the
  existing anchor-and-step-older logic; any `M-p`/`M-n` cycle clears it.
- **`M-n` at the newest reply activates following.** In
  `dsh-bridge-view-next-reply`, reaching index 0 currently either restores the
  anchor or reports "no newer replies"; instead, set `follow` t and refill to
  the newest (discarding the anchor per above). The entry is unconditional —
  following an idle session is inert until the next frame — and announced with
  a `dsh-bridge: following new replies` echo, since the only other feedback is
  the header's `⤓` marker. Following is effectively "turn 0".
- **`M-n` while following is a no-op.** Following means index nil, so `M-n`
  would route through `dsh-bridge--view-next-reply-from-rest`, which
  force-refreshes and can step one newer — but the view already shows the
  newest reply. Short-circuit it with a "already following the newest reply"
  message so the from-rest path never fights the follow state.
- **While following:** the view re-renders to the newest reply on both
  `replies-changed` and `turn-complete`. Today `replies-changed` only
  refreshes the reply cache (`dsh-bridge--view-replies-cache-refresh`); extend
  it to refill the shown text when following. `turn-complete` already refills
  when the view shows the session and is not cycling
  (`dsh-bridge--turn-complete-refetch`), and since following reads as
  not-cycling to `dsh-bridge--view-cycling-p` (which is index-based), that
  path needs no change.
- **Shows committed mid-turn steps.** Because `replies-changed` fires for each
  `assistant/message` committed mid-turn, follow mode shows those committed
  step messages as they land — coarse-grained live progress, **not** fine
  token streaming. This is a deliberate, visible behavior change worth stating
  as intended: it is the "I can see it making progress" signal, without
  reversing the no-streaming rule.

The `(k/n)` header shows `(1/n)` while following. This falls out of the
existing `dsh-bridge--view-reply-position`: at rest it locates the shown text
in the reply list, and the newest reply is position 1 — no new display logic.

## 2. Blank prompt on reply, `M-p` restores the last prompt

Today `C-c C-c` → `dsh-bridge--prompt-exit` deliberately leaves the prompt
buffer intact (message-mode "edit-and-resubmit" feel), so pressing `r` later
reopens the **old** prompt. Change to a compose-then-blank flow:

- In `dsh-bridge--prompt-exit` (`emacs/dsh-bridge.el`), on success and while in
  `dsh-bridge-prompt-mode`: `erase-buffer`. Nothing else is new —
  `dsh-bridge--prompt-history-record-send` already resets
  `dsh-bridge--prompt-history-index` and `dsh-bridge--prompt-draft` to nil on
  every successful send, and `dsh-bridge--prompt-exit` already calls
  `set-buffer-modified-p nil`. The sent text is already recorded by
  `dsh-bridge--prompt-history-record-send`, so `M-p` retrieves it (anchoring
  the now-empty buffer as the draft), and `dsh-bridge-prompt-resend-confirm`
  still guards an identical re-send.
- Do the same after a successful `C-c C-d` draft push (the composer now owns
  the text) — **but only when the draft was sent from the prompt buffer**.
  `dsh-bridge-draft` is a general verb callable from any buffer, and blanking
  `*dsh-bridge-prompt*` then would wipe unrelated unsent text.
  **Acknowledged asymmetry:** drafts are deliberately never recorded in the
  prompt history — that is what keeps the resend guard sound
  (`dsh-bridge--resend-guard-p`) — so a blanked draft is not retrievable via
  `M-p`. The way back is the composer-draft push from the browser client. This
  is acceptable: a draft's whole point is that the composer owns it.
- Leave plain `dsh-bridge-send` / `dsh-bridge-draft` (the non-exit verbs) as-is:
  those keep the buffer for in-transient editing.

Result: "type → send → buffer resets, history intact." History via `M-p` is the
Emacs-y analogue of a chat's previous-prompt log.

## 3. `C-c C-c` → jump to the DSH-View in following state

Today `dsh-bridge--prompt-exit` only switches to `*dsh-bridge-output*` when it
already shows the sent session, else it buries to the previous buffer. Change a
successful `C-c C-c` to:

1. **Optimistically** set the sent session's status to `running` in
   `dsh-bridge-send-text`'s success branch (`dsh-bridge.el`, the `(alist-get
   'sessionId alist)` branch) via `dsh-bridge--status-set`, **and call
   `dsh-bridge--status-event-render`** so the view header and sessions row
   actually repaint immediately instead of waiting on the SSE `turn-start`
   round-trip. (On a genuinely failed send, the later `turn-complete`/error
   path corrects it.)
2. Pop to `*dsh-bridge-output*` for the sent session, filled with the session's
   latest text (the previous turn until the new one commits), **in following
   state**. Use `pop-to-buffer`/`display-buffer` semantics (not a bare
   `switch-to-buffer`), so the jump doesn't replace a window that is showing a
   *different* session's view.
3. Echo a session-labelled message instead of the terse `"dsh-bridge: prompt
   sent"` (`dsh-bridge.el:1532`), e.g. `dsh-bridge: prompt sent to "Label" —
   thinking…`, using `dsh-bridge--session-label`.

`turn-start` then triggers the "… is thinking…" echo, and the pulse/auto-refill
of item 1 make the session visibly come alive.

## 4. Live turn pulse in the DSH-View header + turn-boundary echo

Complementary, non-intrusive signals while the shown session is running:

- **Data pulse (header):** show the live elapsed time since turn start
  (`⏱ 00:23`) and the live context occupancy (`· 43%`) in the view header. The
  context % is already computed host-side and folded into
  `dsh-bridge--session-context`; today it only re-renders the DSH-Prompt header
  (the `FIXME` at `dsh-bridge.el:860`, which only does
  `force-mode-line-update`). Drop that FIXME and **also re-set the view header**
  here (a `with-current-buffer` on the live output buffer re-setting
  `header-line-format` from `dsh-bridge--view-header-line`), so the view header
  tracks `context` frames live.
- **Elapsed ticker:** the turn-start SSE frame already carries the turn's
  ms-epoch `time` (`turnStartMessage`, `dsh-plugin/src/logic.ts:443`), but the
  Emacs status tracker currently discards it — `dsh-bridge--status-set` stores
  only the state symbol. Store the start time alongside the status and tick the
  header with a short repeating `run-at-time`. **Timer ownership:** implement it
  as a *single* timer that re-checks, on each tick, whether the live output
  buffer still shows a `running` session (`dsh-bridge--view-shown-session-p` +
  `dsh-bridge--status-state`); if not, it cancels itself. This provably
  satisfies "never run for a session the user is not looking at" without
  per-session timers to leak. **Degradation rule:** when Emacs attaches or
  reconnects mid-turn there is no `turn-start` frame, hence no t0; in that case
  the elapsed segment is simply omitted until the next turn boundary (the
  context % still pulses). Do not add a turn-started-at field to a route just
  for this. **Lifecycle:** cancel the timer on `turn-complete`, on buffer kill,
  and when the shown session changes. Gate the whole ticker behind a
  `defcustom`, **default on**, since its cost is bounded to the shown session.
- **Turn-boundary echo (echo area):** on `turn-start`, `message`
  `dsh-bridge: session "Label" is thinking…` for the session the user is
  looking at (`dsh-bridge--user-looking-p`); on `turn-complete`, echo the
  existing reason phrase (`dsh-bridge--turn-reason-phrase`). Today only
  `turn-complete` echoes, and only in the `message` action variant; the default
  is `refetch`.

This keeps the "busy" sense entirely in the header/mode line and echo area —
Emacs-native — rather than animating a chat widget.

## 5. Ask-user (`ask_user_question`) handling

At present, the DSH-Emacs bridge has no handling for the `ask_user_question` tool, so whenever the model reaches for this tool, nothing can be done from the Emacs side until the user switches over to the DSH web interface and answers from there.

### What the harness provides

`ask_user_question` (`@deepseek-ai/dsh-tool-ask-user`, tool name confirmed in
`packages/interaction/tool-ask-user/src/index.ts`) calls
`ctx.userQuestions.ask(request)` with `{ questions, agent, signal }`. The host
fills **exactly one** `UserQuestionProvider`
(`packages/interaction/user-questions/src/index.ts:64-73`): `registerProvider`
throws `DUPLICATE_PROVIDER` if a second registers. In the `web` profile the
provider is the web apiproxy (`packages/host/apiproxy/src/api-proxy.ts:1310`):
it mints an `rpcId`, pushes a `question/requested` frame to **mux**
connections, and resolves the awaiting promise when a matching answer arrives.

The two wire endpoints (`packages/host/apiproxy/src/fetch/handler.ts`):

- **`GET /api/events.mux`** (line 254) — a no-envelope SSE stream carrying
  `question/requested` frames with their `rpcId`. Mux-open **replays
  still-pending questions with the same rpcId** (api-proxy.ts:~1352), and
  `question/resolved` broadcasts settle/cancel. No auth beyond the server's
  loopback binding.
- **`POST /api/respond`** (lines 296-300) — a plain JSON POST taking
  `{ rpcId, result }`, validated by `questionResponsePayloadSchema` and
  `matchesQuestions`. The only fences are loopback and a content-type
  `application/json` check. A late or duplicate answer gets
  `{ accepted: false, reason: 'not-pending' }` — a benign race outcome.

Wire shape: `AskUserQuestionItem` =
`{ id, question, detail?, header?, options?, multiSelect?, intent? }`
(`intent: { kind: 'plan-review', approve }`); answer =
`{ answers: [{ id, selected: string[], custom? }] }`.

### Design

**The mux is the single seam — no `tool/call` sniffing.** An earlier draft
proposed detecting questions from the `session/event` hook's `tool/call`
events. Rejected, for two reasons: `tool/call` carries a `callId`, not the
apiproxy's `rpcId`, so it can never correlate an answer; and it is ephemeral,
missing questions raised before the subscriber connected, where mux replay
recovers them. Instead:

1. **Plugin subscribes to `GET /api/events.mux`** over loopback — the same
   class of `/api` coupling the plugin already accepts for `session.models` /
   `session.selectModel` (see AGENTS.md), not a new one. Apply the same
   `isSubagentChild` targetability filter the `session/event` hook uses
   (`dsh-plugin/src/index.ts:585`) so subagent-owned sessions never surface.
   The plugin holds the pending-question map keyed by `rpcId`.
2. **Plugin rebroadcasts** pending questions as a new `ask-user` SSE frame on
   the existing `/dsh-bridge/events` stream:
   `{ kind: 'ask-user', questionId, sessionId, questions }`, where
   `questionId` is the mux `rpcId`. A companion `ask-user-resolved` frame
   (from `question/resolved`) carries the outcome so Emacs can retire the
   question when it was answered elsewhere or cancelled. **The plugin replays
   its current pending asks as `ask-user` frames to each new
   `/dsh-bridge/events` client on connect**, mirroring the mux's own replay,
   so an Emacs restart or a late `dsh-bridge-notifications-start` does not
   lose a pending question.
3. **Answering** is `POST /dsh-bridge/answer` (bearer-authed, body-capped
   like every other route), which the plugin proxies to `POST /api/respond`.
   The mux subscription stays **host-side**: Emacs could technically reach
   `/api` directly, but that would spread the version-fragile apiproxy
   contract into the elisp and bypass the `/dsh-bridge` token-fence
   conventions.

**Race story:** the web UI and Emacs both see every question; first answer
wins. The loser's POST gets `{ accepted: false, reason: 'not-pending' }` —
surface that as a plain "already answered or cancelled" message, and let the
`ask-user-resolved` frame retire the question buffer (see "Lifecycle" below).

### Pending state and the status glyph

A pending question is **orthogonal** to the turn lifecycle: the session is
still `running` host-side (the turn is parked inside the tool call;
`turn-complete` has not fired). So do not add a third state to
`dsh-bridge--session-status`; keep a separate registry
`dsh-bridge--pending-questions` = `(session-id . ((question-id . questions)
...))`, maintained by the `ask-user` / `ask-user-resolved` frames and cleared
defensively on `turn-complete` (an abort settles the question as cancelled; a
missed resolved frame must not leave a stuck glyph).

Give the pending state **display precedence inside
`dsh-bridge--status-glyph`** (`dsh-bridge.el:306`): awaiting > running > idle
> unknown. Every surface already renders through that one function — the
DSH-View header (`:1664`), the DSH-Prompt header (`:1695`), and the
DSH-Sessions rows (`:2622`) — so all three buffer families light up for free.
One new glyph per `dsh-bridge-status-indicator` style (`⏳` emoji, a geometric
and a plain variant) plus a `dsh-bridge-status-awaiting-face`. The DSH-View
header additionally spells out `· awaiting your answer` in text for the shown
session, since a bare glyph is cryptic.

This also fixes today's real UX bug: a parked session currently reads as
"running", so the user waits forever on a turn that is silently waiting on
them.

### Discovery: echo + a key, no popup

A blocking question deserves more than a passive header glyph, but
auto-popping a buffer violates this plan's "messages, not popups" principle
and steals focus mid-typing. In increasing order of intrusiveness:

- **Echo on arrival, always.** Unlike the `turn-start` echo (gated on
  `dsh-bridge--user-looking-p`), an `ask-user` is rare, blocking, and
  directed at the user — message it regardless of which session is being
  viewed: `dsh-bridge: session "Label" asks: <header or first question text>`
  (truncated), ending with `('a' to answer)`.
- **`a` key in DSH-View and DSH-Sessions** ("answer"): opens the pending
  question buffer for the shown / point session, or messages "no pending
  question". It sits alongside the existing `r`/`f`/`g` keys in those keymaps
  (`dsh-bridge.el:1738-1758`) and gives keyboard discovery.
- **Auto-pop** only behind a `defcustom`, **default nil**. Some users will
  want it for plan-review; most will hate it.

The question buffer does not interact with the view's follow/cycle state: the
turn is still running, so following keeps auto-refilling; no conflict.

### The question buffer

One `ask_user_question` call carries a `questions` array, and multiple
sessions can have pending asks concurrently, so the unit is the **ask
(rpcId)**, not the question and not the session:

- One buffer per ask, named `*dsh-bridge-question: <Label>*`. Two sessions
  yield two buffers; one session cannot have two concurrent asks (the tool
  call blocks its turn).
- `dsh-bridge-question-mode` derives from **`special-mode`, not
  markdown-mode** — it is a form, not a document. Read-only buffer; `q`
  buries without answering (the question stays pending and `a` reopens, so
  "answer later" is a first-class flow).
- Buffer-locals: `dsh-bridge--question-id` (the rpcId), the session id, the
  parsed questions, per-question selection state, and a dead flag.
- **Lifecycle:** on `ask-user-resolved`, do not kill the buffer out from
  under someone mid-selection. Insert a top banner ("This question was
  answered elsewhere / cancelled"), set the dead flag, and make `C-c C-c`
  just message "question already resolved". If the buffer is not displayed
  anywhere, killing it outright is fine. A `turn-complete` for the session
  without a resolved frame (missed event) retires it the same way.

### The selection interface: marked lines, not the widget library

`wid-edit` is rejected: terminal-hostile, visually alien to the package's
text-and-keymap aesthetic, and miserable to ERT-test. Instead, the
`package-menu`-style marking pattern, rendered as plain text under
`inhibit-read-only`:

```
 Session "Label" is waiting for your answer                (question 1 of 2)

 Which approach should I take?
   [x] 1. Refactor the parser
   [ ] 2. Patch the call sites
   [ ] 3. Something else (type a custom answer)
```

- Each option line carries its option id as a text property. `RET` (or the
  option's number key) on the line **toggles** it, rewriting just the
  `[ ]`/`[x]` marker. Single-choice questions get radio behavior (selecting
  one clears the others); `multiSelect` gets checkbox behavior.
- A "custom" option (the answer schema's `custom?` field) prompts via
  minibuffer `read-string` and shows the entered text inline.
- `n`/`p` move between option lines; `TAB` jumps to the next question.
- `plan-review` intent: render the `detail` markdown above the options (raw
  markdown reads fine; no fontification in v1) plus an explicit
  `[ ] Approve plan` toggle line that sets `intent.approve`.
- `C-c C-c` validates client-side (every question answered; single-choice
  has exactly one selection; selected ⊆ options) — mirroring
  `matchesQuestions` so a malformed answer never makes the round trip — then
  POSTs `/dsh-bridge/answer` with `{ questionId, sessionId, answers }`. On
  accepted: kill the buffer, echo `answer sent to "Label"`. On
  `not-pending`: the race path above.
- `C-c C-k` **declines**: `POST /api/respond` explicitly accepts
  `{ ok: false, error: { code: "cancelled" } }` → `ASK_CANCELLED`, which is
  how the web UI's cancel works. This is the difference between "ignore the
  question" (bury; stays pending) and "tell the model I won't answer"
  (cancels the tool call).

Everything is plain-text munging in the file's existing implementation style,
and every transition is ERT-testable headless. Per the settled deferred item,
this buffer is the **only** answering path in v1 — the marked-lines design is
what makes that palatable, since even a two-option question is
`a` → `1` → `C-c C-c`.

### Version fragility

The mux/respond shapes are the apiproxy's private contract, zod-defined in
`packages/host/apiproxy/src/api/*.schema.ts`. This is the same re-verify-on-
bump discipline the repo already applies to the client-artifact contract in
`tsdown.client.config.ts`; note it in AGENTS.md's "on any version bump" list.
Before implementing, confirm the reference checkout at `../deepseek-harness/`
matches the pinned `peerDependencies` range so these shapes are current.

### Pre-flight check + host mux lifecycle (do first)

The one real risk in this section is the mux subscribe, so smoke-test it before
building the question buffer:

- Confirm the plugin can hold a **streaming GET** to
  `${webBaseUrl}/api/events.mux` with an `AbortSignal` (the existing
  `rpcCall` carrier only POSTs; the mux is a long-lived SSE read), and that the
  frames arrive as plain `data:` lines. If loopback auth unexpectedly fences
  `/api` for a raw GET, stop and re-plan rather than build the whole surface on
  an unworkable transport.
- The plugin's mux connection is **long-lived** and needs persistent reconnect
  + frame dedupe, mirroring the Emacs notifications stream
  (`dsh-bridge-notifications-start`/`-stop` and the reconnect-with-retry
  discipline). Keep a single subscription per plugin lifetime and re-subscribe
  on teardown/reconnect.

---

## Files touched

- `emacs/dsh-bridge.el`
  - `dsh-bridge--view-follow` + `dsh-bridge--view-following-p`; rework
    `dsh-bridge-view-next-reply` / `dsh-bridge-view-previous-reply` to enter /
    leave following (with anchor discard and the `M-n`-while-following
    no-op).
  - Re-set the view header in the `context` SSE handler (drop the `FIXME`).
  - Store turn-start time in the status tracker; elapsed ticker with cancel
    on `turn-complete` / buffer kill / session switch.
  - Extend `replies-changed` to refill when following.
  - `C-c C-c` → jump to the view in following state; optimistic status +
    render in `dsh-bridge-send-text`; clearer send message.
  - `erase-buffer` in `dsh-bridge--prompt-exit` (and the draft path).
  - New `defcustom`s: live ticker (default on), follow defaults, question
    behavior (auto-pop on arrival, default nil).
  - Ask-user: `ask-user` / `ask-user-resolved` frame handlers;
    `dsh-bridge--pending-questions` registry; awaiting state in
    `dsh-bridge--status-glyph` + `dsh-bridge-status-awaiting-face` (+ one
    glyph per `dsh-bridge-status-indicator` style); `a` (answer) key in the
    DSH-View and DSH-Sessions keymaps; arrival echo; `dsh-bridge-question-mode`
    with the marked-lines selection interface (toggle/radio behavior, custom
    answer via `read-string`, plan-review approve toggle, client-side
    validation, `C-c C-c` submit / `C-c C-k` decline, resolved-banner
    lifecycle); answer POST.
- `emacs/dsh-bridge-tests.el`
  - Following-state transitions (M-p exits / M-n re-enters / M-n no-op while
    following / anchor discard / auto-refill), blank-on-reply + `M-p`
    restore, optimistic status, ticker lifecycle, question buffer/answer
    round-trip: pending-glyph precedence across all three buffer families,
    option toggling (radio vs checkbox), custom-answer entry, client-side
    validation failures, decline path, the not-pending race, and the
    resolved-banner retirement.
- `dsh-plugin/src/logic.ts` + `dsh-plugin/src/index.ts`
  - `askUserMessage` / `askUserResolvedMessage` frame constructors (with doc
    comments per the AGENTS.md frame-documentation rule), mux subscription,
    pending-question map, replay of pending asks to new `/dsh-bridge/events`
    clients, `POST /dsh-bridge/answer` route (submit + decline), and new
    pure predicates for the question-frame filtering.
  - Update the route-inventory header comment in `index.ts` when routes
    change.
- `README.md`
  - Document following, blank-on-reply, live pulse, and ask-user. Add the
    answer route to "Permissions, authentication, and failure bounds" (new
    bearer-authed route; mux subscription is loopback-only, no third-party
    contact).
- `AGENTS.md`
  - Add the mux/respond wire contract to the version-bump re-verification
    list alongside the client-artifact contract.
- Version bump in all three places (the `;; Version:` header of
  `emacs/dsh-bridge.el`, the `dsh-bridge-version` defconst, and
  `dsh-plugin/package.json`) when shipping.

## Pass discipline (two passes, git checkpoint between)

Because this plan splits into the UX cleanups (items 1-4) and the ask-user
feature (item 5), keep each pass a separate git checkpoint so the second does
not depend on the first and either can be reviewed/reverted independently. The
version bump is the coupling: the Makefile refuses to build on version drift
(`;; Version:` header, `dsh-bridge-version`, `package.json` must agree), so
**bump all three sync'd strings at each shippable pass**, not mid-pass, so each
checkpoint leaves a buildable tree.

## Testing

`make build && make test` must pass. Pure plugin logic stays in `logic.ts`
(Vitest); Elisp behavior covered by ERT in `dsh-bridge-tests.el`. Tests describe
observable behavior, so each change above updates its test in the same change.

## Deferred / open decisions

None blocking. Two formerly open questions are now settled: the live elapsed
ticker ships **default-on** behind a `defcustom` (it only runs for the session
the user is looking at), and there is **no minibuffer shortcut** for
single-choice questions in v1 (revisit if usage shows single-choice
dominating). The one pre-implementation check is confirming the
`../deepseek-harness/` reference checkout matches the pinned `peerDependencies`
range so the documented mux/respond shapes are current.
