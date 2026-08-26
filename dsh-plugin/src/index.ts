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
// Routes (all require `Authorization: Bearer <token>` — except the token-vend
// and browser-SSE routes; see logic.ts for the pure decision logic):
//   GET  /dsh-bridge/token                          -> vend the token (loopback-fenced)
//   GET  /dsh-bridge/events?token=                  -> EventSource (composer-draft push)
//   POST /dsh-bridge/send   { text, sessionId? } -> Agent.followup()
//   GET  /dsh-bridge/output?sessionId=           -> latest assistant text
//   GET  /dsh-bridge/sessions                     -> live + persisted sessions
//   POST /dsh-bridge/select { sessionId | null }  -> pin the target session
//   GET  /dsh-bridge/current                      -> the pinned target (or null)
//   POST /dsh-bridge/draft { text, sessionId? }   -> push a composer draft (SSE)
//   GET  /dsh-bridge/outbox                       -> collect DSH->Emacs entries
//   POST /dsh-bridge/outbox { text, sessionId?, source? } -> deposit an entry
//   POST /dsh-bridge/outbox/ack { ids }           -> clear collected entries

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { randomBytes, randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { dirname, join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import type { Session, SessionHeader } from '@deepseek-ai/dsh-session'
import { Outbox } from './outbox.ts'
import {
  draftMessage,
  isLoopbackAddress,
  isSubagentChild,
  latestAssistantText,
  mergeSessionRows,
  outboxMessage,
  parseBearerAuthorization,
  resolveTargetId,
  sessionTitle,
  tokenRequestsSameOrigin,
  tokensEqual,
  userPrompts,
  workspaceTitlesBySession,
  type LiveSessionLike,
  type ResolveTargetResult,
  type SessionEventLike,
  type SessionHeaderLike,
  type SessionRow,
  type WorkspaceLike,
} from './logic.ts'

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

/** Minimal face of the `sessionPersistence` service: list + inspect materialized sessions. */
interface SessionPersistenceService {
  list(signal?: AbortSignal): Promise<SessionHeader[]>
  inspect(id: string, signal?: AbortSignal): Promise<{ events: readonly SessionEventLike[] }>
}

/** Minimal face of one persisted projection-cache snapshot. */
interface ProjectionSnapshotLike {
  asOfSeq: number
  values: Readonly<Record<string, unknown>>
}

/**
 * Minimal face of the optional `sessionProjectionCache` service. Read via
 * `ctx.get` — a profile without the cache simply yields undefined and the
 * bridge falls back to `inspect` for cold titles.
 */
interface ProjectionCacheService {
  cachedSnapshot(meta: SessionHeader): ProjectionSnapshotLike | undefined
}

/**
 * Minimal face of the optional `workspaceRegistry` service. Read via `ctx.get`;
 * a profile without the registry leaves workspace titles unset, and Emacs falls
 * back to the cwd basename.
 */
interface WorkspaceRegistryService {
  list(): WorkspaceLike[]
}

/** The target of a bridge operation: a live session plus its live agent. */
interface BridgeTarget {
  session: Session
  agent: Agent
}

/**
 * Resolve the shared token file: `$DSH_HOME/dsh-bridge-token`, defaulting to
 * `~/.dsh/dsh-bridge-token`. Delegates to `resolveDshHome` so the tilde
 * expansion, whitespace handling, and relative-path resolution match the
 * harness itself (a relative `$DSH_HOME` resolves against the `dsh` process
 * working directory); the Emacs side mirrors the same rules.
 */
function resolveTokenFilePath(): string {
  return join(resolveDshHome(), 'dsh-bridge-token')
}

/** Read the shared token, or generate one and write it mode 0600. */
function loadOrCreateToken(path: string): string {
  if (existsSync(path)) {
    const existing = readFileSync(path, 'utf8').trim()
    if (existing !== '') return existing
  }
  const token = randomBytes(32).toString('hex')
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, token + '\n', { mode: 0o600 })
  return token
}

const MAX_BODY_BYTES = 1024 * 1024

/** Thrown by `readJson` when the body exceeds `MAX_BODY_BYTES`; reported as 413. */
class PayloadTooLargeError extends Error {
  constructor() {
    super('request body too large')
    this.name = 'PayloadTooLargeError'
  }
}

/** Read a bounded JSON request body; rejects on oversize or malformed input. */
function readJson(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let body = ''
    req.setEncoding('utf8')
    req.on('data', (chunk: string) => {
      body += chunk
      if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
        reject(new PayloadTooLargeError())
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

export function apply(ctx: Context): void {
  const webServer = ctx.get('webServer') as WebServerService
  const sessions = ctx.get('sessions') as SessionService
  const sessionPersistence = ctx.get('sessionPersistence') as SessionPersistenceService
  const token = loadOrCreateToken(resolveTokenFilePath())

  /** DSH→Emacs inbox, bounded and acked by Emacs after a successful insert. */
  const outbox = new Outbox()

  /** Browser EventSource clients subscribed to the composer-draft push. */
  const sseClients = new Set<ServerResponse>()

  /** The session id pinned by `/select`; undefined means last-active. */
  let selectedSessionId: string | undefined

  /** Whether a live session is owned by its live parent agent. */
  function ownedByLiveParent(session: Session): boolean {
    const parentId = session.header.parentSession
    if (parentId === undefined) return false
    const agent = ctx.agents.get(session.id)
    if (agent === undefined) return false
    const parent = ctx.agents.get(parentId)
    return parent !== undefined && ctx.agents.isOwnedBy(agent.id, parent)
  }

  /** Live sessions the bridge may target, shaped for the pure logic. */
  function targetableSessions(): LiveSessionLike[] {
    return sessions.list()
      .filter(session => !isSubagentChild(session.header.origin, ownedByLiveParent(session)))
      .map((session): LiveSessionLike => ({
        id: String(session.id),
        header: { cwd: session.header.cwd, createdAt: session.header.createdAt },
        events: session.events,
        running: ctx.agents.get(session.id)?.status === 'running',
      }))
  }

  /** Whether a live, targetable session id has a live agent. */
  function hasAgent(id: string): boolean {
    const session = sessions.list().find(s => String(s.id) === id)
    return session !== undefined && ctx.agents.get(session.id) !== undefined
  }

  /** Whether an id is a drivable target (live, non-subagent, with an agent). */
  function isLiveTarget(id: string): boolean {
    return targetableSessions().some(session => session.id === id) && hasAgent(id)
  }

  /** Resolve a resolved target id back to its live session + agent. */
  function targetById(id: string): BridgeTarget | undefined {
    const session = sessions.list().find(s => String(s.id) === id)
    if (session === undefined) return undefined
    const agent = ctx.agents.get(session.id)
    return agent === undefined ? undefined : { session, agent }
  }

  /** Resolve a request's effective target via the pure precedence logic. */
  function resolveTarget(explicitId: string | undefined): ResolveTargetResult {
    return resolveTargetId(explicitId, selectedSessionId, targetableSessions(), hasAgent)
  }

  /**
   * Fold a cold session's title. The persisted projection cache serves the
   * title with zero log reads (mirroring the harness's own session list); when
   * the cache is absent, or its row lacks the title key, inspect the log and
   * fold `session/title` events directly. Fail-soft: a title is a display
   * nicety and must never hide the session row.
   */
  async function coldSessionTitle(
    cache: ProjectionCacheService | undefined,
    persistence: SessionPersistenceService,
    header: SessionHeader,
  ): Promise<string | null> {
    const snapshot = cache?.cachedSnapshot(header)
    if (snapshot !== undefined) {
      const title = snapshot.values.title
      if (typeof title === 'string' && title !== '') return title
      // The title key is present with a null value: the session has no title
      // yet, and a cold log is immutable, so it cannot acquire one. No inspect.
      if (Object.hasOwn(snapshot.values, 'title')) return null
    }
    try {
      const inspection = await persistence.inspect(header.id)
      return sessionTitle(inspection.events)
    } catch {
      return null
    }
  }

  /** Merge live sessions with persisted headers via the pure merge logic. */
  async function listSessions(): Promise<SessionRow[]> {
    const cache = ctx.get('sessionProjectionCache') as ProjectionCacheService | undefined
    let persisted: SessionHeaderLike[] = []
    try {
      const headers = await sessionPersistence.list()
      persisted = await Promise.all(headers.map(async (header): Promise<SessionHeaderLike> => ({
        id: String(header.id),
        cwd: header.cwd,
        createdAt: header.createdAt,
        origin: header.origin,
        title: header.origin === 'subagent' ? null : await coldSessionTitle(cache, sessionPersistence, header),
      })))
    } catch {
      // Persistence listing is auxiliary to the live view; a backend failure
      // must not hide the sessions that are actually running now.
    }
    const rows = mergeSessionRows(targetableSessions(), persisted)
    const workspaceRegistry = ctx.get('workspaceRegistry') as WorkspaceRegistryService | undefined
    const workspaceBySession = workspaceTitlesBySession(workspaceRegistry?.list() ?? [])
    return rows.map(row => ({ ...row, workspace: workspaceBySession.get(row.id) ?? null }))
  }

  /** Whether a request carries the shared token as a bearer credential. */
  function authorized(req: IncomingMessage): boolean {
    const provided = parseBearerAuthorization(req.headers.authorization)
    return provided !== undefined && tokensEqual(token, provided)
  }

  // Registered inside an effect so a config hot-reload disposes the route
  // before re-applying — a duplicate (kind, path) registration throws.
  ctx.effect(() => webServer.register({
    kind: 'prefix',
    path: '/dsh-bridge',
    handler: async (req, res) => {
      const url = new URL(req.url ?? '/', 'http://localhost')
      const pathname = url.pathname

      // The browser legitimately has no bearer token on first load, so this ONE
      // route is fenced by peer address and origin instead: it hands out the
      // token only to a loopback peer (unforgeable, unlike headers) whose
      // Host/Origin also name loopback (see tokenRequestsSameOrigin).
      if (req.method === 'GET' && pathname === '/dsh-bridge/token') {
        if (!isLoopbackAddress(req.socket.remoteAddress)
          || !tokenRequestsSameOrigin(req.headers.host, req.headers.origin)) {
          sendJson(res, 403, { error: 'forbidden' })
          return
        }
        sendJson(res, 200, { token })
        return
      }

      // Browser-facing SSE for the composer-draft push. EventSource cannot set
      // headers, so it authenticates with the vended token as a query param.
      if (req.method === 'GET' && pathname === '/dsh-bridge/events') {
        const queryToken = url.searchParams.get('token')
        if (!(queryToken !== null && tokensEqual(token, queryToken))) {
          sendJson(res, 401, { error: 'unauthorized' })
          return
        }
        res.writeHead(200, {
          'content-type': 'text/event-stream',
          'cache-control': 'no-cache',
          connection: 'keep-alive',
        })
        res.write('retry: 5000\n\n')
        sseClients.add(res)
        req.on('close', () => { sseClients.delete(res) })
        return
      }

      if (!authorized(req)) {
        sendJson(res, 401, { error: 'unauthorized' })
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/sessions') {
        try {
          sendJson(res, 200, { sessions: await listSessions() })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/current') {
        // A pin is only truthful while it still resolves to a drivable target.
        if (selectedSessionId !== undefined && !isLiveTarget(selectedSessionId)) {
          selectedSessionId = undefined
        }
        sendJson(res, 200, { sessionId: selectedSessionId ?? null })
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/draft') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown; text?: unknown } | undefined
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
          const result = resolveTarget(explicitId)
          if (result.kind === 'error') {
            sendJson(res, result.status, { error: result.message })
            return
          }
          if (sseClients.size === 0) {
            sendJson(res, 409, { error: 'no client connected' })
            return
          }
          const event = draftMessage(result.id, text)
          for (const client of [...sseClients]) {
            try { client.write(event) } catch { sseClients.delete(client) }
          }
          const target = targetById(result.id)
          sendJson(res, 200, {
            ok: true,
            sessionId: result.id,
            title: target === undefined ? null : sessionTitle(target.session.events),
          })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/outbox') {
        const { entries, overflowed } = outbox.collect()
        sendJson(res, 200, { entries, overflowed })
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/outbox') {
        try {
          const body = (await readJson(req)) as { sessionId?: unknown; source?: unknown; text?: unknown } | undefined
          const text = typeof body?.text === 'string' ? body.text : ''
          if (text.trim() === '') {
            sendJson(res, 400, { error: 'text is required' })
            return
          }
          const evicted = outbox.deposit({
            id: randomUUID(),
            sessionId: typeof body?.sessionId === 'string' ? body.sessionId : undefined,
            source: typeof body?.source === 'string' ? body.source : 'bridge',
            text,
            ts: Date.now(),
          })
          // Notify every subscribed client (the browser and Emacs) that new
          // inbox entries are ready.
          const notice = outboxMessage()
          for (const client of [...sseClients]) {
            try { client.write(notice) } catch { sseClients.delete(client) }
          }
          sendJson(res, 200, { ok: true, evicted })
        } catch (error: unknown) {
          const status = error instanceof PayloadTooLargeError ? 413 : 500
          sendJson(res, status, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'POST' && pathname === '/dsh-bridge/outbox/ack') {
        try {
          const body = (await readJson(req)) as { ids?: unknown } | undefined
          const ids = Array.isArray(body?.ids)
            ? body.ids.filter((id): id is string => typeof id === 'string')
            : []
          outbox.ack(ids)
          sendJson(res, 200, { ok: true, acked: ids.length })
        } catch (error: unknown) {
          const status = error instanceof PayloadTooLargeError ? 413 : 500
          sendJson(res, status, { error: error instanceof Error ? error.message : String(error) })
        }
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
          if (!targetableSessions().some(session => session.id === id)) {
            sendJson(res, 404, { error: `session ${id} is not live` })
            return
          }
          if (!hasAgent(id)) {
            sendJson(res, 409, { error: `session ${id} has no live agent` })
            return
          }
          selectedSessionId = id
          sendJson(res, 200, { ok: true, sessionId: id })
        } catch (error: unknown) {
          const status = error instanceof PayloadTooLargeError ? 413 : 500
          sendJson(res, status, { error: error instanceof Error ? error.message : String(error) })
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
          const result = resolveTarget(explicitId)
          if (result.kind === 'error') {
            sendJson(res, result.status, { error: result.message })
            return
          }
          const target = targetById(result.id)
          if (target === undefined) {
            sendJson(res, 409, { error: 'no active session' })
            return
          }
          target.agent.followup(createUserMessage({
            content: [{ type: 'text', text }],
            source: { kind: 'user' },
          }))
          sendJson(res, 200, {
            ok: true,
            sessionId: String(target.session.id),
            title: sessionTitle(target.session.events),
          })
        } catch (error: unknown) {
          const status = error instanceof PayloadTooLargeError ? 413 : 500
          sendJson(res, status, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }

      if (req.method === 'GET' && pathname === '/dsh-bridge/output') {
        const result = resolveTarget(url.searchParams.get('sessionId') ?? undefined)
        if (result.kind === 'error') {
          sendJson(res, result.status, { error: result.message })
          return
        }
        const target = targetById(result.id)
        if (target === undefined) {
          sendJson(res, 404, { error: 'no active session' })
          return
        }
        sendJson(res, 200, {
          sessionId: String(target.session.id),
          title: sessionTitle(target.session.events),
          text: latestAssistantText(target.agent.session.deriveMessages()),
        })
        return
      }

      // The prompt buffer's history: the session's user prompts, newest first.
      if (req.method === 'GET' && pathname === '/dsh-bridge/prompts') {
        const result = resolveTarget(url.searchParams.get('sessionId') ?? undefined)
        if (result.kind === 'error') {
          sendJson(res, result.status, { error: result.message })
          return
        }
        const target = targetById(result.id)
        if (target === undefined) {
          sendJson(res, 404, { error: 'no active session' })
          return
        }
        sendJson(res, 200, {
          sessionId: String(target.session.id),
          prompts: userPrompts(target.agent.session.deriveMessages()).reverse(),
        })
        return
      }

      sendJson(res, 404, { error: 'not found' })
    },
  }))
}
