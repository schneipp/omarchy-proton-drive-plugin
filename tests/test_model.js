// Tests for Model.js — the panel's presentation logic.
//
// These cover the strings and state decisions the panel shows, so wording and
// pluralisation can be checked without a running shell.
//
//     node tests/test_model.js

const M = require(require('path').join(__dirname, '..', 'Model.js'))

let failed = 0
function check(label, got, want) {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    failed++
    console.log(`FAIL ${label}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`)
  } else console.log(`ok   ${label}`)
}

const now = Date.parse('2026-08-17T20:00:00Z')
const pair = (o) => Object.assign({
  remote: '/my-files/Docs', local: '/home/rams/Drive/Docs', localShort: '~/Drive/Docs',
  name: 'Docs', state: 'idle', detail: '', error: '', lastRun: '2026-08-17T19:57:00Z',
  lastOk: true, summary: {}, files: 42, progress: { done: 0, total: 0 }
}, o)

// --- which folder is which -------------------------------------------------
const pairs = [pair({}), pair({ remote: '/my-files/Photos', name: 'Photos' })]

check('the paired folder itself', M.syncStateFor(pairs, '/my-files/Docs').kind, 'self')
check('a folder inside a paired one is covered',
      M.syncStateFor(pairs, '/my-files/Docs/Invoices').kind, 'covered')
check('the covering pair is named so the tooltip can say which',
      M.syncStateFor(pairs, '/my-files/Docs/Invoices').pair.name, 'Docs')
check('an unrelated folder is unpaired', M.syncStateFor(pairs, '/my-files/Other').kind, 'none')
check('a sibling whose name merely starts the same is not covered',
      M.syncStateFor(pairs, '/my-files/Docsomething').kind, 'none')
check('a parent of a paired folder is not covered',
      M.syncStateFor(pairs, '/my-files').kind, 'none')

// --- what one pair is doing ------------------------------------------------
check('an idle pair reads as synced', M.pairMeta(pair({}), now), 'synced 3m ago · 42 files')
check('scanning says so', M.pairMeta(pair({ state: 'scanning' }), now), 'Looking for changes…')
check('transferring shows progress',
      M.pairMeta(pair({ state: 'transferring', detail: 'Uploading 3 item(s)',
                        progress: { done: 2, total: 5 } }), now),
      'Uploading 3 item(s) · 2/5')
check('an error shows the error, not a stale timestamp',
      M.pairMeta(pair({ state: 'error', error: 'folder is missing' }), now), 'folder is missing')
check('a paused pair says paused', M.pairMeta(pair({ state: 'paused' }), now), 'Paused')
check('a never-synced pair does not invent a time',
      M.pairMeta(pair({ lastRun: '', files: 0 }), now), 'not synced yet')
check('one file is singular', M.pairMeta(pair({ files: 1 }), now), 'synced 3m ago · 1 file')

// --- the headline ----------------------------------------------------------
check('nothing configured', M.syncHeadline([], true, now), 'Nothing synced yet')
check('quiet pairs count and date themselves',
      M.syncHeadline(pairs, true, now), '2 folders · synced 3m ago')
check('a single pair reads singular',
      M.syncHeadline([pair({})], true, now), '1 folder · synced 3m ago')
check('a stopped watcher is called out, since nothing would sync by itself',
      M.syncHeadline(pairs, false, now), '2 folders · synced 3m ago · watching off')
check('work in flight outranks the summary',
      M.syncHeadline([pair({}), pair({ name: 'Photos', state: 'transferring',
                                       progress: { done: 1, total: 4 } })], true, now),
      'Syncing Photos · 1/4…')
check('a failure is surfaced over a healthy sibling',
      M.syncHeadline([pair({}), pair({ name: 'Photos', state: 'error', error: 'disk full' })],
                     true, now),
      'Photos: disk full')

// --- what changed ----------------------------------------------------------
check('a quiet run reports nothing rather than a row of zeros',
      M.lastChange({ summary: { downloaded: 0, uploaded: 0, unchanged: 40 } }), '')
check('transfers are named by direction',
      M.lastChange({ summary: { downloaded: 2, uploaded: 1 } }), '2 in · 1 out')
check('deletions say which side they happened on',
      M.lastChange({ summary: { deletedRemote: 1, deletedLocal: 2 } }),
      '1 removed there · 2 removed here')
check('conflicts are pluralised',
      [M.lastChange({ summary: { conflicts: 1 } }), M.lastChange({ summary: { conflicts: 2 } })],
      ['1 conflict', '2 conflicts'])
check('busy detection', [M.isBusy(pair({ state: 'scanning' })),
                         M.isBusy(pair({ state: 'transferring' })), M.isBusy(pair({}))],
      [true, true, false])

// --- drag and drop helpers -------------------------------------------------
check('a dragged path becomes a file:// URI with spaces encoded',
      M.fileUri('/home/rams/a b.txt'), 'file:///home/rams/a%20b.txt')
check('a dropped uri-list becomes plain paths, skipping what is not a file',
      M.localPathsFromUrls(['file:///home/rams/a%20b.txt', 'https://example.com/x']),
      ['/home/rams/a b.txt'])
check('a row with a local copy is marked as draggable',
      M.entryMeta({ type: 'file', size: 2293, time: '', local: '/tmp/x' }, now), '2.29 KB · on disk')

console.log()
if (failed) { console.log(`${failed} FAILED`); process.exit(1) }
console.log('all model tests passed')
