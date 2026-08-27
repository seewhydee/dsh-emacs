# dsh-emacs-bridge

This is a two-way bridge between [Emacs](https://www.gnu.org/software/emacs/)
and a [Deepseek Harness](https://github.com/deepseek-ai/deepseek-harness) 
session.  The bridge moves text from Emacs to DeepSeek Harness (DSH),
and vice versa, over loopback HTTP.  This lets you type in Emacs and
read DSH's replies without copy-pasting, while also avoiding streaming
voluminous LLM outputs through Emacs.

It consists of two components:

- `dsh-plugin/` — a DeepSeek Harness plugin (`dsh-emacs-bridge`).
- `emacs/dsh-bridge.el` — an Emacs package to interact with the harness.

## Installation

### Requirements

- A running `dsh` (currently the `web` profile is supported).
- Node.js and `pnpm` to build the plugin.
- Emacs 29 or later.
- (Recommended) The [`markdown-mode`](https://jblevins.org/projects/markdown-mode/) Emacs package.

### Build the plugin

From this repository's root directory:

```sh
cd dsh-plugin
pnpm install   # first time only
pnpm build     # emits lib/index.js (host) + lib/client.js (browser)
```

Note: if you have a dev setup where `dsh-plugin/node_modules` is a
symlink to the harness checkout, and `pnpm build` aborts with “Aborted
removal of modules directory due to no TTY”, invoke the builders
directly:

```sh
./node_modules/.bin/tsdown && ./node_modules/.bin/tsdown --config tsdown.client.config.ts
```

### Install the DeepSeek Harness plugin

How you install the plugin depends on how DSH was installed.  If you
have a global install with `dsh` on PATH:

```sh
# global install, from this repo root:
dsh plugin --profile web add link:./dsh-plugin
dsh web
```

If you have a source checkout of DSH and run it as a pnpm script
(`pnpm dsh web`), do the following (replace the `link:` path below
with the appropriate path into this repo):

```sh
# source checkout, from deepseek-harness root:
pnpm dsh plugin --profile web add link:/absolute/path/to/dsh-emacs-bridge/dsh-plugin
pnpm dsh web
```

### Install the Emacs package

Put this in your Emacs init file (`~/.emacs.d/init.el` or `~/.emacs`),
replacing the path with the actual path to `dsh-bridge.el`.

```elisp
(load "/path/to/dsh-emacs-bridge/emacs/dsh-bridge.el")
```

Alternatively, copy `dsh-bridge.el` into your Emacs load-path and do
`(require 'dsh-bridge)`.

## Usage

From Emacs, the main entry-points are these two commands:

- `M-x dsh-bridge` — open a transient menu for DSH commands.
- `M-x dsh-bridge-list-sessions` — show a list of DSH sessions.

Consider giving either of these a global keybinding, e.g.,

```elisp
(keymap-global-set "C-c d" #'dsh-bridge)
```

### Transient menu

The `M-x dsh-bridge` command opens a transient menu that prompts for
the next command.  The top line shows the session your next command
will act on: the buffer's own session when the dispatcher is invoked
from a DSH-View or DSH-Prompt buffer, otherwise the **default target**
session if one is set, otherwise the **last-active** session.

The following commands are available from the transient menu:

* `q` — exit the transient menu.
* `r` — open a DSH-Prompt buffer for the session.
* `s` — send the region or buffer as a prompt.
* `d` — send the region or buffer as a draft (can
        still edit in DSH composer before submitting).
* `f` — fetch the session's latest reply into the DSH-View buffer.
* `t` — set the default target session.
* `u` — clear the default target session.
* `l` — open the DSH-Sessions buffer.

### Sessions menu

The `M-x dsh-bridge-list-sessions` command opens a buffer with a list
of DSH sessions.  The default target session (if any) is marked by a
`*` in the leftmost column.

The following commands are available from the DSH-Sessions buffer:

* `q` — quit the window and bury the buffer.
* `f` — fetch the last output for the session at point into a DSH-View buffer.
* `r` or `RET` — open a DSH-Prompt buffer for the session at point.
* `t` — set the session at point as the default target.
* `u` — clear the default target.
* `v` — cycle session display between `live+saved` (default), `live`, and
        `live+saved+archived`.
* `g` — refresh the DSH-Sessions buffer.

For a full list, see the menu bar.  Other `tabulated-list-mode` keys
are also available.

### DSH-View buffer

This read-only buffer contains the model output for a DSH session.  It
is fetched by `f` from the transient menu or the DSH-Sessions buffer,
`C-c C-f` from the DSH-Prompt buffer, or pushed from the web UI's
"Send to Emacs" button (see below).  The session is displayed on the
header line.

The following commands are available:

* `g` — re-fetch the current session's latest reply.
* `r` — open a DSH-Prompt buffer for the current session.
* `w` — copy the reply (region, else the whole buffer) to the kill ring.
* `i` — receive the latest "Send to Emacs" message (see below).
* `M-p`/`M-n` — cycle the current session's assistant replies.
* `l` — open the DSH-Sessions buffer.
* `q` — quit the window and bury the buffer.

If markdown-mode is installed, and `dsh-bridge-view-gfm` is non-nil,
the reply is font-locked as GitHub-Flavored Markdown.

### DSH-Prompt buffer

This buffer is used to compose a prompt, or reply, for a DSH session.
It is opened by `r`/`RET` from the DSH-Sessions buffer, and `r` from
the transient menu or DSH-View buffer.  The session affected is
determined by how this buffer was invoked; for instance, `r` from a
DSH-View buffer opens a prompt for the same session.

The following commands are available from the DSH-Prompt buffer:

* `C-c C-c` — send the region, or the whole buffer, as a prompt.
* `C-c C-d` — push it to the DSH composer as a draft instead.
* `C-c C-k` — erase the buffer.
* `C-c C-f` — open the DSH-View buffer for this session.
* `C-c C-l` — open the DSH-Sessions buffer.
* `M-p` / `M-n` — walk the session's prompt history.

When `markdown-mode` is installed, this buffer derives from it, so
most markdown editing commands are also available.

### Sending text from DSH to Emacs

The DSH plugin adds a "Send to Emacs" button that lets you push
specific assistant messages to Emacs.

With `dsh-bridge-notifications` non-nil (the default), Emacs
subscribes to the bridge's event stream and automatically updates the
DSH-View buffer.  If you disable this option, you can use `i` in the
DSH-View buffer (or run `M-x dsh-bridge-receive`) to pull the latest
message pushed by DSH.  Receiving selects the DSH-View buffer unless
`dsh-bridge-receive-pop` is nil.

## Authentication

Every `/dsh-bridge` route requires a shared bearer token stored at
`~/.dsh/dsh-bridge-token` and generated on first use.  Emacs reads
this file directly, while the browser plugin fetches it from the
loopback-only `GET /dsh-bridge/token` route (peer- and origin-fenced).

## License

This software is released under the terms of the GNU General Public
License version 3, or later.  See [COPYING](COPYING).
