import { createContext } from 'react'
import type { PdfPageNotePairContext } from '../../../../../shared/pdfPageNote'
export const PresentationContext = createContext<{ panelId: string; interactive: boolean; pair: PdfPageNotePairContext | null }>({ panelId: '', interactive: false, pair: null })
