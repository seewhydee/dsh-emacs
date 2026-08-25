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
pnpm dsh plugin --profile web add link:/absolute/path/to/dsh-emacs/dsh-plugin
pnpm dsh web
```

The `link:` path above should be the directory you invoke `dsh` from.

## Install the Emacs package

```elisp
(add-to-list 'load-path "/path/to/dsh-emacs/emacs")
(require 'dsh-bridge) ; Or use `load`
```

## Authentication

Every `/dsh-bridge` route requires a shared bearer token stored at
`~/.dsh/dsh-bridge-token` and generated on first use.  Emacs reads
this file directly, while the browser plugin fetches it from the
loopback-only `GET /dsh-bridge/token` route (peer- and origin-fenced).

## Usage

From Emacs:

- `M-x dsh-bridge` — open the dispatcher.  Its header shows the
  current target session and its letter keys map to the verbs below.
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

You may wish to give the dispatcher to a global keybinding, e.g.

```elisp
(keymap-global-set "C-c d" #'dsh-bridge)
```

## License

GPLv3 or later.  See [COPYING](COPYING).
