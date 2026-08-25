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
  Emacs via `M-x dsh-bridge-pull-inbox`;
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

- `M-x dsh-bridge-send-region` — send the selected region to DSH as a prompt.
- `M-x dsh-bridge-send-buffer` — send the whole buffer.
- `M-x dsh-bridge-send-draft-region` / `M-x dsh-bridge-send-draft-buffer` —
  push the region/buffer into the DSH composer as a *draft*: the text lands in
  the composer's text box for review but is not submitted (`send` submits
  immediately).  Requires the DSH web UI to be open in a browser with the
  target session loaded; the draft goes to the bridge's target session
  (selected or last-active), and a 409 is reported when no browser client is
  connected at all.
- `M-x dsh-bridge-pull-inbox` — pull messages sent from DSH (e.g. via the
  "Send to Emacs" button on assistant messages in the web UI) into
  `*dsh-bridge-inbox*`.
- `M-x dsh-bridge-get-output` — fetch the latest DSH assistant reply into
  `*dsh-bridge-output*`.
- `M-x dsh-bridge-list-sessions` — browse live and saved DSH sessions in a
  `*dsh-bridge-sessions*` buffer; `RET` selects the session under point.
- `M-x dsh-bridge-select-session` — choose the target session (live sessions
  only; choose `(last-active)` to unpin).
- `M-x dsh-bridge-current-session` — show (and re-sync) the current target.

Sends and output fetches go to the selected session, or to the most recently
active session when none is selected.

## License

GPLv3 or later.  See [COPYING](COPYING).
