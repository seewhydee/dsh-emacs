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

- `dsh`, the DeepSeek Harness.
- Node.js and `pnpm` to build the plugin.
- Emacs 29 or later.
- (Recommended) The [`markdown-mode`](https://jblevins.org/projects/markdown-mode/) Emacs package.

### Emacs package

To build an Emacs package that also bundles the DSH plugin, run this
in the repository's root directory:

```sh
make package
```

Then, in Emacs:

1. `M-x package-install-file RET /path/to/dsh-bridge-<version>.tar RET`
2. (*optional*) If you run DSH from a source checkout, customize the
   variable `dsh-bridge-dsh-command` (e.g., `M-x customize-variable
   RET dsh-bridge-dsh-command RET`) with the DSH command (see below).
   Skip this if `dsh` is on the executable path or run via `npx`.
3. `M-x dsh-bridge-install-plugin` — install the bundled plugin into DSH.
4. Start or restart `dsh web`.

To remove the plugin later, run `M-x dsh-bridge-uninstall-plugin`.

Here is an example of `dsh-bridge-dsh-command` for a source checkout:

```elisp
(setq dsh-bridge-dsh-command "pnpm -C /path/to/deepseek-harness dsh")
```

Note that `~` is not expanded, so specify the full path.  Don't add an
additional `web` argument to the end.

### Manual compilation and installation

Instead of an all-in-one Emacs package, you can build and install the
DSH plugin and Emacs library manually.

#### Build and install the DeepSeek Harness plugin

From this repository's root directory:

```sh
make build   # emits dsh-plugin/lib/index.js (host) + lib/client.js (browser)
```

If you have `dsh` installed on
the executable path, run the following commands

```sh
# global install, from this repo root:
dsh plugin --profile web add link:./dsh-plugin
dsh web
```

If you have a source checkout of DSH and run it as a pnpm script
(`pnpm dsh web`), run the following from the `deepseek-harness`
directory instead, replacing the `link:` path with the appropriate
path into this repo:

```sh
# source checkout, from deepseek-harness root:
pnpm dsh plugin --profile web add link:/absolute/path/to/dsh-emacs-bridge/dsh-plugin
pnpm dsh web
```

#### Install the Emacs library

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
`*` in the leftmost column, and the `S` (state) column shows each
session's live status — a filled circle that is green when idle and
amber when running, `?` when unknown — obeying
`dsh-bridge-status-indicator`.

The following commands are available from the DSH-Sessions buffer:

* `q` — quit the window and bury the buffer.
* `f` — fetch the last output for the session at point into a DSH-View buffer.
* `r` or `RET` — open a DSH-Prompt buffer for the session at point.
* `t` — set the session at point as the default target (resuming a saved
  session first).
* `u` — clear the default target.
* `v` — toggle whether archived sessions are shown (hidden by default).
* `R` — rename the session at point.
* `d` — archive the session at point.
* `+` — create a new session, optionally in a new workspace.
* `W` — rename the workspace of the session at point.
* `g` — refresh the DSH-Sessions buffer.

For a full list, see the menu bar.  Other `tabulated-list-mode` keys
are also available.

### DSH-View buffer

This read-only buffer contains the model output for a DSH session.  It
is fetched by `f` from the transient menu or the DSH-Sessions buffer,
`C-c C-f` from the DSH-Prompt buffer, or pushed from the web UI's
"Send to Emacs" button (see below).

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

* `C-c C-c` — send the region, or the whole buffer, as a prompt.  On
  success, bury the buffer.
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

## Permissions, authentication, and failure bounds

The DSH plugin registers its routes on the DSH web server's loopback
listener, and the browser plugin calls only same-origin
`/dsh-bridge/*` routes.  No third-party service is contacted.

Every `/dsh-bridge` route requires a shared bearer token stored at
`~/.dsh/dsh-bridge-token`, generated on first use in mode 0600.  Emacs
reads this file directly, while the browser plugin fetches it from the
loopback-only `GET /dsh-bridge/token` route (peer- and origin-fenced).

HTTP request bodies are capped at 1 MiB; larger bodies get a 413
error.  DSH-to-Emacs messages are held in a bounded outbox (100
unacknowledged entries); overflow evicts the oldest entries and is
reported to the collector.  Naming a cold (persisted-only) session
from Emacs resumes it on demand, matching the web UI; an id neither
live nor persisted is 404, a subagent-owned session is 409, and a
draft push fails with 409 when no browser client is subscribed.

## License

This software is released under the terms of the GNU General Public
License version 3, or later.  See [COPYING](COPYING).
