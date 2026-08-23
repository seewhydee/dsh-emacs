# dsh-emacs

A two-way bridge between an Emacs session and a running
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) session.

The DSH text window is small and typing-poor; Emacs is a full editor but lacks
DSH's live agent.  This bridge moves text in both directions over loopback
HTTP, so you can type in Emacs and read DSH's replies without window-switching
and copy-paste.

## Components

- `dsh-plugin/` — `dsh-emacs-bridge`, a DeepSeek Harness host plugin (Cordis id
  `dsh-bridge`).  It registers a loopback HTTP route that submits prompts and
  serves back the latest assistant reply.
- `emacs/dsh-bridge.el` — the Emacs side (feature `dsh-bridge`), which talks to
  that route.

## Status

MVP prototype.  It currently supports:

- sending a region or buffer to DSH as a prompt;
- fetching the latest assistant reply into an Emacs buffer.

Everything else — a `/emacs` edit command, a composer button,
per-workspace/session targeting, live streaming — is a later phase.  The
scope-reducing decisions and the roadmap live in [PLAN.md](PLAN.md).

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
pnpm build     # emits lib/index.js
```

## Install the plugin into dsh

The plugin is a dsh *bundle*: it declares `dsh.bundle` and inserts one row into
the composition.  Install it into the `web` profile with a filesystem link, then
restart `dsh web` so the profile reloads its bundle set:

```sh
# from the repo root
dsh plugin --profile web add link:./dsh-plugin
dsh web
```

Confirm the row composed:

```sh
dsh web --dump-config | grep -A2 dsh-bridge
```

The plugin's `config` block accepts:

| Key | Default | Meaning |
|---|---|---|
| `sessionId` | `dsh-emacs` | The one session the bridge targets (created on first send). |
| `cwd` | process cwd | Working directory for a newly created session. |
| `presetId` | deployment default | Agent preset to compose for the session. |

## Install the Emacs package

```elisp
(add-to-list 'load-path "/path/to/dsh-emacs/emacs")
(require 'dsh-bridge)
```

Set `dsh-bridge-url` if your `dsh web` binds a non-default port (default
`http://127.0.0.1:3080/dsh-bridge`).

## Usage

From Emacs:

- `M-x dsh-bridge-send-region` — send the selected region to DSH as a prompt.
- `M-x dsh-bridge-send-buffer` — send the whole buffer.
- `M-x dsh-bridge-get-output` — fetch the latest DSH assistant reply into
  `*dsh-bridge-output*`.

## License

GPLv3 or later.  See [COPYRIGHT](COPYRIGHT).
