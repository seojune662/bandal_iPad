import type { McpServerSummary } from '../../../../shared/types/mcp'
import type { PluginSummary } from '../../../../shared/types/plugin'
import type { WorkflowPackSummary } from '../../../../shared/types/workflowPack'
import { MCP_PRESETS, presetForServer, type McpPreset } from './mcpPresets'

export type PluginCenterFilter = 'all' | 'study' | 'plugin' | 'external'
interface RowBase { id: string; name: string; outcome: string; status: string; checked: boolean }
export type PluginCenterRow = RowBase & (
  | { kind: 'study'; summary: WorkflowPackSummary }
  | { kind: 'plugin'; plugin: PluginSummary }
  | { kind: 'external'; server: McpServerSummary }
  | { kind: 'preset'; preset: McpPreset }
)

export function packOutcome(summary: WorkflowPackSummary, ko: boolean): string {
  const { pack } = summary
  if (pack.schemaVersion === 2) {
    if (pack.experience === 'quiz') return ko ? '자료로 문제와 해설을 만들고, 풀면서 이해도를 확인합니다.' : 'Create questions and explanations from your materials, then check your understanding.'
    if (pack.experience === 'flashcards') return ko ? '자료의 핵심 개념을 질문과 답 카드로 만들어 복습합니다.' : 'Review key concepts with question and answer cards from your materials.'
    return ko ? '관심 있는 영어 글을 읽고, 고른 표현을 다음 글에서 다시 만납니다.' : 'Read English articles and revisit your chosen expressions in the next article.'
  }
  const outcomes: Record<string, [string, string]> = {
    summary: ['자료의 핵심 개념과 흐름을 요약한 필기를 저장합니다.', 'Save notes summarizing the key concepts and structure of your materials.'],
    mindmap: ['개념 사이의 관계를 마인드맵이 있는 필기로 정리합니다.', 'Save notes with a mind map connecting the concepts.'],
    'structured-notes': ['강의자료를 제목과 하위 항목이 분명한 필기로 정리합니다.', 'Organize course materials into notes with clear headings and sections.'],
    'exam-predictions': ['자료를 바탕으로 예상 문제와 답안 포인트를 필기로 저장합니다.', 'Save possible exam questions and answer points based on your materials.'],
    explain: ['자료나 선택한 부분의 개념을 단계적으로 설명하는 필기를 저장합니다.', 'Save step-by-step explanations of a material or selected passage.']
  }
  return outcomes[pack.id]?.[ko ? 0 : 1] ?? pack.description
}

export function externalOutcome(server: McpServerSummary, ko: boolean): string {
  const preset = presetForServer(server)
  const outcomes: Record<string, [string, string]> = {
    notion: ['화면 도우미에서 Notion 페이지와 데이터베이스를 검색하고 관리합니다.', 'Search and manage Notion pages and databases with the screen assistant.'],
    github: ['화면 도우미에서 GitHub 저장소, 코드와 이슈를 찾고 관리합니다.', 'Find and manage GitHub repositories, code and issues with the screen assistant.'],
    'google-drive': ['화면 도우미에서 Google Drive 파일을 검색하고 읽습니다.', 'Search and read Google Drive files with the screen assistant.'],
    slack: ['화면 도우미에서 Slack 채널을 읽고 메시지를 관리합니다.', 'Read Slack channels and manage messages with the screen assistant.'],
    filesystem: ['화면 도우미에서 지정한 폴더의 파일을 읽고 관리합니다.', 'Read and manage files in the chosen folder with the screen assistant.'],
    fetch: ['화면 도우미에서 웹 페이지 본문을 가져와 읽습니다.', 'Fetch and read web page content with the screen assistant.']
  }
  return (preset && outcomes[preset.id]?.[ko ? 0 : 1]) || server.description || (ko ? '화면 도우미에서 이 서버가 제공하는 도구를 사용합니다.' : 'Use this server’s tools with the screen assistant.')
}

