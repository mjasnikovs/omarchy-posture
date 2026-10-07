import {describe, expect, test} from 'bun:test'
import {readFileSync} from 'node:fs'
import * as M from '../src/Model.mjs'

type Row = {t: number; label: string; kp: M.Keypoints}

// Keypoints of one labelled recording (bench/RESULTS.md). No images.
const ROWS: Row[] = readFileSync(new URL('fixtures/rec3.jsonl', import.meta.url), 'utf8')
    .trim()
    .split('\n')
    .map(l => JSON.parse(l) as Row)

const SLATE_FRAMES = ROWS.filter(r => r.label === 'slate').map(r => r.kp)
const DEFAULTS = M.settings({})

function slate(): M.Slate {
    const s = M.buildSlate(SLATE_FRAMES, 1)
    if (!s) throw new Error('fixture slate is empty')
    return s
}

// A level, centred person: shoulders 200 px apart, eyes 50 px apart.
function person(scale = 1, dy = 0, tilt = 0, score = 0.9): M.Keypoints {
    const c = 320
    const rot = (x: number, y: number, deg: number, cx: number, cy: number): [number, number] => {
        const r = (deg * Math.PI) / 180
        const dx = x - cx
        const dyy = y - cy
        return [cx + dx * Math.cos(r) - dyy * Math.sin(r), cy + dx * Math.sin(r) + dyy * Math.cos(r)]
    }
    const head = (x: number, y: number): M.Point => {
        const [rx, ry] = rot(c + (x - c) * scale, 200 + dy + (y - 200) * scale, tilt, c, 200 + dy)
        return [rx, ry, score]
    }
    const sh = (x: number): M.Point => [c + (x - c) * scale, 320, score]
    return [
        head(c, 200),
        head(c + 25, 175),
        head(c - 25, 175),
        head(c + 45, 185),
        head(c - 45, 185),
        sh(c + 100),
        sh(c - 100)
    ]
}

function steadySlate(): M.Slate {
    const s = M.buildSlate(
        Array.from({length: 25}, () => person()),
        1
    )
    if (!s) throw new Error('synthetic slate is empty')
    return s
}

describe('settings', () => {
    test('defaults', () => {
        expect(DEFAULTS).toEqual({
            checks: {leanIn: true, headDrop: true, headTilt: true, sideLean: true},
            strictness: 3,
            delaySeconds: 60,
            sideMode: 'ignore'
        })
    })

    test('values are clamped and parsed', () => {
        expect(M.delaySeconds(1)).toBe(10)
        expect(M.delaySeconds(9999)).toBe(600)
        expect(M.delaySeconds('garbage')).toBe(60)
        expect(M.strictness(0)).toBe(1)
        expect(M.strictness('5')).toBe(5)
        expect(M.sideMode('perMonitor')).toBe('perMonitor')
        expect(M.sideMode('nonsense')).toBe('ignore')
        expect(M.settings({checkHeadTilt: 'false'}).checks.headTilt).toBe(false)
    })

    test('a slate swaying both ways raises the tilt floor', () => {
        const frames = Array.from({length: 26}, (_, i) => person(1, 0, i % 2 ? 8 : -8))
        const s = M.buildSlate(frames, 1) as M.Slate
        expect(s.sd.headTilt).toBeGreaterThan(7)
        expect(M.threshold('headTilt', 3, s.sd.headTilt)).toBeGreaterThan(20)
    })

    test('strictness scales thresholds, slate noise sets a floor', () => {
        expect(M.threshold('headTilt', 3, 0)).toBe(12)
        expect(M.threshold('headTilt', 1, 0)).toBe(18)
        expect(M.threshold('headTilt', 5, 0)).toBeCloseTo(7.2)
        expect(M.threshold('headTilt', 3, 10)).toBe(30)
    })
})

