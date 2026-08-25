# dsh-emacs

A two-way bridge between an Emacs session and a running
[Deepseek Harness](https://github.com/deepseek-ai/deepseek-harness) session.

This bridge moves text from Emacs to Deepseek Harness, and vice versa,
over loopback HTTP.  This allows you to type in Emacs and read DSH's
replies without window-switching and copy-paste.

Unlike [agent-shell](https://github.com/xenodium/agent-shell) and
[gptel](https://gptel.org/), we don't stream voluminous LLM outputs
directly into Emacs.  That is handled by Deepseek Harness; Emacs (or
`emacsclient`) pulls data in or out of Deepseek Harness as necessary.

## Components

- `dsh-plugin/` — `dsh-emacs-bridge`, a **dual-face** DeepSeek Harness plugin:
  - a **host bundle** (Cordis id `dsh-bridge`) that registers the loopback HTTP
    routes under `/dsh-bridge/`;
  - a **`dsh.client` browser plugin** (web) that adds the "Send to Emacs"
    button to assistant messages and applies composer drafts.
- `emacs/dsh-bridge.el` — an Emacs package connecting to that route.

## Status

Working prototype.  It supports:

- sending a region or buffer to DSH as a prompt;
- pushing a region/buffer into the DSH composer as a *draft* (review before
  submit);
- fetching the latest assistant reply into an Emacs buffer;
- a "Send to Emacs" button on assistant messages in the web UI, pulled into
  Emacs via `M-x dsh-bridge-inbox`;
- listing live and persisted DSH sessions, and choosing which live session the
  bridge targets (with a per-call override).

Everything else — a `/emacs` edit command, resuming persisted sessions, live
streaming, per-session transcript buffers — is a later phase.  By default the
bridge targets the most recently active DSH session.  The scope-reducing
decisions and the roadmap live in [PLAN.md](PLAN.md).

## Requirements

- A running `dsh` (the `web` profile).
- Node.js and `pnpm` to build the plugin.
- Emacs 29 or later for the Emacs package.

## Build the plugin

The plugin ships as ESM JavaScript built by
[tsdown](https://tsdown.dev/):

```sh
cd dsh-plugin
pnpm install   # first time only
pnpm build     # emits lib/index.js (host) + lib/client.js (browser)
```

Note: with the dev setup where `dsh-plugin/node_modules` is a symlink into
the harness checkout, `pnpm build` may abort with "Aborted removal of modules
directory due to no TTY" — pnpm wants to purge the symlinked modules before
running scripts.  Invoke the builders directly instead (both halves):

```sh
./node_modules/.bin/tsdown && ./node_modules/.bin/tsdown --config tsdown.client.config.ts
```

## Install the plugin into dsh

The plugin is a dsh *bundle*: it declares `dsh.bundle` and inserts one row into
the composition.  Install it into the `web` profile with a filesystem link, then
restart `dsh web` so the profile reloads its bundle set:

How you invoke `dsh` depends on how it is installed.  A global install puts a
`dsh` binary on PATH.  A source checkout has no such binary, so you run it as a
pnpm script (`pnpm dsh web`, i.e. `node --import tsx/esm apps/cli/src/bin.ts`)
from the harness directory.

The `link:` path resolves relative to the directory you invoke `dsh` from.
Running `pnpm dsh` sets that directory to the harness checkout, so the
repo-root-relative `./dsh-plugin` form only works with a global `dsh` binary on
PATH, invoked from this repo root.  Use the form that matches your setup:

```sh
# global install, from this repo root:
dsh plugin --profile web add link:./dsh-plugin
dsh web

# source checkout, from the harness directory (absolute path):
pnpm dsh plugin --profile web add link:/absolute/path/to/dsh-emacs/dsh-plugin
pnpm dsh web
```

Confirm the row composed:

```sh
dsh web --dump-config | grep -A2 dsh-bridge          # global install
pnpm dsh web --dump-config | grep -A2 dsh-bridge     # source checkout
```

## Install the Emacs package

```elisp
(add-to-list 'load-path "/path/to/dsh-emacs/emacs")
(require 'dsh-bridge)
```

Set `dsh-bridge-url` if your `dsh web` binds a non-default port (default
`http://127.0.0.1:3080/dsh-bridge`).

## Authentication

Every `/dsh-bridge` route requires a shared bearer token.  The plugin keeps it
at `~/.dsh/dsh-bridge-token` (or `$DSH_HOME/dsh-bridge-token`) and generates it
on first use.  Emacs reads that same file; the browser plugin fetches it
automatically from the loopback-only `GET /dsh-bridge/token` route (peer- and
origin-fenced), so there is no manual pairing step.

## Usage

From Emacs:

- `M-x dsh-bridge` — open the dispatcher, the single entry point.  Its header
  shows the current target session and its letter keys map to the verbs
  below.
- `M-x dsh-bridge-send` — send the region, or the whole buffer (confirmed
  first), to DSH as a prompt.
- `M-x dsh-bridge-draft` — same region-or-buffer, pushed into the DSH
  composer as a *draft*: the text lands in the composer's text box for review
  but is not submitted (`send` submits immediately).  Requires the DSH web UI
  to be open in a browser with the target session loaded; the draft goes to
  the bridge's target session (selected or last-active), and a 409 is
  reported when no browser client is connected at all.
- `M-x dsh-bridge-prompt` — pop to the persistent prompt-editing buffer, the
  compose half of the loop; `C-c C-c` sends, `C-c C-d` drafts, `C-c C-k`
  erases, and the text survives sends for edit-and-resubmit.
- `M-x dsh-bridge-fetch` — fetch the latest DSH assistant reply into
  `*dsh-bridge-output*`.
- `M-x dsh-bridge-inbox` — pull messages sent from DSH (e.g. via the
  "Send to Emacs" button on assistant messages in the web UI) into
  `*dsh-bridge-inbox*`.
- `M-x dsh-bridge-list-sessions` — browse live and saved DSH sessions in a
  `*dsh-bridge-sessions*` buffer, sorted by last activity.  `RET` pins the
  session under point (live only), `u` unpins, `p` pins and opens the prompt
  buffer, `f` peeks the session's latest reply without changing the pin.
- `M-x dsh-bridge-select-session` — choose the target session (live sessions
  only; choose `(last-active)` to unpin).

Sends and output fetches go to the selected session, or to the most recently
active session when none is selected.  A prefix argument to `send`/`draft`/
`fetch` chooses the target session for that call only, without changing the
pin.  The `*dsh-bridge-output*` and `*dsh-bridge-inbox*` buffers are
read-only and bind the dispatcher's letters (`s`/`d`/`f`/`i`/`S`/`l`) plus
`g` to refresh and `q` to dismiss.

The pre-interface command names (`dsh-bridge-send-region`,
`dsh-bridge-send-buffer`, `dsh-bridge-send-draft-region`,
`dsh-bridge-send-draft-buffer`, `dsh-bridge-get-output`,
`dsh-bridge-pull-inbox`) remain as obsolete aliases of the verbs above.

No global keybinding is set by default (`C-c <letter>` is reserved for
users); bind the dispatcher yourself, e.g.

```elisp
(keymap-global-set "C-c d" #'dsh-bridge)
```

The Tools → DSH Bridge menu provides key-free access.

## License

GPLv3 or later.  See [COPYING](COPYING).
