import type { Locale } from '../../i18n'
import type { AgentProvider } from '../../../../shared/types/agent-events'

export const connectionProviderName = (provider: AgentProvider): string => provider === 'codex' ? 'ChatGPT' : provider === 'claude-code' ? 'Claude' : 'Gemini'

export function agentConnectionCopy(locale: Locale, provider: AgentProvider) {
  const name = connectionProviderName(provider)
  const english = locale === 'en-US'
  return english ? {
    title: `Use ${name} in Bandal`,
    description: 'Bandal prepares the connection for you. Just sign in with the account you already use.',
    subscription: provider === 'codex'
      ? 'Sign in with your existing ChatGPT account. Access and usage limits depend on your account’s plan.'
      : provider === 'claude-code'
        ? 'Requires Claude Pro, Max, or Claude Code access provided by your organization.'
        : 'Sign in with your Google account to connect Gemini.',
    preparation: 'Prepare', account: 'Sign in', ready: 'Ready', progress: 'Connection progress',
    connect: 'Connect', retry: 'Try again', installing: 'Preparing automatically…', checking: 'Checking installation…', opening: 'Opening sign-in…', waiting: 'Waiting for sign-in…', verifying: 'Checking your connection…',
    help: 'A sign-in page opens inside Bandal. Finish signing in there and the connection will complete automatically.',
    terminalHelp: 'Finish the Gemini sign-in in the terminal window. Bandal will confirm the connection automatically.',
    update: 'Bandal will update the connection tool and continue automatically.',
    readyMessage: `${name} is ready to use.`,
    reopen: 'Return to sign-in', cancel: 'Cancel sign-in', external: 'Use another browser',
    externalHelp: 'If your account provider blocks sign-in inside Bandal, you can continue in your default browser.',
    codeQuestion: 'Were you shown a login code?', codeHelp: 'Usually the connection completes automatically. Only paste a code here if the sign-in page explicitly shows one.', codeLabel: 'Login code', codeSubmit: 'Continue',
    repair: 'Prepare the connection tool again',
    details: 'Connection details', logs: 'Preparation log', command: 'Manual installation command', copy: 'Copy command', copied: 'Copied',
    sharedLimits: 'Your provider’s usage limits apply in Bandal too.',
    automatic: 'The connection tool is installed automatically. You do not need to enter commands.',
    browserOnly: 'Only used the website before? Use the same account here.',
  } : {
    title: `반달에서 ${name} 사용하기`,
    description: '준비는 반달이 할게요. 평소 쓰던 계정으로 로그인만 해 주세요.',
    subscription: provider === 'codex'
      ? '사용 중인 ChatGPT 계정으로 연결합니다. 이용 가능 여부와 한도는 계정 요금제에 따라 달라요.'
      : provider === 'claude-code'
        ? 'Claude Pro·Max 또는 조직에서 제공한 Claude Code 이용 권한이 필요해요.'
        : '사용 중인 Google 계정으로 Gemini를 연결할 수 있어요.',
    preparation: '자동 준비', account: '계정 로그인', ready: '연결 완료', progress: 'AI 연결 진행 단계',
    connect: '연결하기', retry: '다시 연결하기', installing: '자동으로 준비 중…', checking: '설치 확인 중…', opening: '로그인 페이지 여는 중…', waiting: '로그인을 기다리는 중…', verifying: '연결 확인 중…',
    help: '반달 안에 열린 로그인 페이지에서 로그인해 주세요. 마치면 자동으로 연결됩니다.',
    terminalHelp: '열린 터미널에서 Gemini 로그인을 마치면 반달이 자동으로 연결을 확인해요.',
    update: '연결 도구를 업데이트한 뒤 자동으로 이어갈게요.',
    readyMessage: `${name} 연결이 완료됐어요. 이제 반달에서 사용할 수 있어요.`,
    reopen: '로그인 페이지로 돌아가기', cancel: '로그인 취소', external: '다른 브라우저에서 로그인',
    externalHelp: '계정 제공자가 반달 안의 로그인을 제한하는 경우 기본 브라우저에서 이어갈 수 있어요.',
    codeQuestion: '로그인 코드가 표시됐나요?', codeHelp: '보통은 자동으로 연결돼요. 로그인 페이지에서 코드를 안내하는 경우에만 여기에 붙여넣어 주세요.', codeLabel: '로그인 코드', codeSubmit: '연결 계속하기',
    repair: '연결 도구 다시 준비하기',
    details: '연결 상세 정보', logs: '준비 과정 기록', command: '직접 설치할 때 쓰는 명령어', copy: '명령어 복사', copied: '복사됨',
    sharedLimits: '반달에서도 해당 서비스의 이용 한도가 적용돼요.',
    automatic: '연결에 필요한 도구는 자동으로 설치해요. 명령어를 입력할 필요가 없어요.',
    browserOnly: '웹사이트에서만 사용했어도, 같은 계정으로 시작하세요.',
  }
}
