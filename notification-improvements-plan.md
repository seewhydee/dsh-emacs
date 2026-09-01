# dsh-emacs-bridge — notification improvements plan

This plan bundles the fixes for the findings (F1–F5) from the audit of the
notification channel. It is a companion to [PLAN.md](PLAN.md); it records the
*what/why/how*, not the code. All five items are implemented; the F2 optional
history re-fetch on entering from rest was left out (marked optional below).

## Background

The DSH plugin already pushes an SSE stream (`GET /dsh-bridge/events`) carrying
`turn-start`, `turn-complete` (with `reason`), `context`, `sessions-changed`,
`outbox`, and `draft` frames. Emacs subscribes via `make-network-process`, parses
chunked SSE, and dispatches in `dsh-bridge--notification-handle-events`. This
channel works: the status glyph flips green↔amber on the fly in all three bridge
buffers.

The gaps are all downstream of the **reply-list cache**
(`dsh-bridge--replies-cache`), which navigation and the `(k/n)` counter read but
never refresh, plus three smaller display staleness issues.

## Findings at a glance

| # | Finding | Fix |
|---|---------|-----|
| F1 | Reply-list cache goes stale; `M-n`/`M-p` and the `(k/n)` counter are bounded by it | Re-fetch at the navigation boundary; decouple cache refresh from buffer refill |
| F2 | The `(k/n)` position lives in DSH-View only; DSH-Prompt history walk shows no position | Add a prompt-history position indicator |
| F3 | `geometric` indicator renders idle and running as the same glyph (`●`/`●`) | Distinct running glyph (●/■/?) |
| F4 | Sessions-list Age column and sort order stay stale on turn boundaries | Carry `time` in turn frames; update `lastActive` and re-sort |
| F5 | `message` turn-complete skips the sessions buffer; prompt header repaint relies on the next redisplay | Extend "looking" scope; `force-mode-line-update` |

## Goals

- Make reply navigation honest at the newest boundary: pressing `M-n` at the
  newest reply must discover a newer reply the host has produced since the last
  fetch.
- Keep the `(k/n)` denominator current without a full re-fetch on every redisplay.
- Give the prompt-history walk the same position feedback the reply walk has.
- Make a running↔idle transition visually unambiguous under every indicator style.
- Make the sessions list's recency live, not just its glyph.

## Non-goals

