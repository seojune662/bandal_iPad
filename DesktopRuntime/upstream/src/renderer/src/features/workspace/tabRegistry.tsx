import { withAssistantPanel } from '../assistantPanel/TabAssistantPanel'
import { useHasBeenShown } from './useHasBeenShown'
/**
 * Tab registry: single place mapping TabKind → panel component + metadata.
 *
 * HOW LATER MILESTONES REGISTER A REAL TAB COMPONENT (M3+):
 *  1. Build a component with the `IDockviewPanelProps` signature that reads
 *     its `TabDescriptor` from `props.params.descriptor`.
 *  2. Replace the `component` import below for your kind. Nothing else
 *     changes — panel ids, dedupe, persistence and the "+" menu all key off
 *     TabKind, not the component.
 *  3. Persisted layouts keep working: `contentComponent` is the kind name.
 *
 * `browser` is special: keep rendering the anchor contract from
 * panels/browserAnchor.ts (the webview guest lives outside the panel DOM).
 */

import {
  lazy,
  Suspense,
  type FunctionComponent,
  type LazyExoticComponent
} from 'react'
import type { IDockviewPanelProps } from 'dockview'
import type { TabDescriptor, TabKind } from '../../../../shared/tabs'
import type { IconName } from '../../app/icons'
import { tabTitle } from './tabIdentity'
import { withMaterialSequence } from '../links/MaterialSequenceWrapper'
import { WorkspacePanelSlot } from './panelContentHost'

type DockPanel = FunctionComponent<IDockviewPanelProps>

/**
 * Dockview needs a synchronous component registry, while the actual viewers
 * are large and rarely all needed in one session. This stable wrapper keeps
 * the registry synchronous and moves each implementation into its own chunk.
 */
function deferredPanel(
  load: () => Promise<{ default: DockPanel }>
): DockPanel {
  const Deferred: LazyExoticComponent<DockPanel> = lazy(load)
  return function DeferredDockPanel(props): JSX.Element {
    return (
      <Suspense
        fallback={
          <div className="workspace-panel-loading" role="status">
            탭 불러오는 중…
          </div>
        }
      >
        <Deferred {...props} />
      </Suspense>
    )
  }
}

const BrowserPanel = deferredPanel(() =>
  import('../browser/BrowserPanel').then((module) => ({
    default: module.BrowserPanel
  }))
)
const NoteTab = deferredPanel(() => import('../notes/NoteTab'))
const BoardPanel = deferredPanel(() => import('../board/BoardPanel'))
const ChatTab = deferredPanel(() => import('../chat/ChatTab'))
const PdfTab = deferredPanel(() => import('../pdf/PdfTab'))
const ImageTab = deferredPanel(() => import('../image/ImageTab'))
const FileTab = deferredPanel(() => import('../file/FileTab'))
const CanvasTab = deferredPanel(() => import('../canvas/CanvasTab'))
const PluginPanelTab = deferredPanel(() =>
  import('../plugins/PluginPanelTab').then((module) => ({
    default: module.PluginPanelTab
  }))
)
const RecordingTab = deferredPanel(() => import('../recordings/RecordingTab'))
const LearningTab = deferredPanel(() => import('../learning/LearningTab'))

export interface TabRegistryEntry {
  component: FunctionComponent<IDockviewPanelProps>
  /** Shared-icon name when one exists; workspaceIcons covers the rest. */
  icon: IconName | null
  defaultTitle: (descriptor: TabDescriptor) => string
}

// `tabPanelId` is the sole dedupe key; registry metadata does not participate
// in deciding whether an existing panel is focused or a new panel is opened.
export const tabRegistry: Record<TabKind, TabRegistryEntry> = {
  learning: { component: LearningTab, icon: 'graph', defaultTitle: tabTitle },
  recording: { component: RecordingTab, icon: null, defaultTitle: tabTitle },
  pdf: {
    component: PdfTab,
    icon: 'filePdf',
    defaultTitle: tabTitle
  },
  image: {
    component: ImageTab,
    icon: 'fileImage',
    defaultTitle: tabTitle
  },
  file: {
    component: FileTab,
    icon: 'file',
    defaultTitle: tabTitle
  },
  note: {
    component: NoteTab,
    icon: 'fileText',
    defaultTitle: tabTitle
  },
  browser: {
    component: BrowserPanel, // M3-F: real chrome + anchor (guest in BrowserWebviewLayer)
    icon: null,
    defaultTitle: tabTitle
  },
  chat: {
    component: ChatTab,
    icon: null,
    defaultTitle: tabTitle
  },
  board: {
    component: BoardPanel,
    icon: null,
    defaultTitle: tabTitle
  },
  whiteboard: {
    component: CanvasTab,
    icon: null,
    defaultTitle: tabTitle
  },
  'plugin-panel': {
    component: PluginPanelTab,
    icon: 'puzzle',
    defaultTitle: tabTitle
  }
}

/**
 * Component map in the shape DockviewReact wants (keyed by TabKind).
 * Course material panels are wrapped with the material-sequence layer (edge
 * drop zones during a material drag + prev/next nav bar when links exist).
 * Plugin panels are deliberately direct guests: they cannot own material
 * links and must not inherit course-scoped queries or overlays.
 */
function visiblePanel(Component: DockPanel): DockPanel {
  return function VisiblePanel(props) {
    const shown = useHasBeenShown(props.api)
    return shown ? <Component {...props} /> : <div className="workspace-panel-loading" />
  }
}

export const workspacePanelContents: Record<string, DockPanel> = Object.fromEntries(
  Object.entries(tabRegistry).map(([kind, entry]) => [kind,
    visiblePanel(withAssistantPanel(kind === 'plugin-panel' || kind === 'learning' ? entry.component : withMaterialSequence(entry.component)))
  ])
)

export const dockviewComponents: Record<string, DockPanel> = Object.fromEntries(
  Object.keys(tabRegistry).map(kind => [kind, WorkspacePanelSlot])
)
