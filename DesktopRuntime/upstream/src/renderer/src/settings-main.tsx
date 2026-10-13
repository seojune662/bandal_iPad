import { bootstrapAppearance } from './app/bootstrapAppearance'
import React from 'react'
import ReactDOM from 'react-dom/client'
import { SettingsApp } from './features/settings/SettingsApp'
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
      <SettingsApp />
    </React.StrictMode>
  )
)
