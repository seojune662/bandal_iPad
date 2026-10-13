import { useEffect } from 'react'
import { useUiStore } from './stores/uiStore'
import { bootstrapAppearance } from './app/bootstrapAppearance'
import React from 'react'
import ReactDOM from 'react-dom/client'
import 'pretendard/dist/web/variable/pretendardvariable-dynamic-subset.css'
import './styles/tokens.css'
import './styles/base.css'
import './features/pip/pip.css'
import { PipPlayerApp } from './features/pip/PipPlayerApp'
import { PipToolbarApp } from './features/pip/PipToolbarApp'

const params = new URLSearchParams(location.search)
const view = params.get('view') === 'toolbar' ? 'toolbar' : 'player'

document.documentElement.dataset['pipView'] = view

function playerTitle(relPath: string): string {
  return params.get('title') ?? relPath.split('/').at(-1) ?? relPath
}

function PipEntry(): JSX.Element {
  useEffect(() => {
    void useUiStore.getState().initTheme().catch(console.error)
  }, [])
  if (view === 'toolbar') return <PipToolbarApp />

  const courseId = params.get('course') ?? ''
  const relPath = params.get('rel') ?? ''
  return (
    <PipPlayerApp
      courseId={courseId}
      relPath={relPath}
      title={playerTitle(relPath)}
    />
  )
}

const rootElement = document.getElementById('root')
if (rootElement === null) {
  throw new Error('Root element #root not found')
}

void bootstrapAppearance().then(() =>
  ReactDOM.createRoot(rootElement).render(
    <React.StrictMode>
      <PipEntry />
    </React.StrictMode>
  )
)
