import type { PipSource } from '../../shared/types/pip'

export interface WebPipIsolationResult {
  ready: boolean
  aspect?: number
}

/**
 * Runs inside the browsing partition. Keeping the original document alive is
 * important: MediaSource/DRM streams usually cannot be copied to another
 * renderer. We instead reduce that document to its player surface.
 */
export function webPipIsolationSource(
  source: Extract<PipSource, { kind: 'web' }>,
  positionSec: number,
  playbackRate: number,
  paused: boolean
): string {
  const preferredIndex = source.videoHint?.index ?? -1
  return `new Promise((resolve) => {
    const deadline = Date.now() + 12000;
    const preferredIndex = ${JSON.stringify(preferredIndex)};
    const positionSec = ${JSON.stringify(positionSec)};
    const playbackRate = ${JSON.stringify(playbackRate)};
    const shouldPause = ${JSON.stringify(paused)};
    const styleId = '__bandal_web_pip_style__';
    const selectVideo = () => {
      const videos = Array.from(document.querySelectorAll('video'));
      const preferred = preferredIndex >= 0 ? videos[preferredIndex] : null;
      return preferred instanceof HTMLVideoElement ? preferred :
        videos.find((video) => !video.paused && !video.ended) ||
        videos.find((video) => video.currentTime > 0 && !video.ended) ||
        videos[0] || null;
    };
    const isolate = () => {
      const video = selectVideo();
      if (!(video instanceof HTMLVideoElement)) return false;
      const youtubePlayer = video.closest('#movie_player');
      const root = youtubePlayer instanceof HTMLElement ? youtubePlayer : video;
      document.getElementById(styleId)?.remove();
      const style = document.createElement('style');
      style.id = styleId;
      style.textContent = [
        'html,body{margin:0!important;width:100%!important;height:100%!important;overflow:hidden!important;background:#000!important}',
        'body *{visibility:hidden!important}',
        '[data-bandal-pip-root], [data-bandal-pip-root] *{visibility:visible!important}',
        '[data-bandal-pip-root]{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;transform:none!important;background:#000!important;z-index:2147483647!important}',
        '[data-bandal-pip-video]{display:block!important;position:absolute!important;inset:0!important;width:100%!important;height:100%!important;max-width:none!important;max-height:none!important;margin:0!important;object-fit:contain!important;background:#000!important}'
      ].join('');
      (document.head || document.documentElement).appendChild(style);
      root.setAttribute('data-bandal-pip-root', '');
      video.setAttribute('data-bandal-pip-video', '');
      if (youtubePlayer === null) video.controls = true;
      const start = () => {
        try { video.currentTime = Math.max(0, positionSec); } catch {}
        video.playbackRate = playbackRate > 0 ? playbackRate : 1;
        if (shouldPause) video.pause();
        else void video.play().catch(() => undefined);
      };
      if (video.readyState === 0) video.addEventListener('loadedmetadata', start, { once: true });
      else start();
      const aspect = video.videoWidth > 0 && video.videoHeight > 0
        ? video.videoWidth / video.videoHeight
        : ${JSON.stringify(source.videoHint?.aspect ?? null)};
      resolve({ ready: true, ...(typeof aspect === 'number' && aspect > 0 ? { aspect } : {}) });
      return true;
    };
    if (isolate()) return;
    const observer = new MutationObserver(() => {
      if (!isolate()) return;
      observer.disconnect();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    const wait = () => {
      if (Date.now() < deadline) {
        window.setTimeout(wait, 250);
        return;
      }
      observer.disconnect();
      resolve({ ready: false });
    };
    window.setTimeout(wait, 250);
  })`
}

export function isWebPipIsolationResult(
  value: unknown
): value is WebPipIsolationResult {
  if (typeof value !== 'object' || value === null) return false
  const result = value as Record<string, unknown>
  return (
    typeof result['ready'] === 'boolean' &&
    (result['aspect'] === undefined ||
      (typeof result['aspect'] === 'number' &&
        Number.isFinite(result['aspect']) &&
        result['aspect'] > 0))
  )
}
