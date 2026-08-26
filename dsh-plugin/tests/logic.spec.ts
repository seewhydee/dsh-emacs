import { describe, expect, it } from 'vitest'
import {
  draftMessage,
  hostnameOf,
  isLoopbackAddress,
  isLoopbackHostname,
  isLoopbackOrigin,
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
  type MessageLike,
  type SessionEventLike,
  type SessionHeaderLike,
} from '../src/logic.ts'

function liveSession(id: string, opts: { cwd?: string; createdAt?: number; eventTimes?: number[]; events?: SessionEventLike[]; running?: boolean } = {}): LiveSessionLike {
  return {
    id,
    header: { cwd: opts.cwd, createdAt: opts.createdAt ?? 0 },
    events: opts.events ?? (opts.eventTimes ?? []).map(time => ({ time })),
    running: opts.running ?? false,
  }
}

function header(id: string, opts: { cwd?: string; createdAt?: number; origin?: string; title?: string | null } = {}): SessionHeaderLike {
  return { id, cwd: opts.cwd, createdAt: opts.createdAt ?? 0, origin: opts.origin, title: opts.title }
}

function message(role: string, blocks: Array<{ type: string; text?: string }>): MessageLike {
  return { role, content: blocks }
}

function titleEvent(title: string): SessionEventLike {
  return { time: 1, type: 'session/title', data: { title } }
}

describe('latestAssistantText', () => {
  it('returns the empty string when there are no messages', () => {
    expect(latestAssistantText([])).toBe('')
  })

  it('ignores non-assistant messages', () => {
    expect(latestAssistantText([message('user', [{ type: 'text', text: 'hello' }])])).toBe('')
  })

  it('returns the newest assistant text', () => {
    const messages = [
      message('assistant', [{ type: 'text', text: 'first' }]),
      message('assistant', [{ type: 'text', text: 'second' }]),
    ]
    expect(latestAssistantText(messages)).toBe('second')
  })

  it('joins multiple text blocks in one assistant message', () => {
    const messages = [
      message('assistant', [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }]),
    ]
    expect(latestAssistantText(messages)).toBe('ab')
  })

  it('falls through tool-call-only assistant turns to the previous text', () => {
    const messages = [
      message('assistant', [{ type: 'text', text: 'real answer' }]),
      message('assistant', [{ type: 'tool-call' }]),
    ]
    expect(latestAssistantText(messages)).toBe('real answer')
  })
})

describe('userPrompts', () => {
  it('returns user text blocks in order, skipping other roles', () => {
    const messages = [
      message('user', [{ type: 'text', text: 'first' }]),
      message('assistant', [{ type: 'text', text: 'reply' }]),
      message('user', [{ type: 'text', text: 'second' }]),
    ]
    expect(userPrompts(messages)).toEqual(['first', 'second'])
  })

  it('joins multiple text blocks with newlines and drops whitespace-only prompts', () => {
    const messages = [
      message('user', [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }]),
      message('user', [{ type: 'text', text: '   ' }]),
    ]
    expect(userPrompts(messages)).toEqual(['a\nb'])
  })

  it('returns an empty list with no messages', () => {
    expect(userPrompts([])).toEqual([])
  })
})

describe('isSubagentChild', () => {
  it('treats subagent origin as a child', () => {
    expect(isSubagentChild('subagent', false)).toBe(true)
  })

  it('treats parent ownership as a child regardless of origin', () => {
    expect(isSubagentChild(undefined, true)).toBe(true)
  })

  it('treats a top-level, unowned session as targetable', () => {
    expect(isSubagentChild(undefined, false)).toBe(false)
  })
})

