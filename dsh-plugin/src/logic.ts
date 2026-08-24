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

/** Structural view of one live session, enough for targeting and listing. */
export interface LiveSessionLike {
  id: string
  header: { cwd?: string; createdAt: number }
  events: readonly { time: number }[]
}

/** Structural view of one persisted session header. */
export interface SessionHeaderLike {
  id: string
  cwd?: string
  createdAt: number
  origin?: string
}

/** One entry in the merged session inventory handed to Emacs. */
export interface SessionRow {
  id: string
  cwd: string | null
  live: boolean
  lastActive?: number
  createdAt: number
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
      cwd: session.header.cwd ?? null,
      live: true,
      lastActive: session.events.at(-1)?.time ?? session.header.createdAt,
      createdAt: session.header.createdAt,
    })
  }
  for (const header of persisted) {
    if (header.origin === 'subagent') continue
    const id = header.id
    if (liveIds.has(id)) continue
    rows.push({ id, cwd: header.cwd ?? null, live: false, createdAt: header.createdAt })
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
