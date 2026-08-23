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
// Scope-reducing decisions (see PLAN.md): one configured session, on-demand
// output pull, submit-not-draft.

import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Context } from '@deepseek-ai/cordis'
import {
  installModelSelection,
  type Agent,
  type ModelSelection,
  type ModelSelectionRef,
} from '@deepseek-ai/dsh-agent'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { SessionId } from '@deepseek-ai/dsh-session'

export const name = 'dsh-bridge'

export const inject = ['agents', 'webServer']

export interface Config {
  /** The one session the bridge targets; created on first send and reused. */
  sessionId?: string
  /** Absolute working directory for a newly created session. */
  cwd?: string
  /** Agent preset id; omitted resolves the deployment default preset. */
  presetId?: string
}

/** Minimal face of the optional `webServer` service. */
interface WebServerService {
  register(route: {
    kind: 'exact' | 'prefix'
    path: string
    handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>
  }): () => void
}

/** Minimal face of the optional `agentDefaultModel` service. */
interface DefaultModelService {
  currentSelection(): ModelSelection
}

/** Minimal face of the optional `agentPresets` service. */
interface PresetService {
  resolve(id?: string): Promise<{ id: string }>
  mount(agentCtx: Context, id: string): Promise<unknown>
}

/** An owned agent whose disposer releases it from the registry. */
interface OwnedAgent {
  agent: Agent
  dispose(): Promise<void>
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

export function apply(ctx: Context, config: Config = {}): void {
  // Guaranteed by `inject`: the plugin stays pending until the Web server mounts.
  const webServer = ctx.get('webServer') as WebServerService

  const sessionId = SessionId(config.sessionId ?? 'dsh-emacs')
  const cwd = config.cwd ?? process.cwd()
  const ownedAgents = new Set<OwnedAgent>()

  /** Compose a fresh agent exactly the way the Web gateway does. */
  async function createAgent(): Promise<OwnedAgent> {
    const defaultModel = ctx.get('agentDefaultModel') as DefaultModelService | undefined
    if (defaultModel === undefined) {
      throw new Error('dsh-bridge: ctx.agentDefaultModel is unavailable')
    }
    const selection = defaultModel.currentSelection()
    const presets = ctx.get('agentPresets') as PresetService | undefined

    const installSelection = (agentCtx: Context): void => {
      const ref: ModelSelectionRef = {
        current: { provider: selection.provider, model: selection.model },
        assembled: undefined,
      }
      installModelSelection(agentCtx, ref)
    }

    let agentPreset: string | undefined
    let setup: (agentCtx: Context) => Promise<void>
    if (presets === undefined) {
      setup = async (agentCtx) => { installSelection(agentCtx) }
    } else {
      const resolvedId = (await presets.resolve(config.presetId)).id
      agentPreset = resolvedId
      setup = async (agentCtx) => {
        installSelection(agentCtx)
        await presets.mount(agentCtx, resolvedId)
      }
    }

    const handle = await ctx.agents.create({
      sessionId,
      agentOptions: { provider: selection.provider, model: selection.model },
      meta: { cwd, ...(agentPreset === undefined ? {} : { agentPreset }) },
      setup,
    })
    ownedAgents.add(handle)
    return handle
  }

  /** In-flight creation, so concurrent sends share one agent. */
  let creating: Promise<OwnedAgent> | undefined

  /** The live agent for `sessionId`, creating it on first use. */
  async function ensureAgent(): Promise<Agent> {
    const live = ctx.agents.get(sessionId)
    if (live !== undefined) return live
    creating ??= createAgent().finally(() => { creating = undefined })
    return (await creating).agent
  }

  // Release any agent this plugin created when the plugin unloads;
  // cordis awaits async disposers, so unload waits for the releases.
  ctx.effect(() => async () => {
    const handles = [...ownedAgents]
    ownedAgents.clear()
    await Promise.all(handles.map(handle => handle.dispose()))
  })

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
          const agent = await ensureAgent()
          agent.followup(createUserMessage({
            content: [{ type: 'text', text }],
            source: { kind: 'user' },
          }))
          sendJson(res, 200, { ok: true, sessionId: String(sessionId) })
        } catch (error: unknown) {
          sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
        }
        return
      }
      if (req.method === 'GET' && pathname === '/dsh-bridge/output') {
        const agent = ctx.agents.get(sessionId)
        if (agent === undefined) {
          sendJson(res, 404, { error: 'no live session', sessionId: String(sessionId) })
          return
        }
        sendJson(res, 200, { sessionId: String(sessionId), text: latestAssistantText(agent) })
        return
      }
      sendJson(res, 404, { error: 'not found' })
    },
  }))
}
