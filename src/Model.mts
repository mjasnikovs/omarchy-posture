// Pure posture logic for the Omarchy Posture plugin.
//
// Compiled to Model.mjs at the repo root, which the QML files import. No Qt
// here. Every function returns a fresh object. Nothing is mutated.
//
// The helper sends seven keypoints per frame from a front webcam. A front
// view cannot measure clinical neck angles, so every check compares the
// frame to the user's own recorded good posture, "the slate". Default
// thresholds come from a labelled recording (bench/RESULTS.md).

/** Keypoint order from the helper. */
export const NOSE = 0
export const L_EYE = 1
export const R_EYE = 2
export const L_EAR = 3
export const R_EAR = 4
export const L_SHOULDER = 5
export const R_SHOULDER = 6
export const KEYPOINTS = 7

/** A keypoint below this score is not trusted. */
export const MIN_SCORE = 0.3

/** Frames the slate needs. 5 s at 5 fps is 25. */
export const SLATE_MIN_FRAMES = 10
export const SLATE_SECONDS = 5

/** Head turned further than this (nose offset in eye widths) means "looking elsewhere". */
export const YAW_LIMIT = 0.3

/** Once alerting, a check stays bad until it falls below this share of its threshold. */
export const CLEAR_RATIO = 0.7

/** No bad frame for this long, ending on a good one, and a bad spell is over. */
export const OK_GRACE_MS = 2000

/** No frame at all for this long (suspend, camera stall, clock jump) and the tracker starts over. */
export const FRAME_GAP_RESET_MS = 5000

/** Unknown frames in a row (away, turned, hidden) that end a bad spell. */
export const UNKNOWN_RESET_MS = 10000

export const MIN_DELAY_SECONDS = 10
export const MAX_DELAY_SECONDS = 600
export const DEFAULT_DELAY_SECONDS = 60

export const MIN_STRICTNESS = 1
export const MAX_STRICTNESS = 5
export const DEFAULT_STRICTNESS = 3
// Threshold multiplier per strictness step: 1 is lax, 5 is strict.
const STRICTNESS_FACTOR = [1.5, 1.25, 1, 0.8, 0.6]

export type CheckId = 'leanIn' | 'headDrop' | 'headTilt' | 'sideLean'
export const CHECKS: CheckId[] = ['leanIn', 'headDrop', 'headTilt', 'sideLean']

/** Base thresholds at strictness 3, in the units the reason text uses. */
export const BASE_THRESHOLD: Record<CheckId, number> = {
    leanIn: 15, // percent closer
    headDrop: 35, // percent of the nose-to-shoulder gap lost
    headTilt: 12, // degrees
    sideLean: 7 // degrees of shoulder-line tilt
}

// A slate spread this many standard deviations wide raises the threshold.
const NOISE_SIGMAS = 3

export type Point = [number, number, number]
export type Keypoints = Point[]

export interface Features {
    /** Shoulder width, px. */
    sw: number
    /** Eye distance, px. */
    ed: number
    /** Shoulder-line midpoint y minus nose y, px. Shrinks as the head drops. */
    gap: number
    /** Eye-line angle, degrees. */
    tilt: number
    /** Shoulder-line angle, degrees. */
    shoulders: number
    /** Nose x offset from the eye midpoint, in eye widths. Grows as the head turns. */
    yaw: number
}

export interface Slate {
    /** Median keypoints, for drawing. */
    kp: Keypoints
    f: Features
    /** Spread of each check value while the slate was recorded. */
    sd: Record<CheckId, number>
    n: number
    at: number
    /** The camera it was recorded on, as the helper names it. */
    cam?: string
}

export interface SlateStore {
    version: 1
    /** "*" is the default slate. Other keys are monitor names. */
    slates: Record<string, Slate>
}

export type SideMode = 'ignore' | 'perMonitor'

export interface Settings {
    checks: Record<CheckId, boolean>
    strictness: number
    delaySeconds: number
    sideMode: SideMode
}