describe('mergeSessionRows', () => {
  it('marks live sessions and computes lastActive from the newest event', () => {
    const rows = mergeSessionRows(
      [liveSession('a', { createdAt: 10, eventTimes: [20, 30] })],
      [],
    )
    expect(rows).toEqual([{ id: 'a', title: null, cwd: null, live: true, running: false, lastActive: 30, createdAt: 10 }])
  })

  it('passes through the live running flag', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 10, running: true })], [])
    expect(rows[0]!.running).toBe(true)
  })

  it('folds the live title from the latest session/title event', () => {
    const rows = mergeSessionRows(
      [liveSession('a', { createdAt: 10, events: [titleEvent('first'), titleEvent('latest')] })],
      [],
    )
    expect(rows[0]!.title).toBe('latest')
  })

  it('falls back to createdAt when a live session has no events', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 10 })], [])
    expect(rows[0]!.lastActive).toBe(10)
  })

  it('marks persisted sessions as not running and skips subagent headers', () => {
    const rows = mergeSessionRows(
      [],
      [header('a', { createdAt: 1 }), header('sub', { origin: 'subagent' })],
    )
    expect(rows).toEqual([{ id: 'a', title: null, cwd: null, live: false, running: false, createdAt: 1 }])
  })

  it('passes through a persisted title', () => {
    const rows = mergeSessionRows([], [header('a', { createdAt: 1, title: 'saved title' })])
    expect(rows[0]!.title).toBe('saved title')
  })

  it('dedupes persisted sessions that are already live', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 1 })], [header('a', { createdAt: 1 })])
    expect(rows).toHaveLength(1)
    expect(rows[0]!.live).toBe(true)
  })
})

describe('sessionTitle', () => {
  it('returns null when there are no events', () => {
    expect(sessionTitle([])).toBeNull()
  })

  it('returns null when no session/title event exists', () => {
    expect(sessionTitle([{ time: 1, type: 'user/message', data: {} }])).toBeNull()
  })

  it('returns the latest title (last-wins)', () => {
    expect(sessionTitle([titleEvent('old'), titleEvent('new')])).toBe('new')
  })

  it('ignores non-title events interleaved with titles', () => {
    expect(sessionTitle([
      titleEvent('a'),
      { time: 2, type: 'user/message', data: {} },
      titleEvent('b'),
    ])).toBe('b')
  })

  it('returns null for a malformed or empty title payload', () => {
    expect(sessionTitle([{ time: 1, type: 'session/title' }])).toBeNull()
    expect(sessionTitle([{ time: 1, type: 'session/title', data: null }])).toBeNull()
    expect(sessionTitle([{ time: 1, type: 'session/title', data: { title: '' } }])).toBeNull()
    expect(sessionTitle([{ time: 1, type: 'session/title', data: { title: 42 } }])).toBeNull()
  })
})

describe('workspaceTitlesBySession', () => {
  it('maps session ids to their workspace titles', () => {
    const map = workspaceTitlesBySession([
      { title: 'alpha', sessionIds: ['s1', 's2'] },
      { title: 'beta', sessionIds: ['s3'] },
    ])
    expect(map.get('s1')).toBe('alpha')
    expect(map.get('s2')).toBe('alpha')
    expect(map.get('s3')).toBe('beta')
    expect(map.get('s4')).toBeUndefined()
  })

  it('returns an empty map for no workspaces', () => {
    expect(workspaceTitlesBySession([]).size).toBe(0)
  })
})

describe('resolveTargetId', () => {
  const live = [liveSession('a', { createdAt: 10, eventTimes: [40] }), liveSession('b', { createdAt: 20, eventTimes: [50] })]

  it('honors an explicit id', () => {
    const result = resolveTargetId('a', undefined, live, () => true)
    expect(result).toEqual({ kind: 'target', id: 'a' })
  })

  it('rejects an explicit id that is not live with 404', () => {
    const result = resolveTargetId('nope', undefined, live, () => true)
    expect(result).toEqual({ kind: 'error', status: 404, message: 'session nope is not live' })
  })

  it('rejects a live id with no agent with 409', () => {
    const result = resolveTargetId('a', undefined, live, id => id !== 'a')
    expect(result).toEqual({ kind: 'error', status: 409, message: 'session a has no live agent' })
  })

  it('honors the selected id when present', () => {
    const result = resolveTargetId(undefined, 'b', live, () => true)
    expect(result).toEqual({ kind: 'target', id: 'b' })
  })

  it('falls back to last-active when the selected id is dead', () => {
    const result = resolveTargetId(undefined, 'gone', live, () => true)
    expect(result).toEqual({ kind: 'target', id: 'b' })
  })

  it('picks the most recently active session when nothing is pinned', () => {
    const result = resolveTargetId(undefined, undefined, live, () => true)
    expect(result).toEqual({ kind: 'target', id: 'b' })
  })

  it('reports no active session with 409 when nothing is targetable', () => {
    const result = resolveTargetId(undefined, undefined, [], () => true)
    expect(result).toEqual({ kind: 'error', status: 409, message: 'no active session' })
  })
})

