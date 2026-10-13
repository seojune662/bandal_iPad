import React from 'react'
import ReactDOM from 'react-dom/client'
import { ScreenSelectionApp } from './features/overlay/ScreenSelectionApp'
import './styles/tokens.css'
import './styles/base.css'
const root = document.getElementById('root')
if (!root) throw new Error('Missing capture root')
ReactDOM.createRoot(root).render(<React.StrictMode><ScreenSelectionApp /></React.StrictMode>)
