import { createContext, useContext } from 'react'
export const CourseActivity = createContext(true)
export function useCourseActive(): boolean { return useContext(CourseActivity) }