export function pluginStatus(plugin: PluginSummary, runtime: boolean, ko: boolean): string {
  if (plugin.state === 'needs-approval' || !plugin.approvedPermissions || !plugin.manifest.permissions.every(p => plugin.approvedPermissions?.includes(p))) return ko ? '승인 필요' : 'Approval needed'
  if (!plugin.enabled) return ko ? '꺼짐' : 'Off'
  if (!runtime) return ko ? '실행 꺼짐' : 'Execution off'
  if (plugin.state === 'errored') return ko ? '실행 오류' : 'Execution failed'
  if (plugin.state === 'starting') return ko ? '시작 중' : 'Starting'
  return plugin.state === 'active' ? ko ? '사용 중' : 'In use' : ko ? '꺼짐' : 'Off'
}

export function buildPluginCenterRows(packs: readonly WorkflowPackSummary[], plugins: readonly PluginSummary[], servers: readonly McpServerSummary[], runtime: boolean, ko: boolean): PluginCenterRow[] {
  const compareName = (a: { name: string }, b: { name: string }): number => a.name.localeCompare(b.name, ko ? 'ko' : 'en')
  const packRows = packs.map(summary => ({ kind: 'study' as const, id: `pack:${summary.pack.id}`, name: summary.pack.schemaVersion === 2 && summary.pack.experience === 'article-vocabulary' ? ko ? '영어 글 읽기' : 'Read English articles' : summary.pack.name, outcome: packOutcome(summary, ko), status: summary.enabled ? ko ? '사용 중' : 'In use' : ko ? '꺼짐' : 'Off', checked: summary.enabled, summary }))
  const builtin = packRows.filter(row => row.summary.source === 'builtin')
  const custom = packRows.filter(row => row.summary.source === 'user').sort(compareName)
  const extensions = plugins.map(plugin => ({ kind: 'plugin' as const, id: `plugin:${plugin.manifest.id}`, name: plugin.manifest.name, outcome: plugin.manifest.description || (ko ? '필기와 자료 작업에 사용할 기능을 추가합니다.' : 'Add tools for working with notes and materials.'), status: pluginStatus(plugin, runtime, ko), checked: runtime && plugin.enabled && plugin.state === 'active', plugin })).sort(compareName)
  const external = servers.map(server => ({ kind: 'external' as const, id: `mcp:${server.id}`, name: presetForServer(server)?.name ?? server.name, outcome: externalOutcome(server, ko), status: !server.enabled ? server.lastTest?.ok === false ? ko ? '확인 실패 · 꺼짐' : 'Check failed · Off' : server.lastTest?.ok === true ? ko ? '연결 확인됨 · 꺼짐' : 'Connection checked · Off' : ko ? '확인 전 · 꺼짐' : 'Not checked · Off' : server.lastTest?.ok === true ? ko ? '연결 확인됨' : 'Connection checked' : server.lastTest?.ok === false ? ko ? '확인 실패' : 'Check failed' : ko ? '확인 전' : 'Not checked', checked: server.enabled, server })).sort(compareName)
  const configured = new Set(servers.map(server => presetForServer(server)?.id).filter(Boolean))
  const presets = MCP_PRESETS.filter(preset => !configured.has(preset.id)).map(preset => {
    const input = preset.input('', {})
    const temporary: McpServerSummary = { ...input, id: preset.id, envKeys: [], headerKeys: [], createdAt: '', updatedAt: '' }
    return { kind: 'preset' as const, id: `preset:${preset.id}`, name: preset.id === 'filesystem' ? ko ? '폴더의 파일' : 'Folder files' : preset.name, outcome: externalOutcome(temporary, ko), status: ko ? '설정 필요' : 'Setup needed', checked: false, preset }
  })
  return [...builtin, ...custom, ...extensions, ...external, ...presets]
}

export function filterPluginCenterRows(rows: readonly PluginCenterRow[], query: string, filter: PluginCenterFilter): PluginCenterRow[] {
  const needle = query.trim().toLocaleLowerCase()
  return rows.filter(row => (filter === 'all' || (filter === 'external' ? row.kind === 'external' || row.kind === 'preset' : row.kind === filter)) && (!needle || `${row.name} ${row.outcome} ${row.kind === 'external' ? row.server.name : ''}`.toLocaleLowerCase().includes(needle)))
}