describe('parseBearerAuthorization', () => {
  it('extracts a bearer token', () => {
    expect(parseBearerAuthorization('Bearer abc123')).toBe('abc123')
  })

  it('returns undefined for a missing header', () => {
    expect(parseBearerAuthorization(undefined)).toBeUndefined()
  })

  it('returns undefined for a non-bearer scheme', () => {
    expect(parseBearerAuthorization('Basic abc123')).toBeUndefined()
  })

  it('returns undefined for an empty token', () => {
    expect(parseBearerAuthorization('Bearer ')).toBeUndefined()
  })
})

describe('tokensEqual', () => {
  it('matches identical tokens', () => {
    expect(tokensEqual('secret', 'secret')).toBe(true)
  })

  it('rejects differing tokens of the same length', () => {
    expect(tokensEqual('secret', 'sekret')).toBe(false)
  })

  it('rejects differing lengths without throwing', () => {
    expect(tokensEqual('secret', 'x')).toBe(false)
  })
})

describe('token-vend origin fence', () => {
  it('strips the port from a Host header, handling IPv6 brackets', () => {
    expect(hostnameOf('localhost:3080')).toBe('localhost')
    expect(hostnameOf('127.0.0.1:3080')).toBe('127.0.0.1')
    expect(hostnameOf('[::1]:3080')).toBe('::1')
    expect(hostnameOf('localhost')).toBe('localhost')
  })

  it('recognises loopback hostnames', () => {
    expect(isLoopbackHostname('localhost')).toBe(true)
    expect(isLoopbackHostname('127.0.0.1')).toBe(true)
    expect(isLoopbackHostname('::1')).toBe(true)
    expect(isLoopbackHostname('192.168.1.5')).toBe(false)
  })

  it('recognises loopback origins', () => {
    expect(isLoopbackOrigin('http://localhost:3080')).toBe(true)
    expect(isLoopbackOrigin('http://127.0.0.1:3080')).toBe(true)
    expect(isLoopbackOrigin('https://evil.com')).toBe(false)
  })

  it('accepts a same-origin request', () => {
    expect(tokenRequestsSameOrigin('localhost:3080', undefined)).toBe(true)
    expect(tokenRequestsSameOrigin('127.0.0.1:8080', 'http://127.0.0.1:8080')).toBe(true)
  })

  it('rejects a DNS-rebinding Host and a cross-origin page', () => {
    expect(tokenRequestsSameOrigin('evil.com', undefined)).toBe(false)
    expect(tokenRequestsSameOrigin('localhost:3080', 'http://evil.com')).toBe(false)
  })

  it('rejects a missing Host', () => {
    expect(tokenRequestsSameOrigin(undefined, undefined)).toBe(false)
  })

  it('recognises loopback socket peer addresses, including IPv4-mapped', () => {
    expect(isLoopbackAddress('127.0.0.1')).toBe(true)
    expect(isLoopbackAddress('127.0.0.2')).toBe(true)
    expect(isLoopbackAddress('::1')).toBe(true)
    expect(isLoopbackAddress('::ffff:127.0.0.1')).toBe(true)
  })

  it('rejects non-loopback and missing peer addresses', () => {
    expect(isLoopbackAddress('192.168.1.5')).toBe(false)
    expect(isLoopbackAddress('::ffff:192.168.1.5')).toBe(false)
    expect(isLoopbackAddress('2001:db8::1')).toBe(false)
    expect(isLoopbackAddress(undefined)).toBe(false)
  })
})

describe('draftMessage', () => {
  it('emits one SSE data frame with the draft payload', () => {
    expect(draftMessage('session-1', 'hello')).toBe(
      'data: {"kind":"draft","sessionId":"session-1","text":"hello"}\n\n',
    )
  })
})

describe('outboxMessage', () => {
  it('emits one SSE data frame signalling new outbox entries', () => {
    expect(outboxMessage()).toBe('data: {"kind":"outbox"}\n\n')
  })
})
