import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import * as path from 'node:path'

/** Durable preference boundaries, actual consumers, and reset/data isolation. */
export async function testSettingsControls({ invoke, runtime, environment, course, note }) {
  const before = await invoke('settings:get'), plain = value => JSON.parse(JSON.stringify(value))
  const patch = {
    theme: 'light', fontScale: 1.2, editorFont: 'serif', density: 'compact', locale: 'en-US',
    agentProvider: 'codex', openAdjacentTab: true, restoreLastCourse: false, browserSearchEngine: 'duckduckgo',
    shortcutPriority: 'site', keybindings: { 'new-tab': 'mod+alt+t' },
    browser: { homePage: 'https://example.test/lesson', defaultZoomLevel: 1.22, linkRouting: 'system', popupBehavior: 'strict', trackingProtection: 'strict', doNotTrack: false, swipeNavigation: false, agentUse: false },
    tabs: { markdownTitlePrefix: '물리 수업', recordingModel: 'sensevoice', recordingDeviceId: 'AVAudioSession:usb', recordingPlaybackRate: 1.5, recordingFollowTranscript: false, recordingSidebarOpen: false, whiteboardBackground: 'dots', boardDefaultView: 'board', boardHideDone: true },
    notifications: { enabled: false, deadlines: false, deadlineLeadDays: [7], agentComplete: false, downloads: false, pluginNotices: false, sound: false, suppressWhileFocused: false },
    widgets: { enabled: ['mail', 'todo'], active: 'mail', collapsed: ['todo'], heightRatio: .5, mailUrl: 'https://mail.example.test/', mailServiceId: null }
  }
  const changed = await invoke('settings:set', patch)
  for (const [key, value] of Object.entries(patch)) {
    if (value && typeof value === 'object' && !Array.isArray(value)) for (const [nested, expected] of Object.entries(value)) assert.deepEqual(changed[key][nested], expected, `${key}.${nested}`)
    else assert.deepEqual(changed[key], value, key)
  }
  // The original repository must consume the preference, not just retain a JSON field.
  const board = await invoke('canvas:create', { courseId: course.id, title: 'Settings background verification' })
  const opened = await invoke('canvas:open', { boardId: board.id })
  assert.equal(opened.board.background, 'dots')
  const reopened = runtime(); reopened.initialize()
  assert.deepEqual(plain(await reopened.invoke('settings:get')), changed, 'All changed controls survive a new JS runtime reading disk')
  const file = path.join(environment.userDataPath, 'settings.json'), saved = fs.readFileSync(file)
  await assert.rejects(invoke('settings:set', { browser: { homePage: 'javascript:alert(1)' } }), /HTTP/)
  await assert.rejects(invoke('settings:set', { widgets: { mailUrl: 'file:///private/secret' } }), /HTTP/)
  assert.deepEqual(fs.readFileSync(file), saved, 'Invalid input cannot replace valid persisted preferences')
  const displaced = `${file}.settings-test-backup`
  fs.renameSync(file, displaced); fs.mkdirSync(file)
  try {
    await assert.rejects(invoke('settings:set', { theme: 'dark' }))
    assert.equal((await invoke('settings:get')).theme, 'light', 'A filesystem failure retains the last committed state')
  } finally { fs.rmdirSync(file); fs.renameSync(displaced, file) }
  const originalNote = await invoke('notes:read', { courseId: course.id, relPath: note.relPath })
  const reset = await invoke('settings:reset')
  assert.equal(reset.dataRoot, changed.dataRoot); assert.equal(reset.locale, 'en-US')
  assert.equal(reset.lastActiveCourseId, changed.lastActiveCourseId)
  assert.deepEqual(reset.university, changed.university); assert.deepEqual(reset.tutorial, changed.tutorial)
  assert.deepEqual(await invoke('notes:read', { courseId: course.id, relPath: note.relPath }), originalNote, 'Reset does not alter learning material')
  assert.equal((await invoke('canvas:open', { boardId: board.id })).board.background, 'dots', 'Reset does not rewrite existing whiteboards')
  await verifyCalendar({ runtime, environment, course, invoke, plain })
  await invoke('settings:set', before)
  console.log('Settings controls: durable native-backed preferences, real whiteboard default, invalid URL/storage failure rollback and data-preserving reset passed')
}

