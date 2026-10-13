import { useEffect, useId, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from '../../app/icons'
import { useFocusTrap } from '../../components/useFocusTrap'
import { acquirePointerPassthrough } from '../browser/webviewPassthrough'
import './englishReadingGuide.css'

const STEPS = [
  {
    label: '글 찾기', title: '좋아하는 이야기로 시작해요',
    description: '우주, 과학, 문화… 궁금한 주제의 영어 기사를 나에게 맞는 길이로 만나보세요.',
    instructions: [
      ['취향과 읽기 속도를 정해요', '관심 주제 1~3개, 편한 영어 수준, 한 편의 읽기 시간을 골라요.'],
      ['함께할 AI를 선택해요', '연결한 AI와 모델을 고른 뒤 ‘공간 만들고 첫 글 찾기’를 누르면 첫 기사를 찾아요.']
    ],
    tip: '읽고 싶은 글이 있나요? ‘읽은 글과 다음 글’에서 기사 주소를 직접 추가할 수도 있어요.'
  },
  {
    label: '단어 담기', title: '모르는 단어는, 그 자리에서',
    description: '읽는 흐름을 놓치지 마세요. 뜻을 확인하고, 기억하고 싶은 표현만 골라 담아요.',
    instructions: [
      ['단어를 톡 눌러요', '단어를 누르면 사전이 열려요. 여러 단어로 된 표현은 드래그해서 선택하세요.'],
      ['뜻을 고르고 단어장에 담아요', '‘단어장에 담기’를 누르면 단어와 지금 읽던 원문 문장이 함께 저장돼요.']
    ],
    tip: '기본 사전은 인터넷 없이도 열려요. 더 자세한 AI 문맥 설명은 단어를 저장한 뒤 요청할 수 있어요.'
  },
  {
    label: '이어 읽기', title: '한 번 만난 단어를 오래 기억하도록',
    description: '외운 목록에서 끝나지 않도록. 모아 둔 표현을 새로운 이야기 속에서 다시 만나요.',
    instructions: [
      ['다 읽으면, 다음 글로', '글 아래의 ‘읽기 완료 · 다음 글 찾기’를 누르면 읽은 기록을 저장하고 다음 기사를 찾아요.'],
      ['내 단어가 다시 나오는 글을 읽어요', 'AI가 저장한 표현이 실제로 등장하는 글을 찾아요. 모은 표현은 ‘나의 단어’에서도 다시 볼 수 있어요.']
    ],
    tip: '잠깐 쉬어도 괜찮아요. 읽던 문단이 저장되어 다음에 열었을 때 이어 읽을 수 있어요.'
  }
] as const

function GuidePreview({ step }: { step: number }): JSX.Element {
  return <div className="reading-guide-preview" aria-hidden="true">
    <div className="reading-guide-preview-caption"><span className="reading-guide-spark">✳</span> {step === 0 ? 'A LITTLE CURIOSITY' : step === 1 ? 'MAKE IT YOURS' : 'MEET YOUR WORDS AGAIN'}<span>예시</span></div>
    {step === 0 ? <>
      <div className="reading-guide-topics"><span>우주</span><span>과학</span><span>문화</span></div>
      <div className="reading-guide-paper"><div className="reading-guide-paper-meta">SCIENCE JOURNAL <span>약 4분</span></div><div className="reading-guide-orbit"><span /><span /><b>✦</b></div><h3>A small step.<br />A new perspective.</h3><p>There is always something<br />new to discover.</p><div className="reading-guide-paper-lines"><i /><i /></div></div>
      <div className="reading-guide-preview-note"><Icon name="search" /> 내 관심사에서 시작하는 한 편</div>
    </> : step === 1 ? <>
      <div className="reading-guide-paper reading-guide-paper--excerpt"><div className="reading-guide-paper-meta">오늘의 읽기</div><p>There is always something<br />new to <mark>discover</mark>.</p><div className="reading-guide-paper-lines"><i /><i /></div></div>
      <div className="reading-guide-definition"><div><strong>discover</strong><span>동사</span></div><p>발견하다, 알아내다</p><div className="reading-guide-save"><Icon name="plus" /> 단어장에 담기</div></div>
      <div className="reading-guide-preview-note">단어 하나에, 문장 하나도 함께</div>
    </> : <>
      <div className="reading-guide-word-ticket"><span>나의 단어</span><strong>discover</strong><small>발견하다, 알아내다</small></div>
      <div className="reading-guide-connection"><span /><Icon name="chevronRight" /><span /></div>
      <div className="reading-guide-paper reading-guide-paper--next"><div className="reading-guide-paper-meta">다음 이야기 <span>다시 만난 표현</span></div><h3>The ocean<br />still surprises us.</h3><p>Scientists <mark>discover</mark> new<br />life beneath the waves.</p></div>
      <div className="reading-guide-preview-note">새로운 문맥에서 더 선명하게</div>
    </>}
  </div>
}

export function EnglishReadingGuide({ creating = false, onClose, onContinue }: {
  creating?: boolean
  onClose: () => void
  onContinue: () => void
}): JSX.Element {
  const [step, setStep] = useState(0)
  const root = useRef<HTMLElement>(null)
  const nextButton = useRef<HTMLButtonElement>(null)
  const body = useRef<HTMLDivElement>(null)
  const id = useId()
  const current = STEPS[step]!
  useFocusTrap(root, { active: true, initialFocus: nextButton, onEscape: onClose })
  useEffect(() => acquirePointerPassthrough(), [])
  useEffect(() => { if (body.current) body.current.scrollTop = 0 }, [step])
  return createPortal(<div className="dialog-backdrop reading-guide-backdrop" onMouseDown={event => { if (event.target === event.currentTarget) onClose() }}>
    <section ref={root} className="reading-guide" role="dialog" aria-modal="true" aria-label="영어 읽기 사용 방법" aria-describedby={`${id}-intro`}>
      <header className="reading-guide-header"><div><p className="reading-guide-eyebrow">ENGLISH READING <span>처음이라면</span></p><h2>영어 기사 한 편이,<br />나의 단어가 되는 시간</h2><p id={`${id}-intro`}>읽고, 담고, 다시 만나는 영어 이어읽기.</p></div><button type="button" className="bare-icon-button" aria-label="소개 닫기" onClick={onClose}><Icon name="x" /></button></header>
      <nav className="reading-guide-steps" aria-label="사용 방법 단계">{STEPS.map((item, index) => <button key={item.label} type="button" aria-label={`${index + 1}. ${item.label}`} aria-current={step === index ? 'step' : undefined} onClick={() => setStep(index)}><span>{String(index + 1).padStart(2, '0')}</span>{item.label}<Icon name="chevronRight" /></button>)}</nav>
      <div className="reading-guide-body" ref={body} tabIndex={0} role="region" aria-label="단계별 사용 설명">
        <GuidePreview step={step} />
        <div className="reading-guide-explanation" aria-live="polite" aria-atomic="true"><p className="reading-guide-step-number">STEP {String(step + 1).padStart(2, '0')}</p><h3>{current.title}</h3><p className="reading-guide-description">{current.description}</p><ol>{current.instructions.map(([title, detail], index) => <li key={title}><span>{index + 1}</span><div><strong>{title}</strong><p>{detail}</p></div></li>)}</ol><p className="reading-guide-tip"><Icon name="help" /><span>{current.tip}</span></p></div>
      </div>
      <footer className="reading-guide-footer"><div>{step > 0 ? <button type="button" className="reading-guide-secondary" onClick={() => setStep(value => value - 1)}><Icon name="chevronLeft" /> 이전</button> : <button type="button" className="reading-guide-secondary" onClick={onContinue}>{creating ? '설정으로 건너뛰기' : '바로 시작하기'}</button>}</div><span className="reading-guide-pagination">{step + 1} / 3</span><button ref={nextButton} type="button" className="button button--primary reading-guide-next" onClick={() => step < STEPS.length - 1 ? setStep(value => value + 1) : onContinue()}>{step < STEPS.length - 1 ? '다음' : creating ? '관심 주제 고르기' : '읽기 시작하기'}<Icon name="chevronRight" /></button></footer>
    </section>
  </div>, document.body)
}
