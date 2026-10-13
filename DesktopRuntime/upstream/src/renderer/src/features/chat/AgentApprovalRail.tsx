import type { AgentConfirmScope } from '../../../../shared/types/agentTools'
import { AgentToolActivity } from './AgentToolCards'
import type { AgentToolActivityItem } from './agentToolActivityStore'

export interface AgentApprovalRailProps {
  items: readonly AgentToolActivityItem[]
  onRespondConfirm: (
    requestId: string,
    approved: boolean,
    scope?: AgentConfirmScope
  ) => void
  onUndoTurn: (turnId: string) => void
}

export function hasVisibleAgentToolActivity(
  items: readonly AgentToolActivityItem[]
): boolean {
  return items.some(
    (item) => item.kind === 'confirmation' || item.actions.length > 0
  )
}

export function AgentApprovalRail({
  items,
  onRespondConfirm,
  onUndoTurn
}: AgentApprovalRailProps): JSX.Element | null {
  if (!hasVisibleAgentToolActivity(items)) {
    return null
  }

  return (
    <aside className="chat-approval-rail" aria-label="승인 요청">
      <AgentToolActivity
        items={items}
        onRespondConfirm={onRespondConfirm}
        onUndoTurn={onUndoTurn}
      />
    </aside>
  )
}