export interface CheckResult {
    id: CheckId
    value: number
    threshold: number
    bad: boolean
}

export type Verdict =
    | {kind: 'unknown'; why: 'no-person' | 'low-score' | 'turned' | 'no-slate'}
    | {kind: 'ok' | 'bad'; checks: CheckResult[]; bad: CheckId[]}

export interface Tracker {
    /** Epoch ms the current bad spell began, or 0. */
    badSince: number
    /** Epoch ms of the first good frame after a bad one, or 0. */
    okSince: number
    /** Epoch ms of the first unknown frame in a row, or 0. */
    unknownSince: number
    alert: boolean
    /** Epoch ms of the last frame seen, or 0. */
    lastAt: number
    /** Checks that were bad in the latest bad frame. */
    reasons: CheckResult[]
}

// ---------------------------------------------------------------- settings

function clampInt(value: unknown, min: number, max: number, fallback: number): number {
    if (value === undefined || value === null || value === '') return fallback
    const n = Number(value)
    if (!isFinite(n)) return fallback
    return Math.max(min, Math.min(max, Math.round(n)))
}

export function boolSetting(raw: unknown, fallback: boolean): boolean {
    if (raw === undefined || raw === null) return fallback
    if (typeof raw === 'boolean') return raw
    const text = String(raw).toLowerCase()
    if (text === 'true' || text === '1' || text === 'yes' || text === 'on') return true
    if (text === 'false' || text === '0' || text === 'no' || text === 'off') return false
    return fallback
}

export function delaySeconds(raw: unknown): number {
    return clampInt(raw, MIN_DELAY_SECONDS, MAX_DELAY_SECONDS, DEFAULT_DELAY_SECONDS)
}

export function strictness(raw: unknown): number {
    return clampInt(raw, MIN_STRICTNESS, MAX_STRICTNESS, DEFAULT_STRICTNESS)
}

export function sideMode(raw: unknown): SideMode {
    return raw === 'perMonitor' ? 'perMonitor' : 'ignore'
}

/** Settings from the bar entry. Unknown or missing values fall back to defaults. */
export function settings(raw: Record<string, unknown>): Settings {
    return {
        checks: {
            leanIn: boolSetting(raw['checkLeanIn'], true),
            headDrop: boolSetting(raw['checkHeadDrop'], true),
            headTilt: boolSetting(raw['checkHeadTilt'], true),
            sideLean: boolSetting(raw['checkSideLean'], true)
        },
        strictness: strictness(raw['strictness']),
        delaySeconds: delaySeconds(raw['delaySeconds']),
        sideMode: sideMode(raw['sideMode'])
    }
}

export function threshold(id: CheckId, level: number, sd: number): number {
    const factor = STRICTNESS_FACTOR[strictness(level) - 1] ?? 1
    return Math.max(BASE_THRESHOLD[id] * factor, NOISE_SIGMAS * sd)
}

// ---------------------------------------------------------------- geometry

function dist(a: Point, b: Point): number {
    return Math.hypot(a[0] - b[0], a[1] - b[1])
}

// Image y grows downward. The camera does not mirror, so the person's left
// point sits at the larger x and a level line reads 0. Folding into
// [-90, 90] keeps a swapped pair from reading 180.
function lineAngle(a: Point, b: Point): number {
    let deg = (Math.atan2(a[1] - b[1], a[0] - b[0]) * 180) / Math.PI
    if (deg > 90) deg -= 180
    if (deg < -90) deg += 180
    return deg
}

// Lines repeat every 180 degrees (lineAngle folds into [-90, 90]), so the
// gap between two line angles wraps at 180, not 360.
export function signedLineDiff(a: number, b: number): number {
    let d = a - b
    while (d > 90) d -= 180
    while (d < -90) d += 180
    return d
}

export function lineAngleDiff(a: number, b: number): number {
    return Math.abs(signedLineDiff(a, b))
}