async function verifyCalendar({ runtime, environment, course, invoke, plain }) {
  let authorization = 'denied', eventCount = 0
  const calls = [], events = new Map(), calendars = [
    { id: 'subscribed', title: '구독', source: 'fixture', color: '#777777', writable: false },
    { id: 'writable', title: '수업', source: 'fixture', color: '#888888', writable: true }
  ]
  const boundary = { async invoke(channel, input) {
    calls.push({channel,input:plain(input)})
    if (channel === 'native:calendarState') return { authorization, calendars: authorization === 'authorized' && input.includeCalendars ? calendars : [], defaultCalendarId:'writable' }
    if (channel === 'native:calendarEvents') return calendars.filter(calendar => input.calendarIds.includes(calendar.id)).map(calendar => ({ id:calendar.id, calendarId:calendar.id, calendarTitle:calendar.title,title:'강의',start:input.from,end:input.to,allDay:false,location:'',color:calendar.color,bandalTaskId:null }))
    if (channel === 'native:calendarExport') { const id = input.eventId ?? 'event-' + ++eventCount; events.set(id,plain(input)); return { eventId:id,updated:!!input.eventId } }
    throw new Error('Unexpected calendar boundary: ' + channel)
  } }
  let backend = runtime(boundary); backend.initialize()
  const calendar = async (action, input = {}) => plain(await backend.invoke('appleCalendar:' + action, input))
  const denied = await calendar('connect')
  assert.equal(denied.connected,false); assert.equal(denied.authorization,'denied')
  authorization = 'authorized'
  const connected = await calendar('connect')
  assert.deepEqual(connected.selectedCalendarIds,['subscribed','writable'])
  assert.equal(connected.destinationCalendarId,'writable')
  const range = {from:'2026-10-01T00:00:00Z',to:'2026-11-01T00:00:00Z'}
  await calendar('configure',{selectedCalendarIds:['subscribed'],destinationCalendarId:'writable'})
  assert.deepEqual((await calendar('events',range)).map(event => event.calendarId), ['subscribed'])
  const file = path.join(environment.userDataPath,'apple-calendar.json'), persisted = fs.readFileSync(file)
  await assert.rejects(calendar('configure',{selectedCalendarIds:['subscribed'],destinationCalendarId:'subscribed'}),/캘린더/)
  assert.deepEqual(fs.readFileSync(file),persisted)
  const task = await invoke('board:createTask',{courseId:course.id,title:'캘린더 왕복',kind:'task',status:'todo',color:'blue',allDay:true,startAt:'2026-10-14',dueAt:'2026-10-16'})
  const first = await calendar('export',{taskId:task.id})
  assert.equal(events.get(first.eventId).start,'2026-10-14'); assert.equal(events.get(first.eventId).end,'2026-10-17')
  backend = runtime(boundary); backend.initialize()
  assert.deepEqual((await calendar('state')).selectedCalendarIds,['subscribed'])
  const second = await calendar('export',{taskId:task.id})
  assert.equal(second.eventId,first.eventId); assert.equal(second.updated,true); assert.equal(eventCount,1,'A new runtime must update the exported calendar event using the durable receipt')
  await calendar('configure',{selectedCalendarIds:[],destinationCalendarId:'writable'})
  const queries = calls.filter(call => call.channel === 'native:calendarEvents').length
  assert.deepEqual(await calendar('events',range),[])
  assert.equal(calls.filter(call => call.channel === 'native:calendarEvents').length,queries)
  await calendar('disconnect'); assert.equal(events.size,1,'Disconnect must not delete calendar events')
  await calendar('connect'); assert.deepEqual((await calendar('state')).selectedCalendarIds,[],'Intentional empty selection survives reconnect')
  authorization = 'denied'
  await assert.rejects(calendar('export',{taskId:task.id}),/권한/)
  assert.equal(events.size,1)
  authorization = 'authorized'
  const displaced = file + '.fixture'; fs.renameSync(file,displaced); fs.mkdirSync(file)
  try { await assert.rejects(calendar('configure',{selectedCalendarIds:['writable'],destinationCalendarId:'writable'})); assert.deepEqual((await calendar('state')).selectedCalendarIds,[]) }
  finally { fs.rmdirSync(file); fs.renameSync(displaced,file) }
  console.log('Actual calendar service/backend: permission recovery, selection filtering, read-only rejection, disk persistence/failure, all-day export receipt reuse, empty selection and disconnect preservation passed')
}
