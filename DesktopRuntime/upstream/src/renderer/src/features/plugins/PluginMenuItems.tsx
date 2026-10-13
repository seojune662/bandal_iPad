import { usePluginsStore } from '../../stores/pluginsStore'
import { invoke } from '../../lib/ipc'
import { showToast } from '../../app/toast'

export function PluginMenuItems({
  location,
  courseId,
  relPath,
  onClose,
}: {
  location: 'editor' | 'materials'
  courseId: string
  relPath: string
  onClose?: () => void
}): JSX.Element {
  const plugins = usePluginsStore((state) => state.plugins)
  return (
    <>
      {plugins
        .filter(
          (p) =>
            p.enabled &&
            p.state === 'active' &&
            p.approvedPermissions?.includes('menus') &&
            p.approvedPermissions.includes('commands'),
        )
        .flatMap((p) =>
          (p.manifest.contributes.menus ?? [])
            .filter((m) => m.location === location)
            .map((m) => {
              const command = p.manifest.contributes.commands.find(
                (c) => c.id === m.command,
              )
              return command === undefined ? null : (
                <button
                  key={`${p.manifest.id}:${m.command}`}
                  type="button"
                  role="menuitem"
                  className={
                    location === 'editor'
                      ? 'note-format-menu-button'
                      : undefined
                  }
                  onMouseDown={(event) => {
                    if (location === 'editor') event.preventDefault()
                  }}
                  onClick={() => {
                    onClose?.()
                    void invoke('plugins:runCommand', {
                      pluginId: p.manifest.id,
                      commandId: m.command,
                      context: { courseId, relPath },
                    }).catch((error: unknown) =>
                      showToast(
                        error instanceof Error ? error.message : String(error),
                        'danger',
                      ),
                    )
                  }}
                >
                  {command.title}
                  <small>{p.manifest.name}</small>
                </button>
              )
            }),
        )}
    </>
  )
}
