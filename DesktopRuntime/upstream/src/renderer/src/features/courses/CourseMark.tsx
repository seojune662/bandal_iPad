import { normalizeCourseColor } from './courseColors'

/** A quiet folder silhouette; only its small index carries the course color. */
export function CourseMark({ color }: { color: string }): JSX.Element {
  return <svg className="course-mark" data-course-color={normalizeCourseColor(color)} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
    <path className="course-mark__body" d="M3 8a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
    <path className="course-mark__index" d="M7 16.5h5" />
  </svg>
}
