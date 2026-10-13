/**
 * 자료 드래그아웃(materials:startDrag)용 기본 아이콘.
 *
 * startDrag 는 사용자 드래그 제스처와 같은 틱 안에서 동기로 불러야 한다 —
 * app.getFileIcon 을 await 하는 순간 제스처가 죽어 드래그가 시작되지 않는다.
 * 그래서 32x32 황금색 문서 글리프 PNG 를 인라인으로 들고 있다가 즉시 쓰고,
 * 진짜 파일 아이콘은 드래그 시작 "후" 비동기로 받아 다음 드래그를 위해
 * 확장자별로 캐시한다 (registerHandlers.ts).
 *
 * 전자 런타임 없이도 테스트할 수 있도록 base64 상수만 이 모듈에 둔다.
 */
export const DRAG_ICON_PNG_BASE64 =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAaElEQVR42mNgGAWjgADY1avxnxj86940rJgqDnixw5sgxuUIujkAZBk2R9DVAdgcQXcHoDtiQByA7Ai6OQBXwhxeDlhWJUcUHr4hMOqA0TQw6gBi4n00CkYdMOoAmjiAEjzasRkFhAAAqoA684gSQL8AAAAASUVORK5CYII='
