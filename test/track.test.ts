// Behaviour tests for billnotch/scripts/track.sh, the plugin's session tracker.
// The script runs for real under `sh` against a fake BillNotch API; block
// timings are set by writing the on-disk session state directly.
//
//   bun test integrations/claude-code

import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'bun:test'

const SCRIPT = join(import.meta.dir, '..', 'billnotch', 'scripts', 'track.sh')
const PROJECT_A = '01a20000-0000-7000-8000-00000000000a'
const PROJECT_B = '01a20000-0000-7000-8000-00000000000b'
const DELETED = '01a20000-0000-7000-8000-0000000000de'

interface Entry {
  activity: string
  startedAt: string
  endedAt: string
  clientEventId: string
  projectId?: string
  isBillable?: boolean
}

type Mode = 'ok' | 'reject-deleted' | 'unknown-route' | 'unauthorized'

let mode: Mode = 'ok'
let accepted: Entry[] = []
let requests = 0
let authorizations: (string | null)[] = []
let server: ReturnType<typeof Bun.serve>
let data: string
let project: string

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })

beforeAll(() => {
  server = Bun.serve({
    port: 0,
    async fetch(request) {
      requests += 1
      authorizations.push(request.headers.get('authorization'))
      if (mode === 'unauthorized') {
        return json(401, { error: { code: 'UNAUTHORIZED', message: 'Invalid API key.' } })
      }
      if (mode === 'unknown-route') {
        return json(404, { error: { code: 'ROUTE_NOT_FOUND', message: 'Route not found.' } })
      }
      const { entries } = (await request.json()) as { entries: Entry[] }
      // The real API resolves every project first and fails the whole batch on one
      // it cannot find.
      if (mode === 'reject-deleted' && entries.some((entry) => entry.projectId === DELETED)) {
        return json(404, {
          error: { code: 'ENTITY_NOT_FOUND', message: `Project "${DELETED}" was not found.` },
        })
      }
      accepted.push(...entries)
      return json(201, { created: entries.length, entries: [] })
    },
  })
})

afterAll(() => {
  void server.stop(true)
})

beforeEach(async () => {
  // Let detached uploads from the previous test finish before resetting state.
  if (data) await settle(0)
  mode = 'ok'
  accepted = []
  requests = 0
  authorizations = []
  data = mkdtempSync(join(tmpdir(), 'bn-data-'))
  project = mkdtempSync(join(tmpdir(), 'bn-repo-'))
})

const now = () => Math.floor(Date.now() / 1000)

function env(extra: Record<string, string> = {}) {
  return {
    PATH: process.env.PATH ?? '/usr/bin:/bin',
    CLAUDE_PLUGIN_OPTION_API_KEY: 'tt_test',
    CLAUDE_PLUGIN_OPTION_API_URL: `http://127.0.0.1:${server.port}`,
    CLAUDE_PLUGIN_DATA: data,
    CLAUDE_PROJECT_DIR: project,
    ...extra,
  }
}

// Async on purpose: the detached upload calls back into the fake API, which lives
// on this event loop, so a blocking spawn would deadlock against it.
async function hook(
  event: string,
  session = 'sess-1',
  extra: Record<string, string> = {},
  overrides: Record<string, string> = {},
) {
  const child = Bun.spawn(['sh', SCRIPT], {
    stdin: Buffer.from(JSON.stringify({ session_id: session, hook_event_name: event, ...extra })),
    stdout: 'pipe',
    env: env(overrides),
  })
  const [code, out] = await Promise.all([child.exited, new Response(child.stdout).text()])
  expect(code).toBe(0)
  // Anything printed on SessionStart / UserPromptSubmit would land in Claude's context.
  expect(out).toBe('')
}

function setState(
  session: string,
  state: { start: number; last: number; busy: 0 | 1; project?: string; billable?: boolean },
) {
  mkdirSync(join(data, 'sessions'), { recursive: true })
  writeFileSync(
    join(data, 'sessions', session),
    [
      `start=${state.start}`,
      `last=${state.last}`,
      `busy=${state.busy}`,
      'label=repo',
      `project=${state.project ?? ''}`,
      `billable=${state.billable ? 'true' : ''}`,
      '',
    ].join('\n'),
  )
}

/** Shift the open block's start back, as if the session had been running that long. */
function backdate(session: string, seconds: number) {
  const file = join(data, 'sessions', session)
  const text = Bun.file(file)
  return text.text().then((body) =>
    writeFileSync(
      file,
      body.replace(/^start=(\d+)$/m, (_, start) => `start=${Number(start) - seconds}`),
    ),
  )
}

const files = (dir: string) =>
  existsSync(join(data, dir)) ? readdirSync(join(data, dir)).filter((f) => f.endsWith('.json')) : []

async function settle(expected: number) {
  // Uploads run detached from the hook; wait for them to land.
  for (let i = 0; i < 100; i++) {
    if (accepted.length >= expected && !existsSync(join(data, 'queue', '.lock'))) return
    await Bun.sleep(50)
  }
}

const seconds = (entry: Entry) => (Date.parse(entry.endedAt) - Date.parse(entry.startedAt)) / 1000

function link(projectId: string, billable: boolean) {
  writeFileSync(join(project, '.billnotch.json'), JSON.stringify({ projectId, billable }))
}

