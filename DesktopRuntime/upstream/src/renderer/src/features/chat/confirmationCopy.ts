/** Product copy only: provider commands and JSON never belong in an approval UI. */
export function isInternalExecution(tool: string): boolean {
  return tool.startsWith('cli:') || /bash|shell|exec|command|terminal|apply.?patch/i.test(tool)
}

export function confirmationCopy(tool: string): { title: string; description: string } {
  tool = tool.split(':').at(-1) ?? tool
  if (tool === 'serviceAuthorization') {
    return { title: '서비스 연결을 확인해 주세요', description: '선택한 서비스의 계정 연결을 완료하면 이어갈 수 있어요.' }
  }
  if (/read|grep|glob|search|fetch/i.test(tool)) {
    return { title: '자료를 확인하고 이어갈까요?', description: '답변에 필요한 자료를 살펴봅니다.' }
  }
  if (/write|edit|patch/i.test(tool)) {
    return { title: '요청한 내용을 반영할까요?', description: '자료를 작성하거나 수정합니다.' }
  }
  return { title: '요청한 작업을 계속할까요?', description: '답변에 필요한 작업을 이어갑니다.' }
}
