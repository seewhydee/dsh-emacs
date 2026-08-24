// dsh-emacs-bridge — DSH host-plane function plugin. Cordis id: `dsh-bridge`.
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
//
// MVP: data transfer to/from the DSH text box over loopback HTTP.
//   POST /dsh-bridge/send   { text, sessionId? } -> Agent.followup()
//   GET  /dsh-bridge/output?sessionId=           -> latest assistant text
//   GET  /dsh-bridge/sessions                     -> live + persisted sessions
//   POST /dsh-bridge/select { sessionId | null }  -> pin the target session
//   GET  /dsh-bridge/current                      -> the pinned target (or null)
//
// The bridge targets whichever conversation is currently active in DSH: the
// live session whose event log is newest, ignoring subagent child sessions. A
// selected session pins the target; a per-request `sessionId` overrides both.

import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import type { Session, SessionHeader } from '@deepseek-ai/dsh-session'

export const name = 'dsh-bridge'

export const inject = ['agents', 'webServer', 'sessions', 'sessionPersistence']

/** Minimal face of the `webServer` service. */
interface WebServerService {
  register(route: {
    kind: 'exact' | 'prefix'
    path: string
    handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>
  }): () => void
}

/** Minimal face of the `sessions` service: enumerate live sessions. */
interface SessionService {
  list(): Session[]
}

/** Minimal face of the `sessionPersistence` service: list materialized session headers. */
interface SessionPersistenceService {
  list(signal?: AbortSignal): Promise<SessionHeader[]>
}

/** One entry in the merged session inventory handed to Emacs. */
interface SessionRow {
  id: string
  cwd: string | null
  live: boolean
  lastActive?: number
  createdAt: number
}

/**
 * Latest assistant text in one session's current transcript, newest-first.
 * Reads the derived view (not the raw event log) so compaction-replaced
 * history stays hidden; assistant turns with no text (tool-call-only steps)
 * fall through to the previous one.
 */
function latestAssistantText(agent: Agent): string {
  const messages = agent.session.deriveMessages()
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i]
    if (message.role !== 'assistant') continue
    const text = message.content
      .filter(block => block.type === 'text')
      .map(block => block.text)
      .join('')
    if (text !== '') return text
  }
  return ''
}

const MAX_BODY_BYTES = 1024 * 1024

/** Read a bounded JSON request body; rejects on oversize or malformed input. */
function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let body = ''
    req.setEncoding('utf8')
    req.on('data', (chunk: string) => {
      body += chunk
      if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
        reject(new Error('request body too large'))
        req.destroy()
      }
    })
    req.on('end', () => {
      try {
        resolve(body === '' ? undefined : JSON.parse(body))
      } catch (error: unknown) {
        reject(new Error(`invalid JSON: ${error instanceof Error ? error.message : String(error)}`))
      }
    })
    req.on('error', reject)
  })
}

/** Write one JSON response. */
function sendJson(res: ServerResponse, status: number, value: unknown): void {
  const payload = JSON.stringify(value)
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(payload)
}

/** The target of a bridge operation: a live session plus its live agent. */
interface BridgeTarget {
  session: Session
  agent: Agent
}

/** The result of resolving a request's target session. */
interface ResolvedTarget {
  target?: BridgeTarget
  error?: string
}

