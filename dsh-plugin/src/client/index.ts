// dsh-emacs-bridge — DSH client plugin (browser half). Registers the
// "Send to Emacs" action into the assistant message actions row.
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

import type { ClientContext } from '@deepseek-ai/dsh-client-runtime/client'
// Type-only: pulls the conversation SlotMap merge so the assistant-actions
// seat is known to the slot registry.
import type {} from '@deepseek-ai/dsh-client-ui-conversation/client'
import { en, zh } from './locales.ts'
import { SendToEmacs } from './SendToEmacs.tsx'

/** Locale namespace owned by this plugin (its `t` seat on the assistant-actions entry). */
const LOCALE_NS = 'dsh-emacs-bridge'

export const inject = ['slots', 'locale', 'sessions']

/** Minimal face of the session-scoped context, enough to reach the conversation service. */
interface SessionScopeCtx {
  get(name: string): unknown
}

/** Minimal face of the client sessions service used to reach a session's scope. */
interface SessionsService {
  scope(sessionId: string): SessionScopeCtx | undefined
}

/** Minimal face of the scoped conversation service, enough to set a composer draft. */
interface ConversationService {
  input: { for(ctx: SessionScopeCtx): { setDraft(text: string): void } }
}

/** In-memory token cache, so the vend fetch happens at most once per page. */
let cachedToken: string | null = null

/** Forget the in-memory and stored token, forcing a fresh vend next time. */
function forgetToken(): void {
  cachedToken = null
  localStorage.removeItem('dsh-bridge-token')
}

/**
 * Resolve the bearer token: the in-memory cache, then `localStorage`, then the
 * loopback-fenced token-vend route (auto, with no manual paste).
 */
async function getToken(): Promise<string> {
  if (cachedToken !== null) return cachedToken
  const stored = localStorage.getItem('dsh-bridge-token')
  if (stored !== null) {
    cachedToken = stored
    return stored
  }
  const response = await fetch('/dsh-bridge/token')
  if (!response.ok) throw new Error(`token fetch failed: HTTP ${response.status}`)
  const body = (await response.json()) as { token?: string }
  if (typeof body.token !== 'string' || body.token === '') {
    throw new Error('/dsh-bridge/token returned no token')
  }
  localStorage.setItem('dsh-bridge-token', body.token)
  cachedToken = body.token
  return body.token
}

/** One authorized POST to a bridge route; returns the response. */
async function postAuthorized(path: string, payload: unknown, token: string): Promise<Response> {
  return fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(payload),
  })
}

/**
 * Deposit one assistant message into the host outbox. A 401 means the
 * cached/stored token is stale (the host regenerated the token file), so it is
 * dropped and a fresh one vended — exactly once; a second 401 is an error.
 */
async function depositOutbox(sessionId: string, text: string): Promise<void> {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const response = await postAuthorized(
      '/dsh-bridge/outbox',
      { text, sessionId, source: 'message-action' },
      await getToken(),
    )
    if (response.ok) return
    if (response.status === 401 && attempt === 0) {
      forgetToken()
      continue
    }
    throw new Error(`HTTP ${response.status}`)
  }
  throw new Error('HTTP 401')
}

/** The live EventSource, so an HMR reload can drop the previous one. */
let draftSource: EventSource | null = null

/** Push one draft onto a session's composer, if that session is loaded in the browser. */
function applyDraft(ctx: ClientContext, sessionId: string, text: string): void {
  const actx = (ctx.get('sessions') as SessionsService).scope(sessionId)
  if (actx === undefined) return
  const conversation = actx.get('conversation') as ConversationService | undefined
  if (conversation === undefined) return
  conversation.input.for(actx).setDraft(text)
}

/** Subscribe to the composer-draft SSE stream and apply drafts to the target session. */
async function connectDraftStream(ctx: ClientContext): Promise<void> {
  let token: string
  try {
    token = await getToken()
  } catch (error) {
    // No token, no stream — the draft push stays unavailable until a vend
    // succeeds. Fire-and-forget.
    // eslint-disable-next-line no-console
    console.error('[dsh-bridge] draft stream unavailable', error)
    return
  }
  draftSource?.close()
  const source = new EventSource(`${location.origin}/dsh-bridge/events?token=${encodeURIComponent(token)}`)
  draftSource = source
  source.addEventListener('message', (event: MessageEvent<string>) => {
    let payload: { kind?: unknown; sessionId?: unknown; text?: unknown }
    try {
      payload = JSON.parse(event.data) as typeof payload
    } catch {
      return
    }
    if (payload.kind !== 'draft' || typeof payload.sessionId !== 'string' || typeof payload.text !== 'string') return
    applyDraft(ctx, payload.sessionId, payload.text)
  })
}

/**
 * Client plugin body: register the per-message "Send to Emacs" action.
 * @param ctx - client root context.
 */
export function apply(ctx: ClientContext): void {
  ctx.effect(() => ctx.locale.register(LOCALE_NS, { zh, en }))
  ctx.slots.inject('conversation.chat.assistant-actions', () => {
    const dispose = ctx.slots.register({
      name: 'conversation.chat.assistant-actions',
      id: 'send-to-emacs',
      order: 9,
      locale: LOCALE_NS,
      inject: (sessionId: string) => ({
        deposit: (text: string) => depositOutbox(sessionId, text),
      }),
    }, SendToEmacs)
    return () => {
      dispose()
    }
  })
  void connectDraftStream(ctx)
}