- No streaming of assistant text into Emacs (unchanged: that remains DSH's job).
- No full-transcript buffer (deferred; see [PLAN.md](PLAN.md) § Deferred).
- No change to the auth/failure bounds (loopback, token, 1 MiB cap, outbox cap).
- No host-side "target pin"; session resolution semantics are untouched.
- The `context` frame's dependence on the optional `sessionProjections` service
  is a documented capability dependency, not a bug; not addressed here.

## Work items

### F1 — Reply-list freshness at the navigation boundary

**Problem.** `dsh-bridge--view-replies-refresh` only fetches `GET /replies` when
`force` is set, the session changed, or the cache is empty. `M-n`
(`dsh-bridge-view-next-reply`) and `M-p` (`dsh-bridge-view-previous-reply`) call
it without `force`, so once a session's reply list is cached, navigation is
bounded by that snapshot forever. `dsh-bridge--view-reply-position` computes the
`(k/n)` string from the same cache, so it is stale too. The `turn-complete`
`refetch` path force-refreshes, but only when the view shows that session *and*
the user is not mid-cycling (`dsh-bridge--view-cycling-p` guard).

**Behavior after change.**

- `M-n` at rest (no reply index): force-refresh the reply list. If the shown
  text is still the newest reply (or is not found), report "no newer replies";
  otherwise adopt the current text as the navigation anchor and step one newer
  (mirroring `M-p`'s first-step anchoring in reverse). This makes `M-n` at the
  newest boundary a "check for new" affordance.
- `M-n` at index 0: unchanged — restore the anchor and return to rest.
- `M-n` at index > 0: unchanged — step one newer within the cached list (no
  refresh mid-walk; freshness comes from the boundary refreshes above).
- `M-p` on first step (entering navigation from rest): force-refresh once so the
  anchor lookup and the `(k/n)` denominator are current; subsequent steps reuse
  the cache.
- On `turn-complete`, refresh the reply *cache* entry for the frame's session
  (which need not be the shown one) regardless of cycling, so `n` stays current
  while browsing. Update only the `dsh-bridge--replies-cache` alist — do not
  route through `dsh-bridge--fill-output-from-text`, which resets the reply
  index and anchor. Keep the buffer *refill* gated on "shown and not cycling"
  so a mid-browse view is never clobbered.

**Implementation notes.** All changes are Emacs-side in `emacs/dsh-bridge.el`;
the `/replies` endpoint already exists. The boundary decision (given the shown
text and a fresh reply list, what index to show next) should be factored into a
small pure helper so it is ERT-testable without HTTP. When the cache refresh
lands while the user is cycling that same session, new replies arrive at the
head and shift every index: adjust `dsh-bridge--view-replies-index` by the head
delta (the list-length difference) so the shown reply and the `(k/n)` counter
stay aligned. Keep the refresh calls
deferred (`run-at-time 0 …`) where they run inside the SSE filter, matching the
existing re-entrancy discipline in `dsh-bridge--notification-filter`.

**Tests.** ERT in `emacs/dsh-bridge-tests.el` for the pure boundary helper:
(shown-text at index 0 → nil; at index k>0 → k-1; not found → nil). A
turn-complete refresh that must not clobber a cycling buffer is covered by the
existing behavior plus a unit test on the new decision helper.

**Acceptance.** With a stale cache, pressing `M-n` at the newest reply reveals a
newer reply the host produced; the header `(k/n)` reflects the refreshed count.

### F2 — Prompt-history position indicator

**Problem.** The prompt buffer's `M-p`/`M-n` walk walks
`dsh-bridge--prompt-history` and tracks `dsh-bridge--prompt-history-index`,
but never displays a position. The header is
`<status> <label>[ · <model>][ · <ctx%>][ ✓ sent HH:MM]` with no counter.

**Behavior after change.** When `dsh-bridge--prompt-history-index` is non-nil,
append a ` (k/n)` segment to `dsh-bridge--prompt-header-line`, newest-first and
1-indexed (k = 1 + index), exactly like the View buffer's reply-position
segment. At rest (index nil) no segment is shown. Optionally, entering history
from rest refreshes the history list once (`dsh-bridge--prompt-history-refresh`
already fetches on first use; make that first use also re-fetch when the cached
list may predate a web-UI send) so the denominator is current.

**Implementation notes.** Emacs-side only. Reuse the existing
`(:eval …)` header; the segment falls out of
`dsh-bridge--prompt-header-line` by reading the buffer-local index and
`(length (dsh-bridge--prompt-history-list))`. Update the format comment in
that function's docstring to include the new `[ (k/n)]` segment.

**Tests.** ERT: bind the prompt-buffer locals, set a history list and index, and
assert the header string contains `(2/5)`-style text; assert no segment when
the index is nil.

**Acceptance.** Walking prompt history in DSH-Prompt shows `(k/n)` that tracks
`M-p`/`M-n` and disappears at rest.

### F3 — Distinct geometric running glyph

**Problem.** `dsh-bridge--status-glyph` maps `geometric` as `idle → "●"` and
`running → "●"` — identical glyphs, differing only by face color. This
contradicts the `dsh-bridge-status-indicator` docstring (`●/■/?`) and makes the
on-the-fly running↔idle change invisible to glyph-shape (or monochrome) users.

**Behavior after change.** Make the geometric running glyph `■` (idle stays
`●`, unknown `?`). The `dsh-bridge-status-indicator` docstring already
documents `●/■/?` — only the code diverges, so no docstring change is needed.
The sessions-list status column width
(1 for geometric, 2 for emoji) already accommodates single-width glyphs.

**Implementation notes.** One-line change in `dsh-bridge--status-glyph`. Verify
the `:set` re-render path (`dsh-bridge--refresh-status-display`) already covers
indicator-style changes; it does.

**Tests.** ERT: under `dsh-bridge-status-indicator` = `geometric`, assert the
glyph for a running live session differs from the glyph for an idle live session
(bind `dsh-bridge--session-status` and a minimal `dsh-bridge--sessions-cache`
row).

**Acceptance.** A running↔idle transition changes the geometric glyph shape,
not just its color.

### F4 — Live age/sort in the sessions list

**Problem.** `dsh-bridge--status-reprint-row` recomputes the row but the Age cell
reads `lastActive`/`createdAt` from the cached session data, which turn frames
never update, and the list does not re-sort. The host does not emit
`sessions-changed` on turn boundaries.

**Behavior after change.** Include the event's `time` (ms-epoch, already
available as `SessionEventLike.time` on the host) in the `turn-start` and
`turn-complete` SSE frames. On the Emacs side, update that session's
`lastActive` in `dsh-bridge--sessions-cache` from the frame and re-sort/re-print
the sessions list on `turn-complete` (turn start keeps glyph-only so a row does
not jump mid-turn). Tolerate a missing `time` (older plugin) by leaving
`lastActive` unchanged.

**Implementation notes.** Host: extend `turnStartMessage`/`turnCompleteMessage`
in `dsh-plugin/src/logic.ts` to carry `time`, and pass `event.time` from the
`ctx.on('session/event', …)` emitter in `dsh-plugin/src/index.ts`. Emacs: extend
the `turn-start`/`turn-complete` branches in
`dsh-bridge--notification-handle-events` to update `lastActive`, then re-print
via `dsh-bridge--status-reprint-row`. The re-sort comes free:
`tabulated-list-print` re-sorts whenever `tabulated-list-sort-key` is set
(here `("Age" . t)` — the flip makes the ascending-timestamp sorter display
newest first, i.e. ascending age); pass REMEMBER-POS so point follows the
session id when the row moves, matching the full-refresh path. Alternative
considered and rejected: emitting `sessions-changed` on every turn end — simpler
but forces a full `/sessions` refetch per turn and re-seeds the tracker
unnecessarily.

**Tests.** Vitest: `turnStartMessage`/`turnCompleteMessage` serialize `time`
into the frame JSON. ERT: a helper that applies a turn frame's `time` to the
cache updates `lastActive` and leaves it unchanged when `time` is absent.

**Acceptance.** After a session's turn ends, its Age cell refreshes and the row
moves to reflect the new recency without a manual `g`.

### F5 — Prompt-header repaint and turn-complete message scope

**Problem.** (a) The prompt header is `(:eval …)` and repaints on the next
redisplay, lagging the immediately-recomputed View header and reprinted sessions
row. (b) `dsh-bridge--user-looking-p` covers View and Prompt only, so the
`message` variant of `dsh-bridge-turn-complete` never notifies a user watching
the sessions list.

**Behavior after change.** (a) After a status/context update, call
`force-mode-line-update` for the prompt buffer so its header paints in the same
tick as the other surfaces. (b) Optionally, treat the sessions buffer as
"looking at" the session under point (via `tabulated-list-get-id`) so a
list-watcher gets the turn-complete echo for the row they are on; keep this
lower priority, as the glyph already carries the primary signal there.

**Implementation notes.** Emacs-side only. (a) is a two-line change in
`dsh-bridge--status-event-render` and the `context` frame branch — note that
`dsh-bridge--status-event-render`'s docstring currently asserts the prompt
buffer "needs no explicit re-render here"; update it with the change. (b) extends
`dsh-bridge--user-looking-p` with a sessions-buffer arm; it should be kept
narrow (row-at-point, not any visible list) to avoid chatty echoes.

**Tests.** ERT: `dsh-bridge--user-looking-p` (if extended) returns true for the
session under point in a live sessions buffer and false otherwise. (a) has no
behavioral unit test; it is a repaint optimization.

**Acceptance.** The prompt header updates without a perceptible delay, and
`message`-mode users watching the sessions list hear about the completing
session they are pointed at.

## Wire-format changes (host)

Only F4 touches the wire. The `turn-start`/`turn-complete` frames gain a `time`
field (ms-epoch). Emacs treats it as optional, so a new Emacs side keeps working
with an older plugin. No route, auth, or failure-bound change. The frame
payloads are documented in the doc comments on `turnStartMessage` /
`turnCompleteMessage` in `dsh-plugin/src/logic.ts`; update those to mention
`time`. (The header comment of `dsh-plugin/src/index.ts` inventories routes
only — there is no frame list there to update.)

## Ordering

1. F3 — one-line, self-contained, unblocks confidence in the indicator.
2. F1 — the load-bearing fix; lands with the pure boundary helper and its ERT.
3. F2 — small, Emacs-only, mirrors F1's position display.
4. F4 — small host frame change + Emacs cache update; re-verify the client
   bundle still builds (`make build`).
5. F5 — cosmetic/optional; land last or fold into whichever change touches
   `dsh-bridge--status-event-render`.

Each change is complete when `make build && make test` passes, per
[AGENTS.md](AGENTS.md).

## Open questions

- F1: when several new replies have arrived, should `M-n` at rest step one at a
  time (proposed) or jump straight to the newest? Stepping is chosen for
  consistency with the existing step semantics; confirm.
- F1: on a mid-cycling cache refresh, shift `dsh-bridge--view-replies-index` by
  the head delta (proposed) or accept a transient off-by-one until the walk
  ends? Shifting keeps `(k/n)` honest; confirm.
- F4: is ms-epoch `time` on turn frames sufficient for the Age cell, or should
  the host also emit `sessions-changed` on turn end for exact parity with its own
  `lastActive` fold? The frame `time` is a faithful proxy (it *is* the event the
  host folds); confirm no need for the extra refetch.
- F5(b): include the sessions-buffer row-at-point in `message` scope, or leave
  `message` to View/Prompt and rely on the glyph for list-watchers?

## References

- `emacs/dsh-bridge.el` — `dsh-bridge--view-replies-refresh`,
  `dsh-bridge-view-next-reply`, `dsh-bridge-view-previous-reply`,
  `dsh-bridge--view-reply-position`, `dsh-bridge--fill-output-from-text`,
  `dsh-bridge--turn-complete-act`, `dsh-bridge--turn-complete-refetch`,
  `dsh-bridge--prompt-header-line`,
  `dsh-bridge--prompt-history-*`, `dsh-bridge--status-glyph`,
  `dsh-bridge--status-event-render`, `dsh-bridge--status-reprint-row`,
  `dsh-bridge--session-entry`, `dsh-bridge--age-sorter`,
  `dsh-bridge--user-looking-p`, `dsh-bridge--notification-handle-events`.
- `dsh-plugin/src/index.ts` — `ctx.on('session/event')` emitter, route inventory.
- `dsh-plugin/src/logic.ts` — `turnStartMessage`, `turnCompleteMessage`.
- `emacs/dsh-bridge-tests.el`, `dsh-plugin/tests/logic.spec.ts` — test surfaces.
- [README.md](README.md), [PLAN.md](PLAN.md), [AGENTS.md](AGENTS.md).