function isPoint(p: unknown): p is Point {
    return Array.isArray(p) && p.length === 3 && p.every(v => typeof v === 'number' && isFinite(v))
}

export function isKeypoints(kp: unknown): kp is Keypoints {
    return Array.isArray(kp) && kp.length === KEYPOINTS && kp.every(isPoint)
}

/** Features of one frame, or why there are none. */
export function features(kp: unknown): Features | 'no-person' | 'low-score' {
    if (!isKeypoints(kp)) return 'no-person'
    const need = [NOSE, L_EYE, R_EYE, L_SHOULDER, R_SHOULDER]
    if (need.some(i => (kp[i] as Point)[2] < MIN_SCORE)) return 'low-score'
    const nose = kp[NOSE] as Point
    const le = kp[L_EYE] as Point
    const re = kp[R_EYE] as Point
    const ls = kp[L_SHOULDER] as Point
    const rs = kp[R_SHOULDER] as Point
    const sw = dist(ls, rs)
    const ed = dist(le, re)
    if (sw < 1 || ed < 1) return 'low-score'
    return {
        sw,
        ed,
        gap: (ls[1] + rs[1]) / 2 - nose[1],
        tilt: lineAngle(le, re),
        shoulders: lineAngle(ls, rs),
        yaw: (nose[0] - (le[0] + re[0]) / 2) / ed
    }
}

/** How far each check has drifted from the slate, in reason-text units. */
export function checkValues(f: Features, s: Features): Record<CheckId, number> {
    const gapNow = f.gap / f.sw
    const gapSlate = s.gap / s.sw
    return {
        leanIn: 100 * (0.5 * (f.sw / s.sw + f.ed / s.ed) - 1),
        headDrop: gapSlate > 0 ? 100 * (1 - gapNow / gapSlate) : 0,
        headTilt: lineAngleDiff(f.tilt, s.tilt),
        sideLean: lineAngleDiff(f.shoulders, s.shoulders)
    }
}

// ------------------------------------------------------------------- slate

function median(xs: number[]): number {
    const s = xs.slice().sort((a, b) => a - b)
    const m = Math.floor(s.length / 2)
    if (s.length === 0) return 0
    return s.length % 2 ? (s[m] as number) : ((s[m - 1] as number) + (s[m] as number)) / 2
}

function stdev(xs: number[]): number {
    if (xs.length < 2) return 0
    const mean = xs.reduce((a, b) => a + b, 0) / xs.length
    return Math.sqrt(xs.reduce((a, b) => a + (b - mean) * (b - mean), 0) / (xs.length - 1))
}

/** A slate from the frames recorded while the user sat well, or null if too few were usable. */
export function buildSlate(frames: unknown[], at: number): Slate | null {
    const good: {kp: Keypoints; f: Features}[] = []
    for (const kp of frames) {
        const f = features(kp)
        if (typeof f !== 'string') good.push({kp: kp as Keypoints, f})
    }
    if (good.length < SLATE_MIN_FRAMES) return null
    const pick = (key: keyof Features) => median(good.map(g => g.f[key]))
    const f: Features = {
        sw: pick('sw'),
        ed: pick('ed'),
        gap: pick('gap'),
        tilt: pick('tilt'),
        shoulders: pick('shoulders'),
        yaw: pick('yaw')
    }
    const kp: Keypoints = []
    for (let i = 0; i < KEYPOINTS; i++) {
        kp.push([0, 1, 2].map(c => median(good.map(g => (g.kp[i] as Point)[c] as number))) as Point)
    }
    const values = good.map(g => checkValues(g.f, f))
    const sd = {} as Record<CheckId, number>
    for (const id of CHECKS) sd[id] = stdev(values.map(v => v[id]))
    // Tilt values are absolute, so a slate swaying ±8° would read as no
    // spread at all. Measure the angles' spread signed.
    sd.headTilt = stdev(good.map(g => signedLineDiff(g.f.tilt, f.tilt)))
    sd.sideLean = stdev(good.map(g => signedLineDiff(g.f.shoulders, f.shoulders)))
    return {kp, f, sd, n: good.length, at}
}

