# dsh-emacs-bridge

A two-way bridge between [Emacs](https://www.gnu.org/software/emacs/)
and a [Deepseek Harness](https://github.com/deepseek-ai/deepseek-harness) 
session.  The bridge moves text from Emacs to DeepSeek Harness, and
vice versa, over loopback HTTP.  This lets you type in Emacs and read
DSH's replies without copy-pasting, while also avoiding streaming
voluminous LLM outputs through Emacs.

Currently in working protoype stage.

## Components

- `dsh-plugin/` — `dsh-emacs-bridge`, a dual-face DeepSeek Harness plugin
  consisting of:
  - a host bundle (Cordis id `dsh-bridge`) that registers the loopback HTTP
    routes under `/dsh-bridge/`;
  - a `dsh.client` browser plugin that adds the "Send to Emacs" button
    to assistant messages and applies composer drafts.
- `emacs/dsh-bridge.el` — an Emacs package supplying commands to
  interact with DeepSeek Harness via the HTTP route.

## Requirements

- A running `dsh` (the `web` profile).
- Node.js and `pnpm` to build the plugin.
- Emacs 29 or later.
- (Recommended) The [`markdown-mode`](https://jblevins.org/projects/markdown-mode/) Emacs package.

## Build the plugin

The plugin ships as ESM JavaScript built by
[tsdown](https://tsdown.dev/):

```sh
cd dsh-plugin
pnpm install   # first time only
pnpm build     # emits lib/index.js (host) + lib/client.js (browser)
```

Note: with a dev setup where `dsh-plugin/node_modules` is a symlink to
the harness checkout, `pnpm build` may abort with “Aborted removal of
modules directory due to no TTY”.  In that case, invoke the builders
directly:

```sh
./node_modules/.bin/tsdown && ./node_modules/.bin/tsdown --config tsdown.client.config.ts
```

## Install the DeepSeek Harness plugin

The plugin is a dsh bundle.  How you install it depends on how your
DeepSeek Harness is installed.

If you have a global install putting a `dsh` binary on PATH:

```sh
# global install, from this repo root:
dsh plugin --profile web add link:./dsh-plugin
dsh web
```

If you have a source checkout of DeepSeek Harness and run it as a pnpm
script (`pnpm dsh web`):

```sh
# source checkout, from the harness directory (absolute path):
pnpm dsh plugin --profile web add link:/absolute/path/to/dsh-emacs-bridge/dsh-plugin
pnpm dsh web
```

The `link:` path above should be the directory you invoke `dsh` from.

## Install the Emacs package

Put this in your Emacs init file (`~/.emacs.d/init.el` or `~/.emacs`),
replacing the path with the actual path to `dsh-bridge.el`.

```elisp
(load "/path/to/dsh-emacs-bridge/emacs/dsh-bridge.el")
```

## Authentication

Every `/dsh-bridge` route requires a shared bearer token stored at
`~/.dsh/dsh-bridge-token` and generated on first use.  Emacs reads
this file directly, while the browser plugin fetches it from the
loopback-only `GET /dsh-bridge/token` route (peer- and origin-fenced).

## Usage

From Emacs:

- `M-x dsh-bridge` — open the dispatcher.  Its header shows the *effective
  session* of the buffer it was invoked from, and its letter keys map to the
  verbs below (grouped into Compose / Read / Sessions).
- `M-x dsh-bridge-send` — send the region, or the whole buffer (confirmed
  first), to DSH as a prompt.
- `M-x dsh-bridge-draft` — same region-or-buffer, pushed into the DSH
  composer as a *draft*: the text lands in the composer's text box for review
  but is not submitted (`send` submits immediately).  Requires the DSH web UI
  to be open in a browser with the target session loaded; the draft goes to
  the bridge's effective session, and a 409 is reported when no browser
  client is connected at all.
- `M-x dsh-bridge-prompt` — pop to the persistent prompt-editing buffer, the
  compose half of the loop; `C-c C-c` sends, `C-c C-d` drafts, `C-c C-k`
  erases, `C-c C-f` fetches the session's latest reply (closing the loop),
  `C-c C-s` rebinds this buffer's session, `C-c C-l` lists sessions, and the
  text survives sends for edit-and-resubmit.  `M-p`/`M-n` walk the session's
  prompt history, recalling earlier prompts (the current draft is restored by
  `M-n` at the newest prompt).  The buffer's `default-directory` follows its
  effective session's workspace.
- `M-x dsh-bridge-fetch` — fetch the latest DSH assistant reply into
  `*dsh-bridge-output*`.  The buffer's `default-directory` is set to the
  workspace of the session the reply came from.
- `M-x dsh-bridge-receive` — receive the latest "Send to Emacs" message (from
  the button on assistant messages in the web UI) into `*dsh-bridge-output*`,
  without popping the buffer.  This is the manual fallback for the
  notifications-off case; the SSE listener calls it automatically otherwise.
- `M-x dsh-bridge-list-sessions` — browse DSH sessions in a
  `*dsh-bridge-sessions*` buffer, sorted by age; shows a default-target
  marker column (`*` for the default target), a running-marker column
  (`…` while a session's model is working), the session name, its age, and
  its workspace.  All non-archived sessions (live and saved) are listed by
  default; `v` cycles the display mode (`live+saved` → `live` →
  `live+saved+archived`).  `RET`/`r` open the session under point (binds the
  prompt buffer to it; the default target is untouched), `t` sets the default
  target (live only), `u` clears it, `f` peeks the session's latest reply
  without changing anything, `w` copies the session id, `D` shows session
  details, `g` re-fetches and `S` sorts.
- `M-x dsh-bridge-set-default-target` — set the bridge-wide default target
  (live sessions only; choose `(last-active)` to clear it).  Setting the
  default target is Emacs-local: there is no host-side pin anymore.

### Targeting: the effective session

Every verb acts on the **effective session** of the buffer it runs in:

1. the buffer's own session, if it has one — the prompt buffer's binding, or
   the reply shown in the output buffer;
2. else the bridge-wide **default target** (`dsh-bridge-default-session`);
3. else the host's **last-active** session.

So **opening a session is not the same as setting the default target**:
`RET`/`r` in the session list (or `r` in the output buffer) binds the *prompt
buffer* to that session — its header shows `session: <name>` — without
changing what context-free sends from other buffers use.  To make a session
the target of context-free operations, set the default target explicitly
(`t` in the list, `t` in the dispatcher, or `M-x
dsh-bridge-set-default-target`); headers then show `<name> (default)`.
When nothing is bound, headers show the resolved last-active session with
`(last-active)`.

A prefix argument to `send`/`draft`/`fetch` chooses a session for that call
only, overriding everything above.

### DSH→Emacs text: fetch and receive

`*dsh-bridge-output*` holds the assistant text Emacs currently has for a
session, however it arrived — a `fetch` (pull, the latest reply) or a
"Send to Emacs" push from the web UI (a specific message).  The header says
`reply from: <session> · refreshed <time>` for a fetch and
`received from: <session> · sent <time>` for a push (the message's own send
time).  There is no inbox: the delivery queue is invisible plumbing, and
`r`/`w` in the output buffer act on the shown session's text either way.

### The buffers at a glance

| Buffer / mode | Keys |
|---|---|
| Dispatcher (`M-x dsh-bridge`) | `p` prompt · `s` send · `d` draft · `f` fetch · `t` set default target · `u` clear · `l` list sessions · `q` quit |
| `*dsh-bridge-sessions*` | `RET`/`r` open session · `t` set default target · `u` clear · `f` peek · `v` display mode · `w` copy id · `D` details · `g` refresh · `S` sort · `n`/`p` line motion |
| `*dsh-bridge-output*` | `g` re-fetch the shown reply · `r` reply (bind prompt to the shown session) · `w` copy · `l` list sessions · `q` dismiss |
| `*dsh-bridge-prompt*` | `C-c C-c` send · `C-c C-d` draft · `C-c C-k` erase · `C-c C-f` fetch · `C-c C-s` set buffer session · `C-c C-l` list · `M-p`/`M-n` history |

The output buffer is read-only and its keymap is identical with and without
`markdown-mode`; when markdown-mode is installed (and `dsh-bridge-view-gfm`
is non-nil), replies are additionally font-locked as GitHub-Flavored Markdown
(including native highlighting of fenced code blocks).  `g` is the output
buffer's fetch: `f` elsewhere produces a reply into this buffer, so inside it
the two coincide.

With `dsh-bridge-notifications` non-nil (the default), Emacs subscribes to the
bridge's event stream (starting lazily on first use) and automatically fills
`*dsh-bridge-output*` with new "Send to Emacs" messages as they arrive —
without popping the buffer, so an unsolicited push never steals focus.
`dsh-bridge-notifications-start` / `dsh-bridge-notifications-stop` control the
listener.

### Renames (0.1 → 0.2, breaking)

The pin and inbox vocabularies are gone; commands and variables are renamed
outright (no obsolete aliases), so update any init-file bindings:

| Old | New |
|---|---|
| `dsh-bridge-target-session` | `dsh-bridge-default-session` |
| `dsh-bridge-select-session` | `dsh-bridge-set-default-target` |
| `dsh-bridge-unpin-session` | `dsh-bridge-clear-default-target` |
| `dsh-bridge-select-session-at-point` | `dsh-bridge-open-session` (semantics changed: binds the prompt buffer, no retarget) |
| `dsh-bridge-current-session` | removed (the dispatcher header shows the target) |
| `dsh-bridge-inbox` | `dsh-bridge-receive` (no `*dsh-bridge-inbox*` buffer; pushes land in `*dsh-bridge-output*`) |

You may wish to give the dispatcher to a global keybinding, e.g.

```elisp
(keymap-global-set "C-c d" #'dsh-bridge)
```

## License

GPLv3 or later.  See [COPYING](COPYING).