describe('features', () => {
    test('rejects missing and low-confidence frames', () => {
        expect(M.features(null)).toBe('no-person')
        expect(M.features([[1, 2, 3]])).toBe('no-person')
        expect(M.features(person(1, 0, 0, 0.1))).toBe('low-score')
    })

    test('level person reads level', () => {
        const f = M.features(person())
        if (typeof f === 'string') throw new Error(f)
        expect(f.sw).toBeCloseTo(200)
        expect(f.ed).toBeCloseTo(50)
        expect(f.gap).toBeCloseTo(120)
        expect(f.tilt).toBeCloseTo(0)
        expect(f.shoulders).toBeCloseTo(0)
        expect(f.yaw).toBeCloseTo(0)
    })

    test('line angles wrap at 180 degrees', () => {
        expect(M.lineAngleDiff(88, -88)).toBeCloseTo(4)
        expect(M.lineAngleDiff(10, -5)).toBeCloseTo(15)
        expect(M.lineAngleDiff(-3, 3)).toBeCloseTo(6)
    })

    test('check values move the right way', () => {
        const base = M.features(person()) as M.Features
        const closer = M.checkValues(M.features(person(1.3)) as M.Features, base)
        expect(closer.leanIn).toBeCloseTo(30)
        const dropped = M.checkValues(M.features(person(1, 60)) as M.Features, base)
        expect(dropped.headDrop).toBeCloseTo(50)
        const tilted = M.checkValues(M.features(person(1, 0, 20)) as M.Features, base)
        expect(tilted.headTilt).toBeCloseTo(20)
        expect(tilted.sideLean).toBeCloseTo(0)
    })
})

describe('slate', () => {
    test('needs enough usable frames', () => {
        expect(M.buildSlate([person(), person()], 1)).toBeNull()
        expect(
            M.buildSlate(
                Array.from({length: 20}, () => person(1, 0, 0, 0.1)),
                1
            )
        ).toBeNull()
    })

    test('store round-trips and drops malformed slates', () => {
        const s = steadySlate()
        const store = M.withSlate(M.withSlate(M.emptyStore(), '*', s), 'DP-1', s)
        const back = M.parseStore(JSON.stringify(store))
        expect(Object.keys(back.slates).sort()).toEqual(['*', 'DP-1'])
        expect(M.parseStore('not json')).toEqual(M.emptyStore())
        expect(M.parseStore(JSON.stringify({slates: {'*': {kp: [], f: {}}}}))).toEqual(M.emptyStore())
    })

    test('a slate keeps the camera it was made on', () => {
        const s = {...steadySlate(), cam: '/dev/v4l/by-id/usb-cam-video-index0'}
        const back = M.parseStore(JSON.stringify(M.withSlate(M.emptyStore(), '*', s)))
        expect(back.slates['*']?.cam).toBe('/dev/v4l/by-id/usb-cam-video-index0')
        expect(M.statusText('other-camera', '')).toContain('another camera')
    })

    test('per-monitor mode picks the monitor slate, then the default', () => {
        const a = steadySlate()
        const b = {...steadySlate(), at: 2}
        const store = M.withSlate(M.withSlate(M.emptyStore(), '*', a), 'DP-1', b)
        expect(M.slateFor(store, 'perMonitor', 'DP-1')).toBe(b)
        expect(M.slateFor(store, 'perMonitor', 'DP-2')).toBe(a)
        expect(M.slateFor(store, 'ignore', 'DP-1')).toBe(a)
        expect(M.slateKey('ignore', 'DP-1')).toBe('*')
        expect(M.judgeMode(store, 'perMonitor', 'DP-1')).toBe('perMonitor')
        expect(M.judgeMode(store, 'perMonitor', 'DP-2')).toBe('ignore')
        expect(M.judgeMode(store, 'ignore', 'DP-1')).toBe('ignore')
        expect(M.slateKey('perMonitor', 'DP-1')).toBe('DP-1')
    })
})