export function emptyStore(): SlateStore {
    return {version: 1, slates: {}}
}

function isSlate(s: unknown): s is Slate {
    if (!s || typeof s !== 'object') return false
    const o = s as Record<string, unknown>
    const f = o['f'] as Record<string, unknown> | undefined
    const sd = o['sd'] as Record<string, unknown> | undefined
    return (
        isKeypoints(o['kp'])
        && !!f
        && ['sw', 'ed', 'gap', 'tilt', 'shoulders', 'yaw'].every(k => typeof f[k] === 'number' && isFinite(f[k]))
        && !!sd
        && CHECKS.every(k => typeof sd[k] === 'number' && isFinite(sd[k]))
        && (f['sw'] as number) > 0
        && (f['ed'] as number) > 0
    )
}

/** The slate file. Anything malformed is dropped rather than trusted. */
export function parseStore(text: unknown): SlateStore {
    let raw: unknown
    try {
        raw = JSON.parse(String(text))
    } catch {
        return emptyStore()
    }
    const store = emptyStore()
    const slates = raw && typeof raw === 'object' ? (raw as Record<string, unknown>)['slates'] : null
    if (!slates || typeof slates !== 'object') return store
    for (const key of Object.keys(slates)) {
        const s = (slates as Record<string, unknown>)[key]
        if (isSlate(s)) store.slates[key] = s
    }
    return store
}

export function withSlate(store: SlateStore, key: string, slate: Slate): SlateStore {
    const slates: Record<string, Slate> = {}
    for (const k of Object.keys(store.slates)) slates[k] = store.slates[k] as Slate
    slates[key] = slate
    return {version: 1, slates}
}

/** The slate key a recording should be saved under. */
export function slateKey(mode: SideMode, monitor: string): string {
    return mode === 'perMonitor' && monitor ? monitor : '*'
}

/** The slate to judge against. Per-monitor mode falls back to the default slate. */
export function slateFor(store: SlateStore, mode: SideMode, monitor: string): Slate | null {
    if (mode === 'perMonitor' && monitor && store.slates[monitor]) return store.slates[monitor]
    return store.slates['*'] ?? null
}

/**
 * The side mode to judge with. A monitor without its own slate falls back to
 * the front-facing default slate, so a turned head must be filtered as in
 * 'ignore' mode, or every glance at that monitor reads as tilt.
 */
export function judgeMode(store: SlateStore, mode: SideMode, monitor: string): SideMode {
    return mode === 'perMonitor' && monitor && store.slates[monitor] ? 'perMonitor' : 'ignore'
}

// ----------------------------------------------------------------- judging

/**
 * One frame against the slate. `alerting` lowers each threshold to
 * CLEAR_RATIO of itself, so a card does not flicker at the edge.
 */
export function judge(kp: unknown, slate: Slate | null, s: Settings, alerting: boolean): Verdict {
    if (!slate) return {kind: 'unknown', why: 'no-slate'}
    const f = features(kp)
    if (typeof f === 'string') return {kind: 'unknown', why: f}
    // Turning to a side monitor fakes tilt and lean. With per-monitor slates
    // the slate already faces that way, so the turn is judged instead.
    if (s.sideMode === 'ignore' && Math.abs(f.yaw - slate.f.yaw) > YAW_LIMIT) return {kind: 'unknown', why: 'turned'}
    const values = checkValues(f, slate.f)
    const checks: CheckResult[] = []
    for (const id of CHECKS) {
        if (!s.checks[id]) continue
        const full = threshold(id, s.strictness, slate.sd[id])
        const limit = alerting ? full * CLEAR_RATIO : full
        checks.push({id, value: values[id], threshold: full, bad: values[id] > limit})
    }
    const bad = checks.filter(c => c.bad).map(c => c.id)
    return {kind: bad.length ? 'bad' : 'ok', checks, bad}
}

