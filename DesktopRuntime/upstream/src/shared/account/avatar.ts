/** Only account-provider image origins are exposed to the renderer's image CSP. */
export function accountAvatarUrl(metadata: Record<string, unknown> | undefined): string | null {
  for (const value of [metadata?.avatar_url, metadata?.picture, metadata?.profile_image]) {
    if (typeof value !== 'string') continue
    try {
      const url = new URL(value)
      const provider = ['googleusercontent.com', 'kakaocdn.net'].some(host => url.hostname === host || url.hostname.endsWith(`.${host}`))
      if (!provider || url.username || url.password || (url.port && url.port !== '443')) continue
      // Older Kakao profiles contain an HTTP URL for the same HTTPS-capable CDN.
      if (url.protocol === 'http:') url.protocol = 'https:'
      if (url.protocol === 'https:') return url.href
    } catch { /* Missing/invalid provider photos use the neutral avatar. */ }
  }
  return null
}
