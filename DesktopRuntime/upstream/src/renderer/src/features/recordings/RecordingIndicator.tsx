import { useEffect, useState } from 'react'
import { recordingTime } from '../../../../shared/recording'
import { onPush } from '../../lib/ipc'
import { useCoursesStore } from '../../stores/coursesStore'
import { useWorkspaceStore } from '../../stores/workspaceStore'
import { descriptorFor } from '../workspace/tabIdentity'
import { activateRecordingView } from './recordingNavigation'
import { abandonCapture, stopCapture, useCaptureStore } from './captureStore'
import './recording.css'

export function RecordingIndicator(): JSX.Element | null {
  const capture = useCaptureStore()
  const courseId = useWorkspaceStore((state) => state.activeCourseId)
  const hydration = useWorkspaceStore((state) => state.hydration)
  const [pending, setPending] = useState(false)
  useEffect(
    () =>
      onPush('recordings:event', (event) => {
        const current = useCaptureStore.getState().session
        if (!current || current.id !== event.session.id) return
        if (event.session.status === 'interrupted') {
          abandonCapture(event.session.error ?? '녹음이 중단되었습니다.')
          return
        }
        useCaptureStore.setState({
          session: {
            ...event.session,
            samples: Math.max(current.samples, event.session.samples),
            nextSequence: Math.max(
              current.nextSequence,
              event.session.nextSequence
            )
          }
        })
      }),
    []
  )
  useEffect(() => {
    if (
      pending &&
      capture.session &&
      courseId === capture.session.courseId &&
      hydration === 'ready'
    ) {
      if (!activateRecordingView(capture.session.id))
        useWorkspaceStore.getState().openTab(
          descriptorFor('recording', {
            courseId,
            sessionId: capture.session.id,
            title: capture.session.title
          })
        )
      setPending(false)
    }
  }, [pending, capture.session, courseId, hydration])
  if (!capture.session) return null
  return (
    <div className="recording-indicator" aria-label="진행 중인 녹음">
      <i />
      <button
        onClick={() => {
          if (activateRecordingView(capture.session!.id)) return
          useCoursesStore.getState().selectCourse(capture.session!.courseId)
          setPending(true)
        }}
      >
        {capture.session.status === 'paused' ? '녹음 일시정지' : '강의 녹음 중'}
      </button>
      <time>{recordingTime(capture.session.samples)}</time>
      <button disabled={capture.busy} onClick={() => void stopCapture()}>
        종료
      </button>
    </div>
  )
}