describe('judge', () => {
    test('no slate or no person is unknown, never bad', () => {
        expect(M.judge(person(), null, DEFAULTS, false)).toEqual({kind: 'unknown', why: 'no-slate'})
        expect(M.judge(null, steadySlate(), DEFAULTS, false)).toEqual({kind: 'unknown', why: 'no-person'})
    })

    test('a turned head is unknown unless slates are per monitor', () => {
        const turned = person()
        turned[M.NOSE] = [345, 200, 0.9]
        expect(M.judge(turned, steadySlate(), DEFAULTS, false)).toEqual({kind: 'unknown', why: 'turned'})
        expect(M.judge(turned, steadySlate(), {...DEFAULTS, sideMode: 'perMonitor'}, false).kind).toBe('ok')
    })

    test('disabled checks are skipped', () => {
        const s = {...DEFAULTS, checks: {...DEFAULTS.checks, leanIn: false}}
        const v = M.judge(person(1.3), steadySlate(), s, false)
        expect(v.kind === 'unknown' ? [] : v.checks.map(c => c.id)).not.toContain('leanIn')
    })

    test('while alerting, a check clears only well below its threshold', () => {
        const nearly = person(1.12) // 12% closer: under 15, over 15 * 0.7
        expect(M.judge(nearly, steadySlate(), DEFAULTS, false).kind).toBe('ok')
        expect(M.judge(nearly, steadySlate(), DEFAULTS, true).kind).toBe('bad')
    })
})

describe('tracker', () => {
    const bad: M.Verdict = {kind: 'bad', checks: [{id: 'leanIn', value: 30, threshold: 15, bad: true}], bad: ['leanIn']}
    const ok: M.Verdict = {kind: 'ok', checks: [], bad: []}
    const unknown: M.Verdict = {kind: 'unknown', why: 'no-person'}
    const DELAY = 10000
    const T0 = new Date(2026, 9, 7, 9, 0, 0, 0).getTime()

    // Feeds one verdict every 200 ms (5 fps) from T0 + from to T0 + to.
    function run(t: M.Tracker, v: M.Verdict, from: number, to: number): M.Tracker {
        for (let ms = from; ms <= to; ms += 200) t = M.step(t, v, T0 + ms, DELAY)
        return t
    }

    test('alerts only after the delay', () => {
        let t = run(M.tracker(), bad, 0, 9800)
        expect(t.alert).toBe(false)
        t = M.step(t, bad, T0 + 10000, DELAY)
        expect(t.alert).toBe(true)
        expect(t.reasons.map(r => r.id)).toEqual(['leanIn'])
    })

    test('short good blips do not restart the delay', () => {
        let t = run(M.tracker(), bad, 0, 5000)
        t = run(t, ok, 5200, 6000)
        t = run(t, bad, 6200, 10000)
        expect(t.alert).toBe(true)
    })

    test('two seconds of good posture ends the spell and closes the card', () => {
        let t = run(M.tracker(), bad, 0, 12000)
        expect(t.alert).toBe(true)
        t = run(t, ok, 12200, 14000)
        expect(t.alert).toBe(true)
        t = M.step(t, ok, T0 + 14200, DELAY)
        expect(t.badSince).toBe(0)
        expect(t.alert).toBe(false)
    })

    test('good and unknown frames mixed end the spell once no bad frame came for 2 s', () => {
        let t = run(M.tracker(), bad, 0, 12000)
        for (let ms = 12200; ms <= 20000; ms += 200) t = M.step(t, (ms / 200) % 2 ? ok : unknown, T0 + ms, DELAY)
        expect(t.badSince).toBe(0)
        expect(t.alert).toBe(false)
    })

    test('brief unknown frames keep the spell, a long stretch ends it', () => {
        let t = run(M.tracker(), bad, 0, 5000)
        t = run(t, unknown, 5200, 9000)
        expect(t.badSince).toBe(T0)
        t = run(t, unknown, 9200, 15200)
        expect(t.badSince).toBe(0)
        expect(t.alert).toBe(false)
    })

    test('a gap in frames (suspend) starts over instead of alerting at once', () => {
        let t = run(M.tracker(), bad, 0, 5000)
        t = M.step(t, bad, T0 + 3600000, DELAY)
        expect(t.alert).toBe(false)
        expect(t.badSince).toBe(T0 + 3600000)
    })

    test('a clock that jumps back starts over', () => {
        let t = run(M.tracker(), bad, 0, 12000)
        t = M.step(t, ok, T0 + 1000, DELAY)
        expect(t.alert).toBe(false)
        expect(t.badSince).toBe(0)
    })

    test('dismiss restarts the delay', () => {
        let t = run(M.tracker(), bad, 0, 12000)
        t = M.dismiss(t, T0 + 12000)
        expect(t.alert).toBe(false)
        t = run(t, bad, 12200, 21800)
        expect(t.alert).toBe(false)
        t = M.step(t, bad, T0 + 22000, DELAY)
        expect(t.alert).toBe(true)
    })
})

