/** Allows importing .sql files as raw strings (vite `?raw` / vitest). */
declare module '*.sql?raw' {
  const sql: string
  export default sql
}
