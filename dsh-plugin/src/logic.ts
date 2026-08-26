// dsh-emacs-bridge — pure, dependency-free logic. No Cordis/dsh runtime
// imports live here, so Vitest can exercise this module without booting a host.
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

import { timingSafeEqual } from 'node:crypto'

/** One content block, narrowed to the fields the bridge reads. */
export interface MessageBlockLike {
  type: string
  text?: string
}

/** One derived message, narrowed to the fields the bridge reads. */
export interface MessageLike {
  role: string
  content: readonly MessageBlockLike[]
}

/**
 * Latest assistant text, newest-first. Reads the derived message view so
 * compaction-replaced history stays hidden; assistant turns with no text
 * (tool-call-only steps) fall through to the previous one.
 */
export function latestAssistantText(messages: readonly MessageLike[]): string {
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i]
    if (message.role !== 'assistant') continue
    const text = message.content
      .filter(block => block.type === 'text')
      .map(block => block.text ?? '')
      .join('')
    if (text !== '') return text
  }
  return ''
}

/**
 * The text of every user prompt, oldest first. The mirror image of
 * `latestAssistantText`: reads the derived message view, keeps `user` role
 * messages, joins their text blocks with newlines, and drops whitespace-only
 * entries. Used by the prompt-buffer history.
 */
export function userPrompts(messages: readonly MessageLike[]): string[] {
  const prompts: string[] = []
  for (const message of messages) {
    if (message.role !== 'user') continue
    const text = message.content
      .filter(block => block.type === 'text')
      .map(block => block.text ?? '')
      .join('\n')
    if (text.trim() !== '') prompts.push(text)
  }
  return prompts
}

/**
 * Minimal structural face of one logged event, enough to fold a title and
 * last-activity time. `data` is deliberately `unknown`: the real `SessionEvent`
 * union satisfies this shape, and the title fold narrows the payload it reads.
 */
export interface SessionEventLike {
  time: number
  type?: string
  data?: unknown
}

/** Structural view of one live session, enough for targeting and listing. */
export interface LiveSessionLike {
  id: string
  header: { cwd?: string; createdAt: number }
  events: readonly SessionEventLike[]
  /** Whether the live agent is actively processing a turn (not yet quiesced). */
  running: boolean
}

/** Structural view of one persisted session header. */
export interface SessionHeaderLike {
  id: string
  cwd?: string
  createdAt: number
  origin?: string
  title?: string | null
}

/** One entry in the merged session inventory handed to Emacs. */
export interface SessionRow {
  id: string
  title: string | null
  cwd: string | null
  live: boolean
  /** Whether the session's agent is currently running a turn (never for cold). */
  running: boolean
  lastActive?: number
  createdAt: number
  /** Display name of the workspace the session belongs to, when one is known. */
  workspace?: string | null
}

/** Minimal structural face of one workspace, enough for a session->title map. */
export interface WorkspaceLike {
  title: string
  sessionIds: readonly string[]
}

/**
 * Build a session-id -> workspace-title map from the registry's workspaces.
 * A session accounted by several workspaces keeps the last one's title (the
 * registry invariant forbids that overlap in practice).
 */
export function workspaceTitlesBySession(workspaces: readonly WorkspaceLike[]): Map<string, string> {
  const map = new Map<string, string>()
  for (const workspace of workspaces) {
    for (const id of workspace.sessionIds) map.set(id, workspace.title)
  }
  return map
}

/**
 * Whether a session must be excluded from targeting and listing: it is a
 * subagent child by origin, or its live parent still owns it (`ownedByParent`
 * is computed by the caller from the live agent registry).
 */
export function isSubagentChild(origin: string | undefined, ownedByParent: boolean): boolean {
  return origin === 'subagent' || ownedByParent
}

/**
 * The latest `session/title` event's title, or null. Last-wins fold of the
 * same event DSH's own session list projects as the display title; titles are
 * normalized non-empty strings, so a malformed or empty payload reads as null.
 */
export function sessionTitle(events: readonly SessionEventLike[]): string | null {
  const event = events.findLast(item => item.type === 'session/title')
  const data = event?.data
  if (typeof data !== 'object' || data === null) return null
  const title = (data as { title?: unknown }).title
  return typeof title === 'string' && title !== '' ? title : null
}

/**
 * Merge live sessions with persisted (cold) headers into one inventory.
 * `live` is already filtered to targetable sessions by the caller; persisted
 * entries are skipped when subagent-owned or already present as live.
 */
export function mergeSessionRows(
  live: readonly LiveSessionLike[],
  persisted: readonly SessionHeaderLike[],
): SessionRow[] {
  const liveIds = new Set<string>()
  const rows: SessionRow[] = []
  for (const session of live) {
    const id = session.id
    liveIds.add(id)
    rows.push({
      id,
      title: sessionTitle(session.events),
      cwd: session.header.cwd ?? null,
      live: true,
      running: session.running,
      lastActive: session.events.at(-1)?.time ?? session.header.createdAt,
      createdAt: session.header.createdAt,
    })
  }
  for (const header of persisted) {
    if (header.origin === 'subagent') continue
    const id = header.id
    if (liveIds.has(id)) continue
    rows.push({
      id,
      title: header.title ?? null,
      cwd: header.cwd ?? null,
      live: false,
      running: false,
      createdAt: header.createdAt,
    })
  }
  return rows
}

