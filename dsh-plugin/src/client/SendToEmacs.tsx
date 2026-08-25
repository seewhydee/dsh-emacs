// dsh-emacs-bridge — "Send to Emacs" action for the assistant message actions
// row. Reads the assistant message text from the conversation snapshot by
// messageId and deposits it into the host outbox for Emacs to pull.
// Copyright (C) 2026  Chong Yidong <cyd@stupidchicken.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import { useCallback, useState } from 'react'
import { IconCheckOutline16, Tooltip } from '@deepseek-ai/dsh-client-ui-primitives'
import type { PropsLocale, SnapshotSelectorHook } from '@deepseek-ai/dsh-client-ui-slots'
import type {} from './locales.ts'
import { EmacsMiniIcon } from './EmacsMiniIcon.tsx'

/** Minimal structural face of an assistant content block. */
interface AssistantBlockLike {
  kind: string
  text?: string
}

/**
 * The slice of a Chat node's data the selector reads. A turn-tail node carries
 * `closing` (the finalized assistant of its turn); a live assistant node
 * carries `blocks` directly. Both are narrowed out of the node's `unknown`.
 */
interface ChatNodeData {
  closing?: { finalNode?: { messageId?: string }; blocks?: readonly AssistantBlockLike[] } | null
  messageId?: string
  blocks?: readonly AssistantBlockLike[]
}

/** Minimal structural face of the Chat snapshot the selector walks. */
interface ChatSnapshotLike {
  chat: { nodes: { values: () => readonly { data: unknown }[] } }
}

/** Concatenate the visible prose from assistant content blocks. */
function assistantText(blocks: readonly AssistantBlockLike[]): string {
  let out = ''
  for (const block of blocks) {
    if (block.kind === 'text' && block.text !== undefined) out += block.text
  }
  return out
}

/**
 * The assistant message text for one durable messageId. Looks for the
 * turn-tail node whose finalized message carries that id, then falls back to
 * a live assistant node with the same id.
 */
function textForMessage(snapshot: ChatSnapshotLike, messageId: string): string {
  for (const node of snapshot.chat.nodes.values()) {
    const data = node.data as ChatNodeData | null
    if (data === null) continue
    if (data.closing?.finalNode?.messageId === messageId) {
      return assistantText(data.closing.blocks ?? [])
    }
    if (data.messageId === messageId) return assistantText(data.blocks ?? [])
  }
  return ''
}

/** Props handed to the slot occupant: owner id, the session snapshot hook, the deposit verb, and the locale seat. */
interface SendToEmacsProps {
  messageId: string
  useSession: SnapshotSelectorHook<ChatSnapshotLike>
  deposit: (text: string) => Promise<void>
  t: PropsLocale<'dsh-emacs-bridge'>['t']
}

/**
 * The "Send to Emacs" action: deposit the assistant message text into the
 * bridge outbox. A brief check swap confirms success; a failure surfaces a
 * short tooltip message and leaves the button usable.
 */
export function SendToEmacs({ messageId, useSession, deposit, t }: SendToEmacsProps) {
  const text = useSession(snapshot => textForMessage(snapshot, messageId))
  const [sent, setSent] = useState(false)
  const [pending, setPending] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  const onClick = useCallback(() => {
    if (pending || text === '') return
    setPending(true)
    setFailure(null)
    deposit(text)
      .then(() => {
        setPending(false)
        setSent(true)
        window.setTimeout(() => setSent(false), 1200)
      })
      .catch((error: unknown) => {
        setPending(false)
        setFailure(error instanceof Error ? error.message : String(error))
      })
  }, [pending, text, deposit])
  const label = failure ?? (sent ? t('sentToEmacs') : t('sendToEmacs'))
  return (
    <Tooltip label={label} side="bottom">
      <button
        type="button"
        aria-label={t('sendToEmacs')}
        disabled={pending}
        onClick={onClick}
        style={{
          display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
          width: 20, height: 20, border: 0, background: 'none', padding: 0,
          cursor: pending ? 'default' : 'pointer', color: 'inherit',
        }}
      >
        {sent ? <IconCheckOutline16 /> : <EmacsMiniIcon />}
      </button>
    </Tooltip>
  )
}
