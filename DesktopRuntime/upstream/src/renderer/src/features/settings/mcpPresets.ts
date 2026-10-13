import type { McpServerInput, McpServerSummary } from '../../../../shared/types/mcp'

interface PresetField {
  key: string
  labelKey: string
  placeholder: string
  secret?: boolean
}

export interface McpPreset {
  id: string
  name: string
  packageName: string
  descriptionKey: string
  fields: PresetField[]
  input: (description: string, values: Record<string, string>) => McpServerInput
}

const NPX_ARGS = (packageName: string): string[] => ['-y', packageName]

export const MCP_PRESETS: readonly McpPreset[] = [
  {
    id: 'notion',
    name: 'Notion',
    packageName: '@notionhq/notion-mcp-server',
    descriptionKey: 'settings.mcp.gallery.notion.description',
    fields: [
      {
        key: 'NOTION_TOKEN',
        labelKey: 'settings.mcp.gallery.field.notionToken',
        placeholder: 'ntn_…',
        secret: true
      }
    ],
    input: (description, values) => ({
      name: 'notion',
      description,
      transport: 'stdio',
      command: 'npx',
      args: NPX_ARGS('@notionhq/notion-mcp-server'),
      env: { NOTION_TOKEN: values['NOTION_TOKEN'] ?? '' },
      enabled: true
    })
  },
  {
    id: 'github',
    name: 'GitHub',
    packageName: '@modelcontextprotocol/server-github',
    descriptionKey: 'settings.mcp.gallery.github.description',
    fields: [
      {
        key: 'GITHUB_PERSONAL_ACCESS_TOKEN',
        labelKey: 'settings.mcp.gallery.field.githubToken',
        placeholder: 'github_pat_…',
        secret: true
      }
    ],
    input: (description, values) => ({
      name: 'github',
      description,
      transport: 'stdio',
      command: 'npx',
      args: NPX_ARGS('@modelcontextprotocol/server-github'),
      env: {
        GITHUB_PERSONAL_ACCESS_TOKEN:
          values['GITHUB_PERSONAL_ACCESS_TOKEN'] ?? ''
      },
      enabled: true
    })
  },
  {
    id: 'google-drive',
    name: 'Google Drive',
    packageName: '@modelcontextprotocol/server-gdrive',
    descriptionKey: 'settings.mcp.gallery.googleDrive.description',
    fields: [
      {
        key: 'GDRIVE_OAUTH_PATH',
        labelKey: 'settings.mcp.gallery.field.googleOauthPath',
        placeholder: '/path/to/gcp-oauth.keys.json'
      }
    ],
    input: (description, values) => ({
      name: 'google-drive',
      description,
      transport: 'stdio',
      command: 'npx',
      args: NPX_ARGS('@modelcontextprotocol/server-gdrive'),
      env: { GDRIVE_OAUTH_PATH: values['GDRIVE_OAUTH_PATH'] ?? '' },
      enabled: true
    })
  },
  {
    id: 'slack',
    name: 'Slack',
    packageName: '@modelcontextprotocol/server-slack',
    descriptionKey: 'settings.mcp.gallery.slack.description',
    fields: [
      {
        key: 'SLACK_BOT_TOKEN',
        labelKey: 'settings.mcp.gallery.field.slackToken',
        placeholder: 'xoxb-…',
        secret: true
      },
      {
        key: 'SLACK_TEAM_ID',
        labelKey: 'settings.mcp.gallery.field.slackTeam',
        placeholder: 'T01234567'
      }
    ],
    input: (description, values) => ({
      name: 'slack',
      description,
      transport: 'stdio',
      command: 'npx',
      args: NPX_ARGS('@modelcontextprotocol/server-slack'),
      env: {
        SLACK_BOT_TOKEN: values['SLACK_BOT_TOKEN'] ?? '',
        SLACK_TEAM_ID: values['SLACK_TEAM_ID'] ?? ''
      },
      enabled: true
    })
  },
  {
    id: 'filesystem',
    name: '파일시스템',
    packageName: '@modelcontextprotocol/server-filesystem',
    descriptionKey: 'settings.mcp.gallery.filesystem.description',
    fields: [
      {
        key: 'folder',
        labelKey: 'settings.mcp.gallery.field.courseFolder',
        placeholder: '/Users/student/Documents/과목'
      }
    ],
    input: (description, values) => ({
      name: 'course-files',
      description,
      transport: 'stdio',
      command: 'npx',
      args: [
        ...NPX_ARGS('@modelcontextprotocol/server-filesystem'),
        values['folder'] ?? ''
      ],
      enabled: true
    })
  },
  {
    id: 'fetch',
    name: 'Fetch',
    packageName: 'mcp-server-fetch (Python)',
    descriptionKey: 'settings.mcp.gallery.fetch.description',
    fields: [],
    input: (description) => ({
      name: 'fetch',
      description,
      transport: 'stdio',
      command: 'uvx',
      args: ['--with', 'mcp<2', 'mcp-server-fetch'],
      enabled: true
    })
  }
]


/** Identify a preset by its actual executable, never by display name alone. */
export function presetForServer(server: McpServerSummary): McpPreset | undefined {
  return MCP_PRESETS.find(preset => {
    const expected = preset.input('', {})
    return server.transport === expected.transport && server.command === expected.command && expected.args?.filter(Boolean).every(arg => server.args?.includes(arg))
  })
}
