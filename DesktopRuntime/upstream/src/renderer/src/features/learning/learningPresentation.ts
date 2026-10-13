import type { Course } from '../../../../shared/types/course'
import type { LearningProjectSummary } from '../../../../shared/types/learning'

type NamedProject = Pick<LearningProjectSummary, 'binding' | 'name' | 'topic' | 'purpose' | 'linkedCourseId'>

export function learningSourceCourse(project: NamedProject, courses: Course[]): Course | undefined {
  if (project.linkedCourseId) return courses.find(course => course.id === project.linkedCourseId)
  return courses.find(course => course.id === project.binding.courseId && course.workspaceKind !== 'study-space')
}

/** Presentation only: preserve user names and every existing filesystem path. */
export function learningDisplayName(project: NamedProject, courses: Course[]): string {
  if (project.name === 'AI 학습자료' && project.topic === '과목 자료' && project.purpose === 'course-review') {
    const source = learningSourceCourse(project, courses)
    return source ? `${source.name} 복습` : '과목 복습'
  }
  return project.name
}
