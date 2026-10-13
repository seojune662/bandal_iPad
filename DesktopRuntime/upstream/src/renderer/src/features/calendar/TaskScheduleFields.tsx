import { useState } from 'react'
import type { BoardTask } from '../../../../shared/types/board'
import { dueAtForLocalInput, localDateKey, localTimeInput } from './calendarDate'
import './taskSchedule.css'

export function useTaskSchedule(task: BoardTask | null, defaultDate = '') {
  const [endDate, setEndDate] = useState(task?.dueAt ? localDateKey(task.dueAt) : defaultDate)
  const [startDate, setStartDate] = useState(task?.startAt ? localDateKey(task.startAt) : task?.dueAt ? localDateKey(task.dueAt) : defaultDate)
  const [endTime, setEndTime] = useState(localTimeInput(task?.allDay ? null : task?.dueAt ?? null))
  const [startTime, setStartTime] = useState(task?.startAt && !task.allDay ? localTimeInput(task.startAt) : '09:00')
  const [allDay, setAllDay] = useState(task?.dueAt ? task.allDay : true)
  const [hasRange, setHasRange] = useState(Boolean(task?.startAt))
  const value = () => {
    if (!endDate && !hasRange) return { startAt: null, dueAt: null, allDay }
    if (!endDate || (hasRange && !startDate)) throw new Error('시작일과 종료일을 입력해주세요.')
    const dueAt = dueAtForLocalInput(endDate, endTime, allDay)
    const startAt = hasRange ? dueAtForLocalInput(startDate, startTime, allDay) : null
    if (startAt !== null && startAt > dueAt) throw new Error('종료 날짜와 시각은 시작보다 빠를 수 없습니다.')
    return { startAt, dueAt, allDay }
  }
  return { endDate, setEndDate, startDate, setStartDate, endTime, setEndTime, startTime, setStartTime, allDay, setAllDay, hasRange, setHasRange, value }
}

export function TaskScheduleFields({ schedule: s, required = false, disabled = false }: {
  schedule: ReturnType<typeof useTaskSchedule>
  required?: boolean
  disabled?: boolean
}): JSX.Element {
  return <fieldset className="task-schedule" disabled={disabled}>
    <legend>일정</legend>
    <div className="task-schedule__options">
      <label><input type="checkbox" checked={s.hasRange} onChange={event => {
        s.setHasRange(event.target.checked)
        if (event.target.checked && !s.startDate) s.setStartDate(s.endDate)
      }} />기간 지정</label>
      <label><input type="checkbox" checked={s.allDay} onChange={event => s.setAllDay(event.target.checked)} />하루 종일</label>
    </div>
    {s.hasRange && <div className="task-schedule__row">
      <label className="board-field"><span>시작일</span><input type="date" value={s.startDate} required onChange={event => s.setStartDate(event.target.value)} /></label>
      {!s.allDay && <label className="board-field"><span>시작 시각</span><input type="time" value={s.startTime} required onChange={event => s.setStartTime(event.target.value)} /></label>}
    </div>}
    <div className="task-schedule__row">
      <label className="board-field"><span>{s.hasRange ? '종료일' : '마감일'}</span><input type="date" value={s.endDate} required={required || s.hasRange} min={s.hasRange ? s.startDate : undefined} onChange={event => s.setEndDate(event.target.value)} /></label>
      {!s.allDay && <label className="board-field"><span>{s.hasRange ? '종료 시각' : '마감 시각'}</span><input type="time" value={s.endTime} required={required || s.hasRange || Boolean(s.endDate)} onChange={event => s.setEndTime(event.target.value)} /></label>}
    </div>
    <small className="task-schedule__hint">{s.hasRange
      ? s.allDay ? '시작일부터 종료일까지 매일 표시합니다.' : '지정한 시작부터 종료 시각까지 표시합니다.'
      : s.allDay ? '선택한 날짜 하루에 표시합니다.' : '마감 시각에 표시합니다. 소요 시간이 있으면 기간을 지정하세요.'}</small>
  </fieldset>
}
