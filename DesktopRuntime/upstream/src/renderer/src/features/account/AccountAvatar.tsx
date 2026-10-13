import { useState } from 'react'
import { Icon } from '../../app/icons'
import './account.css'

interface AccountAvatarProps {
  avatarUrl: string | null
  nickname: string
  size?: 'sm' | 'md' | 'lg'
}

export function AccountAvatar({
  avatarUrl,
  nickname,
  size = 'md'
}: AccountAvatarProps): JSX.Element {
  const [failedUrl, setFailedUrl] = useState<string | null>(null)
  return (
    <span
      className="account-avatar"
      data-size={size}
      aria-hidden="true"
      title={nickname}
    >
      {avatarUrl && failedUrl !== avatarUrl
        ? <img key={avatarUrl} src={avatarUrl} alt="" referrerPolicy="no-referrer" onError={() => setFailedUrl(avatarUrl)} />
        : <Icon name="user" />}
    </span>
  )
}
