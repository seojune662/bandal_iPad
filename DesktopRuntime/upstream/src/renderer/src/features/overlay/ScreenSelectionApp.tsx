import { useCallback, useEffect, useRef, useState } from 'react'
import { invoke } from '../../lib/ipc'
export function ScreenSelectionApp(): JSX.Element {
  const [image, setImage] = useState(''), [rect, setRect] = useState<{ x: number; y: number; width: number; height: number } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const start = useRef<{ x: number; y: number } | null>(null)
  const cancel = useCallback(() => {
    void invoke('assistant:selection', { action: 'cancel' }).catch(() => setError('선택 창을 닫지 못했어요. 취소를 다시 눌러 주세요.'))
  }, [])
  useEffect(() => {
    let active = true
    void invoke('assistant:selection', { action: 'get' }).then(result => {
      if (!active) return
      if (result.image) setImage(result.image)
      else setError('화면을 불러오지 못했어요. 취소 후 다시 선택해 주세요.')
    }).catch(() => { if (active) setError('화면을 불러오지 못했어요. 취소 후 다시 선택해 주세요.') })
    const key = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') { event.preventDefault(); cancel() }
    }
    window.addEventListener('keydown', key)
    return () => { active = false; window.removeEventListener('keydown', key) }
  }, [cancel])
  return <div className="screen-selection" style={{ position: 'fixed', inset: 0, cursor: 'crosshair', userSelect: 'none', backgroundImage: `url(${image})`, backgroundSize: '100% 100%' }}
    onPointerDown={event => {
      if (event.button !== 0 || !image || error) return
      start.current = { x: event.clientX, y: event.clientY }; event.currentTarget.setPointerCapture(event.pointerId); setRect(null)
    }}
    onPointerMove={event => { if (start.current) setRect({ x: Math.min(start.current.x, event.clientX), y: Math.min(start.current.y, event.clientY), width: Math.abs(start.current.x - event.clientX), height: Math.abs(start.current.y - event.clientY) }) }}
    onPointerCancel={() => { start.current = null; setRect(null) }}
    onLostPointerCapture={() => { start.current = null }}
    onPointerUp={event => {
      const origin = start.current; start.current = null
      if (!origin) return
      const selected = { x: Math.min(origin.x, event.clientX), y: Math.min(origin.y, event.clientY), width: Math.abs(origin.x - event.clientX), height: Math.abs(origin.y - event.clientY) }
      if (selected.width < 4 || selected.height < 4) { setRect(null); return }
      void invoke('assistant:selection', { action: 'select', rect: selected }).catch(() => setError('영역을 선택하지 못했어요. 취소 후 다시 선택해 주세요.'))
    }}>
    <div onPointerDown={event => event.stopPropagation()} style={{ position: 'absolute', top: 24, left: '50%', transform: 'translateX(-50%)', padding: '10px 16px', background: '#161616e6', color: 'white', borderRadius: 10, fontSize: 13, cursor: 'default', display: 'flex', alignItems: 'center', gap: 16 }}>
      <span role={error ? 'alert' : 'status'}>{error ?? (image ? '질문할 영역을 드래그하세요 · Esc 취소' : '화면을 준비하고 있어요…')}</span>
      <button type="button" onClick={cancel} style={{ color: 'inherit', background: 'transparent', border: '1px solid #aaa', borderRadius: 6, padding: '4px 10px', cursor: 'pointer', whiteSpace: 'nowrap' }}>취소</button>
    </div>
    {rect && <div style={{ position: 'absolute', ...rect, border: '2px solid white', boxShadow: '0 0 0 9999px #0006', boxSizing: 'border-box' }} />}
  </div>
}
