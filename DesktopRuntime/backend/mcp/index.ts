import { createMcpRegistry } from '../../upstream/src/main/features/mcpRegistry/registryStore'
import { native, env, emit } from '../native'
import { createHash } from '../shims/crypto'
import { platform } from '../ai/adapter'
import { redactText } from '../../upstream/src/main/features/browserAgent/redact'
import type { AgentTools } from '../../upstream/src/main/features/agentTools/tools'

const fingerprint = (config: any) => createHash('sha256').update(JSON.stringify(config)).digest('hex')
const connection = (config: any) => JSON.stringify([config.transport, config.url, Object.entries(config.headers ?? {}).sort(), config.command ?? '', config.args ?? [], Object.entries(config.env ?? {}).sort()])
export function installMCP({ handle }: { handle: (channel: string, fn: (request: any) => any) => void }) {
  const registry = createMcpRegistry({ userDataPath: env().userDataPath, commandExists: () => false, safeStorage: {
    isEncryptionAvailable: () => native<boolean>('mcp.available'),
    encryptString: plain => Buffer.from(native<string>('mcp.encrypt', { plaintext: plain }), 'base64'),
    decryptString: cipher => native<string>('mcp.decrypt', { ciphertext: cipher.toString('base64') })
  } })
  const catalogs = new Map<string, { connection: string; tools: any[] }>()
  const generations = new Map<string, number>()
  const changed = () => emit('mcp:changed', {})
  const resolve = (id: string) => { const config = registry.resolve(id); if (!config) throw new Error('MCP 서버를 찾을 수 없습니다.'); return config }
  const validate = (input: any) => {
    if (input.transport !== 'http') throw new Error('iPad에서는 로컬 stdio MCP 서버를 실행할 수 없습니다. HTTPS 원격 서버를 등록해 주세요.')
    const url = new URL(input.url)
    if (url.protocol !== 'https:' || url.username || url.password || url.hash) throw new Error('iPad MCP에는 사용자 정보와 #조각이 없는 HTTPS 주소가 필요합니다.')
    if (JSON.stringify(input).length > 256_000) throw new Error('MCP 설정 크기 한도를 초과했습니다.')
  }
  async function probe(config: any) {
    validate(config)
    const result = await platform('native:mcpProbe', { config })
    if (mask(JSON.stringify(result.tools), config) !== JSON.stringify(result.tools)) throw new Error('MCP 서버가 도구 정의에 인증 정보를 포함했습니다. 안전하게 연결할 수 없습니다.')
    if (!Array.isArray(result.tools) || result.tools.length > 100 || result.tools.some((tool: any) => typeof tool.name !== 'string' || !tool.inputSchema || tool.inputSchema.type !== 'object' || JSON.stringify(tool).length > 64_000)) throw new Error('MCP 도구 정의를 확인해 주세요.')
    if (connection(resolve(config.id)) !== connection(config)) throw new Error('연결 검사 중 MCP 설정이 변경되었습니다.')
    catalogs.set(config.id, { connection: connection(config), tools: result.tools })
    return { ok: true, tools: result.tools.map((tool: any) => tool.name), durationMs: result.durationMs ?? 0 }
  }
  handle('mcp:list', () => ({ servers: registry.list(), availability: registry.availability() }))
  handle('mcp:save', input => {
    validate(input)
    if (input.enabled) {
      const previous = input.id ? resolve(input.id) : undefined
      const merged = previous && { ...input, headers: input.headers ?? previous.headers, env: input.env ?? previous.env }
      if (!previous?.lastTest?.ok || connection(previous) !== connection(merged)) throw new Error('변경한 MCP 연결을 검사한 뒤 켜 주세요.')
    }
    const server = registry.save(input); changed(); return { server }
  })
  handle('mcp:delete', request => { registry.delete(request.id); catalogs.delete(request.id); changed(); return { ok: true } })
  handle('mcp:test', async request => {
    const config = resolve(request.id), started = Date.now()
    let result
    try { result = await probe(config) }
    catch (error) { result = { ok: false, tools: [], durationMs: Date.now() - started, error: safeError(error, config) }; catalogs.delete(config.id) }
    if (!registry.recordTest(config.id, result, config)) return { ok: false, tools: [], durationMs: Date.now() - started, error: '연결 검사 중 설정이 바뀌거나 삭제되었습니다.' }
    changed(); return result
  })
  async function refresh() {
    for (const config of registry.resolveEnabled()) {
      if (catalogs.get(config.id)?.connection === connection(config)) continue
      try { const result = await probe(config); registry.recordTest(config.id, result, config) }
      catch (error) { catalogs.delete(config.id); registry.recordTest(config.id, { ok: false, tools: [], durationMs: 0, error: safeError(error, config) }, config); changed() }
    }
  }
  function cancel(conversationId: string) {
    generations.set(conversationId, (generations.get(conversationId) ?? 0) + 1)
    void platform('native:mcpCancel', { conversationId }).catch(() => undefined)
  }
  function wrap(base: AgentTools, context: { courseId: string; sessionId: string; turn: () => string; restriction: () => ReadonlySet<string> | null | undefined; confirm: (request: any) => Promise<any> }): AgentTools {
    const entries = () => registry.resolveEnabled().flatMap(config => {
      const cached = catalogs.get(config.id)
      if (!config.lastTest?.ok || cached?.connection !== connection(config)) return []
      return cached.tools.map(tool => {
        const suffix = createHash('sha256').update(config.id + ':' + tool.name).digest('hex').slice(0, 12)
        const name = `mcp_${config.name}_${tool.name}`.replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 49) + '_' + suffix
        return { config, tool, definition: { name, description: `[${config.name}] ${String(tool.description ?? tool.name).slice(0, 2000)}`, inputSchema: tool.inputSchema } }
      })
    }).filter(entry => !context.restriction() || context.restriction()!.has(entry.definition.name))
    return {
      get definitions() { const extra = entries(); if (base.definitions.length + extra.length > 160) throw new Error('AI에 연결할 도구가 160개를 넘었습니다. MCP 서버 일부를 꺼 주세요.'); return [...base.definitions, ...extra.map(entry => entry.definition)] as any },
      get names() { return [...base.names, ...entries().map(entry => entry.definition.name)] as any },
      async call(name, arguments_ = {}) {
        if (base.names.includes(name as any)) return base.call(name, arguments_)
        const entry = entries().find(entry => entry.definition.name === name)
        if (!entry) return failed('허용되지 않았거나 비활성화된 MCP 도구입니다.')
        const revision = fingerprint(entry.config), turn = context.turn(), generation = generations.get(context.sessionId) ?? 0
        const live = () => {
          const current = registry.resolve(entry.config.id)
          if (!current?.enabled || fingerprint(current) !== revision || context.turn() !== turn || (generations.get(context.sessionId) ?? 0) !== generation || context.restriction() && !context.restriction()!.has(name)) throw new Error('MCP 연결이 바뀌었거나 실행이 취소되었습니다.')
        }
        try {
          if (!arguments_ || typeof arguments_ !== 'object' || Array.isArray(arguments_) || JSON.stringify(arguments_).length > 256_000) throw new Error('MCP 도구 입력을 확인해 주세요.')
          const allowed = await context.confirm({ courseId: context.courseId, conversationId: context.sessionId, turnId: turn, tool: name, summary: `${entry.config.name}의 ${entry.tool.name} 도구를 실행할까요?`, details: [new URL(entry.config.url!).origin, redactText(JSON.stringify(arguments_)).slice(0, 4000), '등록한 외부 서버에 이 입력을 전달합니다.'], scopes: ['once'] })
          if (allowed === false) return failed('학생이 MCP 실행을 취소했습니다.')
          live()
          const result = await platform('native:mcpCall', { config: entry.config, conversationId: context.sessionId, tool: entry.tool.name, expectedSchema: entry.tool.inputSchema, arguments: arguments_ })
          live()
          const encoded = mask(JSON.stringify(result), entry.config)
          if (encoded.length > 1_000_000) throw new Error('MCP 도구 결과가 1MB를 초과했습니다.')
          const value = JSON.parse(encoded)
          if (!Array.isArray(value.content)) value.content = [{ type: 'text', text: JSON.stringify(value.structuredContent ?? value) }]
          return value
        } catch (error) { return failed(safeError(error, entry.config)) }
      }
    }
  }
  return { refresh, wrap, cancel }
}
function mask(value: string, config: any) { for (const secret of [...Object.values(config.headers ?? {}), ...Object.values(config.env ?? {})].flatMap((value: any) => [String(value), /^Bearer\s+(.+)$/i.exec(String(value))?.[1] ?? '']).filter(Boolean).sort((a, b) => b.length - a.length)) value = value.split(secret).join('[redacted]'); return value }
function safeError(error: any, config: any) { return redactText(mask(error instanceof Error ? error.message : String(error), config)).slice(0, 1000) }
function failed(message: string) { return { isError: true, content: [{ type: 'text' as const, text: message }] } }