/** The outcome of resolving a request's target session id. */
export type ResolveTargetResult =
  | { kind: 'target'; id: string }
  | { kind: 'error'; status: 404 | 409; message: string }

/**
 * Resolve the effective target session id. Precedence: an explicit id, then a
 * pinned id, then last-active. A non-live explicit id is 404; a live session
 * with no live agent is 409; no targetable session at all is 409. `hasAgent`
 * is supplied by the caller (it consults the live agent registry).
 */
export function resolveTargetId(
  explicitId: string | undefined,
  selectedId: string | undefined,
  live: readonly LiveSessionLike[],
  hasAgent: (id: string) => boolean,
): ResolveTargetResult {
  const find = (id: string): LiveSessionLike | undefined => live.find(session => session.id === id)
  if (explicitId !== undefined) {
    const session = find(explicitId)
    if (session === undefined) return { kind: 'error', status: 404, message: `session ${explicitId} is not live` }
    if (!hasAgent(session.id)) return { kind: 'error', status: 409, message: `session ${explicitId} has no live agent` }
    return { kind: 'target', id: session.id }
  }
  if (selectedId !== undefined) {
    const session = find(selectedId)
    if (session !== undefined && hasAgent(session.id)) return { kind: 'target', id: session.id }
    // A dead pin falls back to last-active.
  }
  let best: string | undefined
  let bestTime = -Infinity
  for (const session of live) {
    if (!hasAgent(session.id)) continue
    const time = session.events.at(-1)?.time ?? session.header.createdAt
    if (time > bestTime) {
      bestTime = time
      best = session.id
    }
  }
  if (best === undefined) return { kind: 'error', status: 409, message: 'no active session' }
  return { kind: 'target', id: best }
}

/** The bearer token carried by an Authorization header, or undefined. */
export function parseBearerAuthorization(header: string | undefined): string | undefined {
  if (header === undefined) return undefined
  const match = /^Bearer\s+(\S+)$/.exec(header)
  return match?.[1]
}

/** Constant-time comparison of two token strings. */
export function tokensEqual(expected: string, provided: string): boolean {
  const a = Buffer.from(expected)
  const b = Buffer.from(provided)
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

/** The hostname part of a Host header value, handling an IPv6-bracketed port. */
export function hostnameOf(host: string): string {
  if (host.startsWith('[')) {
    const end = host.indexOf(']')
    return end === -1 ? host : host.slice(1, end)
  }
  const colon = host.lastIndexOf(':')
  return colon === -1 ? host : host.slice(0, colon)
}

/** Whether a hostname names the loopback interface. */
export function isLoopbackHostname(name: string): boolean {
  return name === 'localhost' || name === '127.0.0.1' || name === '::1'
}

/**
 * Whether a socket peer address names the loopback interface (IPv4 127/8,
 * `::1`, or IPv4-mapped `::ffff:127/8`). Unlike the Host header, a TCP peer
 * address cannot be forged by a remote client, so this check keeps the
 * token-vend route loopback-only even if the server is configured to bind a
 * non-loopback interface.
 */
export function isLoopbackAddress(address: string | undefined): boolean {
  if (address === undefined) return false
  const unmapped = address.startsWith('::ffff:') ? address.slice('::ffff:'.length) : address
  return unmapped === '::1' || unmapped.startsWith('127.')
}

/** Whether an Origin value belongs to the loopback interface. */
export function isLoopbackOrigin(origin: string): boolean {
  let url: URL
  try {
    url = new URL(origin)
  } catch {
    return false
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return false
  return isLoopbackHostname(url.hostname)
}

/**
 * Whether a token-vend request proves it came from the web UI's own origin:
 * the Host must name loopback (defeating DNS-rebinding), and a present Origin
 * must too (defeating a cross-origin page). The browser legitimately lacks the
 * bearer token on first load, so this fence stands in for it on that one
 * route. Headers alone cannot prove the peer is local (a remote client can
 * forge Host when the server binds a non-loopback interface), so callers must
 * combine this with `isLoopbackAddress(req.socket.remoteAddress)`.
 */
export function tokenRequestsSameOrigin(host: string | undefined, origin: string | undefined): boolean {
  if (host === undefined) return false
  if (!isLoopbackHostname(hostnameOf(host))) return false
  if (origin !== undefined && !isLoopbackOrigin(origin)) return false
  return true
}

/**
 * One SSE `data:` frame for a composer-draft push. The payload names the target
 * session so the browser routes the draft to the right composer scope.
 */
export function draftMessage(sessionId: string, text: string): string {
  return `data: ${JSON.stringify({ kind: 'draft', sessionId, text })}\n\n`
}

/**
 * One SSE `data:` frame signalling that new outbox entries are available (the
 * "Send to Emacs" button deposited a message). A bare notice: consumers pull the
 * outbox themselves, keeping the ack/redelivery semantics in one place.
 */
export function outboxMessage(): string {
  return 'data: {"kind":"outbox"}\n\n'
}
