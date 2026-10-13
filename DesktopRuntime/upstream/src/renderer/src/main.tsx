import { bootstrapAppearance } from './app/bootstrapAppearance'
import React from 'react'
import ReactDOM from 'react-dom/client'
import 'pretendard/dist/web/variable/pretendardvariable-dynamic-subset.css'
import { AppShell } from './app/AppShell'
import { RendererErrorBoundary } from './app/RendererErrorBoundary'
// tokens.css pulls in every theme (styles/themes/index.css) — entry points
// never list themes individually.
import './styles/tokens.css'
import './styles/base.css'

const rootElement = document.getElementById('root')
if (rootElement === null) {
  throw new Error('Root element #root not found')
}

void bootstrapAppearance().then(() =>
  ReactDOM.createRoot(rootElement).render(
    <React.StrictMode>
      <RendererErrorBoundary>
        <AppShell />
      </RendererErrorBoundary>
    </React.StrictMode>
  )
)
