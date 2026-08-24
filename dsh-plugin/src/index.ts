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
//   POST /dsh-bridge/send   { text } -> Agent.followup() (submits a prompt)
//   GET  /dsh-bridge/output          -> latest assistant text for the session
//
// The bridge targets whichever conversation is currently active in DSH: the
// live session whose event log is newest, ignoring subagent child sessions.
// No session is configured or created here — the bridge rides the session the
// user is already working in.

import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import type { Session } from '@deepseek-ai/dsh-session'

export const name = 'dsh-bridge'

export const inject = ['agents', 'webServer', 'sessions']

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

export function apply(ctx: Context): void {
  const webServer = ctx.get('webServer') as WebServerService
  const sessions = ctx.get('sessions') as SessionService

  /**
   * The live session to target: the most recently active one. Subagent child
   * sessions are ignored so the bridge follows the top-level conversation the
   * user is driving, never a background child it spawned. The session's agent
   * must be live — there is nothing to drive for a session without one.
   *
   * @returns the target, or undefined when no live agent-backed top-level
   *   session exists.
   */
  function lastActiveSession(): BridgeTarget | undefined {
    let best: BridgeTarget | undefined
    let bestTime = -Infinity
    for (const session of sessions.list()) {
      if (session.header.origin === 'subagent') continue
      const agent = ctx.agents.get(session.id)
      if (agent === undefined) continue
      const time = session.events.at(-1)?.time ?? session.header.createdAt
      if (time > bestTime) {
        bestTime = time
        best = { session, agent }
      }
    }
    return best
  }

  // Registered inside an effect so a config hot-reload disposes the route
  // before re-applying — a duplicate (kind, path) registration throws.
  ctx.effect(() => webServer.register({
    kind: 'prefix',
    path: '/dsh-bridge',
    handler: async (req, res) => {
      const pathname = new URL(req.url ?? '/', 'http://localhost').pathname
      if (req.method === 'POST' && pathname === '/dsh-bridge/send') {
        try {
          const body = (await readJson(req)) as { text?: unknown }
          const text = typeof body?.text === 'string' ? body.text : ''
          if (text.trim() === '') {
            sendJson(res, 400, { error: 'text is required' })
            return
          }
          const target = lastActiveSession()
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
        const target = lastActiveSession()
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