export function apply(ctx: Context): void {
  const webServer = ctx.get('webServer') as WebServerService
  const sessions = ctx.get('sessions') as SessionService
  const sessionPersistence = ctx.get('sessionPersistence') as SessionPersistenceService

  /** The session id pinned by `/select`; undefined means last-active. */
  let selectedSessionId: string | undefined

  /** Live sessions the bridge may target (subagent children excluded). */
  function liveSessions(): Session[] {
    return sessions.list().filter(session => session.header.origin !== 'subagent')
  }

  /** A live, non-subagent session by its string id. */
  function liveSessionById(id: string): Session | undefined {
    return liveSessions().find(session => String(session.id) === id)
  }

  /** The live agent for a live session, when one is registered. */
  function targetFor(session: Session): BridgeTarget | undefined {
    const agent = ctx.agents.get(session.id)
    return agent === undefined ? undefined : { session, agent }
  }

  /**
   * The live session to target when nothing is pinned: the most recently
   * active one (newest event `time`, falling back to `createdAt`).
   */
  function lastActiveSession(): BridgeTarget | undefined {
    let best: BridgeTarget | undefined
    let bestTime = -Infinity
    for (const session of liveSessions()) {
      const target = targetFor(session)
      if (target === undefined) continue
      const time = session.events.at(-1)?.time ?? session.header.createdAt
      if (time > bestTime) {
        bestTime = time
        best = target
      }
    }
    return best
  }

  /**
   * Resolve a request's effective target: an explicit `sessionId` wins, then
   * the pinned target, then last-active. A non-live explicit id is an error
   * (resume is not implemented); a pinned id that has gone away falls back.
   */
  function resolveTarget(explicitId: string | undefined): ResolvedTarget {
    if (explicitId !== undefined) {
      const session = liveSessionById(explicitId)
      if (session === undefined) return { error: `session ${explicitId} is not live` }
      const target = targetFor(session)
      if (target === undefined) return { error: `session ${explicitId} has no live agent` }
      return { target }
    }
    if (selectedSessionId !== undefined) {
      const session = liveSessionById(selectedSessionId)
      const target = session === undefined ? undefined : targetFor(session)
      if (target !== undefined) return { target }
      // The pinned session is gone or undrivable — fall through to last-active.
    }
    return { target: lastActiveSession() }
  }

  /** Merge live sessions with persisted (cold) headers, deduping live ids. */
  async function listSessions(): Promise<SessionRow[]> {
    const liveIds = new Set<string>()
    const rows: SessionRow[] = []
    for (const session of liveSessions()) {
      const id = String(session.id)
      liveIds.add(id)
      rows.push({
        id,
        cwd: session.header.cwd ?? null,
        live: true,
        lastActive: session.events.at(-1)?.time ?? session.header.createdAt,
        createdAt: session.header.createdAt,
      })
    }
    // `sessionPersistence` is a required inject, so it is always present; the
    // try/catch guards backend *errors* — a persistence failure is auxiliary
    // to the live view and must not hide the sessions that are running now.
    try {
      const headers = await sessionPersistence.list()
      for (const header of headers) {
        if (header.origin === 'subagent') continue
        const id = String(header.id)
        if (liveIds.has(id)) continue
        rows.push({ id, cwd: header.cwd ?? null, live: false, createdAt: header.createdAt })
      }
    } catch {
      // Best-effort per the comment above.
    }
    return rows
  }

  // Registered inside an effect so a config hot-reload disposes the route
  // before re-applying — a duplicate (kind, path) registration throws.
  ctx.effect(() => webServer.register({
    kind: 'prefix',
    path: '/dsh-bridge',
    handler: async (req, res) => {
      const url = new URL(req.url ?? '/', 'http://localhost')
      const pathname = url.pathname

      if (req.method === 'GET' && pathname === '/dsh-bridge/sessions') {
        try {
          sendJson(res, 200, { sessions: await listSessions() })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/current') {
        // A pin is only truthful while it still resolves to a drivable
        // target; a dead pin is cleared so Emacs does not re-target a
        // session the bridge can no longer reach.
        if (selectedSessionId !== undefined) {
          const session = liveSessionById(selectedSessionId)
          if (session === undefined || targetFor(session) === undefined) {
            selectedSessionId = undefined
          }
        }
        sendJson(res, 200, { sessionId: selectedSessionId ?? null })
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/select') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown } | undefined
          const id = body?.sessionId
          if (id === null || id === undefined) {
            selectedSessionId = undefined
            sendJson(res, 200, { ok: true, sessionId: null })
            return
          }
          if (typeof id !== 'string' || id === '') {
            sendJson(res, 400, { error: 'sessionId must be a non-empty string or null' })
            return
          }
          const session = liveSessionById(id)
          if (session === undefined) {
            sendJson(res, 404, { error: `session ${id} is not live` })
            return
          }
          if (targetFor(session) === undefined) {
            sendJson(res, 409, { error: `session ${id} has no live agent` })
            return
          }
          selectedSessionId = id
          sendJson(res, 200, { ok: true, sessionId: id })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/send') {
        try {
          const body = (await readJson(req)) as { text?: unknown; sessionId?: unknown } | undefined
          const text = typeof body?.text === 'string' ? body.text : ''
          if (text.trim() === '') {
            sendJson(res, 400, { error: 'text is required' })
            return
          }
          let explicitId: string | undefined
          if (body?.sessionId !== undefined && body.sessionId !== null) {
            if (typeof body.sessionId !== 'string') {
              sendJson(res, 400, { error: 'sessionId must be a string' })
              return
            }
            explicitId = body.sessionId
          }
          const { target, error } = resolveTarget(explicitId)
          if (error !== undefined) {
            sendJson(res, 404, { error })
            return
          }
          if (target === undefined) {
            sendJson(res, 409, { error: 'no active session' })
            return
          }
          target.agent.followup(createUserMessage({
            content: [{ type: 'text', text }],
            source: { kind: 'user' },
          }))
          sendJson(res, 200, { ok: true, sessionId: String(target.session.id) })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/output') {
        const { target, error } = resolveTarget(url.searchParams.get('sessionId') ?? undefined)
        if (error !== undefined) {
          sendJson(res, 404, { error })
          return
        }
        if (target === undefined) {
          sendJson(res, 404, { error: 'no active session' })
          return
        }
        sendJson(res, 200, { sessionId: String(target.session.id), text: latestAssistantText(target.agent) })
        return
      }

      sendJson(res, 404, { error: 'not found' })
    },
  }))
}
