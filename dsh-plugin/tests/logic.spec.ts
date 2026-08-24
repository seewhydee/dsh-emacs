import { describe, expect, it } from 'vitest'
import {
  isSubagentChild,
  latestAssistantText,
  mergeSessionRows,
  parseBearerAuthorization,
  resolveTargetId,
  tokensEqual,
  type LiveSessionLike,
  type MessageLike,
  type SessionHeaderLike,
} from '../src/logic.ts'

function liveSession(id: string, opts: { cwd?: string; createdAt?: number; eventTimes?: number[] } = {}): LiveSessionLike {
  return {
    id,
    header: { cwd: opts.cwd, createdAt: opts.createdAt ?? 0 },
    events: (opts.eventTimes ?? []).map(time => ({ time })),
  }
}

function header(id: string, opts: { cwd?: string; createdAt?: number; origin?: string } = {}): SessionHeaderLike {
  return { id, cwd: opts.cwd, createdAt: opts.createdAt ?? 0, origin: opts.origin }
}

function message(role: string, blocks: Array<{ type: string; text?: string }>): MessageLike {
  return { role, content: blocks }
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
    expect(rows).toEqual([{ id: 'a', cwd: null, live: true, lastActive: 30, createdAt: 10 }])
  })

  it('falls back to createdAt when a live session has no events', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 10 })], [])
    expect(rows[0]!.lastActive).toBe(10)
  })

  it('marks persisted sessions and skips subagent headers', () => {
    const rows = mergeSessionRows(
      [],
      [header('a', { createdAt: 1 }), header('sub', { origin: 'subagent' })],
    )
    expect(rows).toEqual([{ id: 'a', cwd: null, live: false, createdAt: 1 }])
  })

  it('dedupes persisted sessions that are already live', () => {
    const rows = mergeSessionRows([liveSession('a', { createdAt: 1 })], [header('a', { createdAt: 1 })])
    expect(rows).toHaveLength(1)
    expect(rows[0]!.live).toBe(true)
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