describe('recorded session', () => {
    function rates(level: number) {
        const s = M.slateFor(M.withSlate(M.emptyStore(), '*', slate()), 'ignore', '')
        const out: Record<string, {known: number; bad: number; ids: Record<string, number>}> = {}
        for (const r of ROWS) {
            const v = M.judge(r.kp, s, M.settings({strictness: level}), false)
            const o = (out[r.label] ??= {known: 0, bad: 0, ids: {}})
            if (v.kind === 'unknown') continue
            o.known++
            if (v.kind === 'bad') o.bad++
            if (v.kind === 'bad') for (const id of v.bad) o.ids[id] = (o.ids[id] ?? 0) + 1
        }
        const pct = (label: string) => {
            const o = out[label]
            return o && o.known ? (100 * o.bad) / o.known : 0
        }
        const share = (label: string, id: string) => {
            const o = out[label]
            return o && o.known ? (100 * (o.ids[id] ?? 0)) / o.known : 0
        }
        return {pct, share}
    }

    test('default strictness flags bad postures and spares good ones', () => {
        const {pct, share} = rates(3)
        for (const label of ['lean_in', 'head_drop', 'head_tilt', 'side_lean']) expect(pct(label)).toBeGreaterThan(85)
        expect(pct('good')).toBeLessThan(5)
        expect(pct('side_look')).toBe(0)
        expect(share('lean_in', 'leanIn')).toBeGreaterThan(80)
        expect(share('head_drop', 'headDrop')).toBeGreaterThan(85)
        expect(share('head_tilt', 'headTilt')).toBeGreaterThan(85)
        expect(share('side_lean', 'sideLean')).toBeGreaterThan(85)
    })

    test('a stricter setting flags more, a laxer one less', () => {
        expect(rates(5).pct('good')).toBeGreaterThan(rates(3).pct('good'))
        expect(rates(1).pct('good_work')).toBeLessThan(rates(3).pct('good_work'))
    })

    test('with a delay, only the bad segments raise the card', () => {
        const s = slate()
        let t = M.tracker()
        const alertsIn = new Set<string>()
        for (const r of ROWS) {
            const v = M.judge(r.kp, s, DEFAULTS, t.alert)
            t = M.step(t, v, r.t, 8000)
            if (t.alert) alertsIn.add(r.label)
        }
        for (const label of ['lean_in', 'head_drop', 'head_tilt', 'side_lean']) expect(alertsIn).toContain(label)
        expect(alertsIn).not.toContain('good_work')
        expect(alertsIn).not.toContain('side_look')
    })
})

describe('text', () => {
    test('reasons read in plain units', () => {
        expect(M.reasonText({id: 'leanIn', value: 31.4, threshold: 15, bad: true})).toBe(
            'Leaning in: 31% closer than your slate'
        )
        expect(M.reasonText({id: 'headTilt', value: 25.6, threshold: 12, bad: true})).toBe('Head tilted 26°')
        expect(M.checkLabel('sideLean')).toBe('Side lean')
    })
})