describe('track.sh', () => {
  it('records a session as one block of active time', async () => {
    await hook('SessionStart')
    await hook('UserPromptSubmit')
    await backdate('sess-1', 600)
    await hook('Stop')
    await hook('SessionEnd')
    await settle(1)

    expect(accepted).toHaveLength(1)
    expect(seconds(accepted[0])).toBeGreaterThanOrEqual(600)
    expect(seconds(accepted[0])).toBeLessThan(610)
    expect(files('queue')).toEqual([])
    // Sent through curl's stdin config, so it never appears in the process list.
    expect(authorizations).toEqual(['Bearer tt_test'])
  })

  it('keeps its state private to the user', async () => {
    await hook('UserPromptSubmit')
    const mode = statSync(join(data, 'sessions', 'sess-1')).mode & 0o777
    expect(mode).toBe(0o600)
  })

  it('ignores a key that is not a BillNotch key', async () => {
    await hook(
      'UserPromptSubmit',
      'sess-1',
      {},
      { CLAUDE_PLUGIN_OPTION_API_KEY: 'tt_x"\nurl = "http://evil' },
    )
    expect(existsSync(join(data, 'sessions', 'sess-1'))).toBe(false)
  })

  it('closes a turn left running by a crash when the session is resumed', async () => {
    // Crashed mid-turn a day ago, an hour into the block.
    setState('sess-1', { start: now() - 90_000, last: now() - 86_400, busy: 1 })

    await hook('SessionStart', 'sess-1', { source: 'resume' })
    await hook('UserPromptSubmit')
    await hook('Stop')
    await hook('SessionEnd')
    await settle(1)

    // The crashed block keeps the hour it had; the downtime is never billed.
    expect(accepted.map(seconds)).toEqual([3600])
  })

  it('does not stretch a long-dead running turn even without a resume event', async () => {
    setState('sess-1', { start: now() - 90_000, last: now() - 86_400, busy: 1 })

    await hook('UserPromptSubmit')
    await hook('Stop')
    await hook('SessionEnd')
    await settle(1)

    expect(accepted.map(seconds)).toEqual([3600])
  })

  it('splits the block when the repository is relinked mid-session', async () => {
    setState('sess-1', { start: now() - 7200, last: now() - 60, busy: 0, project: PROJECT_A })
    link(PROJECT_B, true)

    await hook('UserPromptSubmit')
    await backdate('sess-1', 600)
    await hook('Stop')
    await hook('SessionEnd')
    await settle(2)

    const byProject = Object.fromEntries(accepted.map((entry) => [entry.projectId, entry]))
    // The two hours already tracked stay on A, non-billable, exactly as tracked.
    expect(seconds(byProject[PROJECT_A])).toBeGreaterThanOrEqual(7200)
    expect(seconds(byProject[PROJECT_A])).toBeLessThan(7210)
    expect(byProject[PROJECT_A].isBillable).toBe(false)
    // Only the time after the link goes to B.
    expect(seconds(byProject[PROJECT_B])).toBeLessThan(610)
    expect(byProject[PROJECT_B].isBillable).toBe(true)
  })

  it('keeps valid blocks flowing when one points at a deleted project', async () => {
    mode = 'reject-deleted'
    setState('sess-good', { start: now() - 1800, last: now() - 600, busy: 0 })
    setState('sess-bad', { start: now() - 3600, last: now() - 2400, busy: 0, project: DELETED })

    // Another session's start sweeps both idle blocks into the queue and uploads.
    await hook('SessionStart', 'sess-3')
    await settle(2)

    expect(accepted).toHaveLength(2)
    // The orphaned block still lands, uncategorized, rather than being dropped.
    const orphan = accepted.find((entry) => seconds(entry) === 1200 && !entry.projectId)
    expect(orphan).toBeDefined()
    expect(accepted.some((entry) => entry.projectId === DELETED)).toBe(false)
    expect(files('queue')).toEqual([])
    expect(files('rejected')).toEqual([])
  })

  it('keeps everything queued when the API URL is wrong or the key is refused', async () => {
    setState('sess-a', { start: now() - 1800, last: now() - 600, busy: 0 })

    mode = 'unknown-route'
    await hook('SessionStart', 'sess-3')
    await settle(0)
    await Bun.sleep(300)
    expect(files('queue')).toHaveLength(1)
    expect(files('rejected')).toEqual([])
    expect(requests).toBe(1) // no per-entry retries against a route that does not exist

    mode = 'unauthorized'
    await hook('SessionStart', 'sess-4')
    await Bun.sleep(300)
    expect(files('queue')).toHaveLength(1)
    expect(files('rejected')).toEqual([])

    mode = 'ok'
    await hook('SessionStart', 'sess-5')
    await settle(1)
    expect(accepted).toHaveLength(1)
    expect(files('queue')).toEqual([])
  })

  it("never closes another session's block while that session holds its lock", async () => {
    setState('sess-busy', { start: now() - 1800, last: now() - 600, busy: 0 })
    mkdirSync(join(data, 'sessions', 'sess-busy.lock'))

    await hook('SessionStart', 'sess-2')
    await Bun.sleep(300)
    expect(existsSync(join(data, 'sessions', 'sess-busy'))).toBe(true)
    expect(accepted).toEqual([])

    rmSync(join(data, 'sessions', 'sess-busy.lock'), { recursive: true })
    await hook('SessionStart', 'sess-2')
    await settle(1)
    expect(accepted).toHaveLength(1)
  })

  it('records nothing when tracking is turned off', async () => {
    await hook('UserPromptSubmit', 'sess-1', {}, { CLAUDE_PLUGIN_OPTION_AUTO_TRACK: 'false' })
    expect(existsSync(join(data, 'sessions', 'sess-1'))).toBe(false)
  })
})
