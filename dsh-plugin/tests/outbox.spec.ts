import { describe, expect, it } from 'vitest'
import { Outbox, type OutboxEntry } from '../src/outbox.ts'

let counter = 0
function entry(overrides: Partial<OutboxEntry> = {}): OutboxEntry {
  counter += 1
  return { id: `id-${counter}`, source: 'bridge', text: `text ${counter}`, ts: counter, ...overrides }
}

describe('Outbox', () => {
  it('returns a deposited entry on collect, oldest-first', () => {
    const outbox = new Outbox()
    const first = entry({ id: 'a', ts: 1 })
    const second = entry({ id: 'b', ts: 2 })
    outbox.deposit(first)
    outbox.deposit(second)
    const { entries } = outbox.collect()
    expect(entries.map(e => e.id)).toEqual(['a', 'b'])
  })

  it('collect returns a detached copy', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    const collected = outbox.collect().entries
    collected[0]!.text = 'mutated'
    expect(outbox.collect().entries[0]!.text).not.toBe('mutated')
  })

  it('evicts the oldest entry at capacity and reports the overflow', () => {
    const outbox = new Outbox(2)
    outbox.deposit(entry({ id: 'a' }))
    outbox.deposit(entry({ id: 'b' }))
    const evicted = outbox.deposit(entry({ id: 'c' }))
    expect(evicted).toBe(true)
    const { entries, overflowed } = outbox.collect()
    expect(entries.map(e => e.id)).toEqual(['b', 'c'])
    expect(overflowed).toBe(true)
    // The overflow latch clears after one collect.
    expect(outbox.collect().overflowed).toBe(false)
  })

  it('does not evict when below capacity', () => {
    const outbox = new Outbox(2)
    outbox.deposit(entry({ id: 'a' }))
    expect(outbox.deposit(entry({ id: 'b' }))).toBe(false)
  })

  it('ack removes the named entries and leaves the rest', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    outbox.deposit(entry({ id: 'b' }))
    outbox.deposit(entry({ id: 'c' }))
    outbox.ack(['a', 'c'])
    expect(outbox.collect().entries.map(e => e.id)).toEqual(['b'])
    expect(outbox.size).toBe(1)
  })

  it('ignores unknown ids in ack', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    outbox.ack(['nope'])
    expect(outbox.collect().entries.map(e => e.id)).toEqual(['a'])
  })

  it('collect after ack returns empty', () => {
    const outbox = new Outbox()
    outbox.deposit(entry({ id: 'a' }))
    outbox.ack(['a'])
    expect(outbox.collect().entries).toEqual([])
  })
})