// ----------------------------------------------------------------- tracker

export function tracker(): Tracker {
    return {badSince: 0, okSince: 0, unknownSince: 0, alert: false, lastAt: 0, reasons: []}
}

/**
 * Advance the alert state by one verdict. A bad spell must last the whole
 * delay before the card shows. Short good blips (under OK_GRACE_MS) do not
 * break a spell. Brief unknown frames keep it. A long unknown stretch ends it.
 */
export function step(prev: Tracker, v: Verdict, now: number, delayMs: number): Tracker {
    // A spell measured across a gap would alert on the first frame after a
    // suspend. A clock that went backwards would never end one.
    const gap = prev.lastAt > 0 && (now - prev.lastAt > FRAME_GAP_RESET_MS || now < prev.lastAt)
    const t = gap ? tracker() : prev
    return {...advance(t, v, now, delayMs), lastAt: now}
}

function advance(t: Tracker, v: Verdict, now: number, delayMs: number): Tracker {
    if (v.kind === 'unknown') {
        const unknownSince = t.unknownSince || now
        if (now - unknownSince >= UNKNOWN_RESET_MS) {
            return {...tracker(), unknownSince}
        }
        // Unknown frames leave okSince alone: the spell ends once OK_GRACE_MS
        // have passed since the first good frame after the last bad one.
        // Resetting it here would let ok/unknown alternation keep a spell alive.
        return {...t, unknownSince}
    }
    if (v.kind === 'bad') {
        const badSince = t.badSince || now
        const reasons = v.checks.filter(c => c.bad)
        return {...t, badSince, okSince: 0, unknownSince: 0, alert: now - badSince >= delayMs, reasons}
    }
    // Good frame.
    if (!t.badSince) return tracker()
    const okSince = t.okSince || now
    if (now - okSince >= OK_GRACE_MS) return tracker()
    return {...t, okSince, unknownSince: 0}
}

/** The user closed the card. The delay starts over from now. */
export function dismiss(t: Tracker, now: number): Tracker {
    return {...t, alert: false, badSince: t.badSince ? now : 0}
}

// ------------------------------------------------------------------ text

export function reasonText(c: CheckResult): string {
    const v = Math.round(c.value)
    switch (c.id) {
        case 'leanIn':
            return `Leaning in: ${v}% closer than your slate`
        case 'headDrop':
            return `Head dropped: neck gap ${v}% shorter`
        case 'headTilt':
            return `Head tilted ${v}°`
        case 'sideLean':
            return `Shoulders tilted ${v}°`
    }
}

/** One line for the bar tooltip and the panel. `status` is the service's status word. */
export function statusText(status: string, detail: string): string {
    switch (status) {
        case 'missing':
            return 'Helper not found. Install omarchy-posture-helper.'
        case 'error':
            return detail ? `Helper error: ${detail}` : 'Helper error.'
        case 'paused':
            return 'Paused. Camera off.'
        case 'no-camera':
            return detail ? `No camera: ${detail}` : 'No camera.'
        case 'starting':
            return 'Starting.'
        case 'recording':
            return 'Recording your slate. Sit well and hold still.'
        case 'no-slate':
            return 'No slate yet. Sit well, then press Record slate.'
        case 'other-camera':
            return 'Your slate was made on another camera. Re-record it.'
        case 'alert':
            return 'Bad posture for too long.'
        case 'bad':
            return 'Drifting from your slate.'
        case 'ok':
            return 'Matches your slate.'
        default:
            return 'Watching. Cannot see you clearly.'
    }
}

export function checkLabel(id: CheckId): string {
    switch (id) {
        case 'leanIn':
            return 'Leaning in'
        case 'headDrop':
            return 'Head drop'
        case 'headTilt':
            return 'Head tilt'
        case 'sideLean':
            return 'Side lean'
    }
}
