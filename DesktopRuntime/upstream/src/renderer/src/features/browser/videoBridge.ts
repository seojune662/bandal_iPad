import { useEffect, useSyncExternalStore, type RefObject } from 'react'
import { invoke } from '../../lib/ipc'
import type { BrowserPageHandle } from './browserPageTypes'

export const VIDEO_REPORT_PREFIX = '__bandal_video__'

interface WebviewConsoleMessageEvent extends Event {
  message: string
}

export interface WebVideoReport {
  hasPlayingVideo: boolean
  currentTime: number
  playbackRate: number
  paused: boolean
  videoIndex: number
  aspect?: number
  pageUrl: string
  title: string
}

export interface WebVideoResumeRequest {
  positionSec: number
  playbackRate: number
}

const validPageUrl = (value: unknown): value is string => {
  if (typeof value !== 'string') return false
  try {
    const protocol = new URL(value).protocol
    return protocol === 'http:' || protocol === 'https:'
  } catch {
    return false
  }
}

function reportFrom(value: unknown): WebVideoReport | null {
  if (typeof value !== 'object' || value === null) return null
  const report = value as Record<string, unknown>
  if (
    typeof report['hasPlayingVideo'] !== 'boolean' ||
    typeof report['currentTime'] !== 'number' ||
    !Number.isFinite(report['currentTime']) ||
    report['currentTime'] < 0 ||
    typeof report['playbackRate'] !== 'number' ||
    !Number.isFinite(report['playbackRate']) ||
    report['playbackRate'] <= 0 ||
    typeof report['paused'] !== 'boolean' ||
    typeof report['videoIndex'] !== 'number' ||
    !Number.isInteger(report['videoIndex']) ||
    report['videoIndex'] < -1 ||
    !validPageUrl(report['pageUrl']) ||
    typeof report['title'] !== 'string'
  ) {
    return null
  }
  return {
    hasPlayingVideo: report['hasPlayingVideo'],
    currentTime: report['currentTime'],
    playbackRate: report['playbackRate'],
    paused: report['paused'],
    videoIndex: report['videoIndex'],
    ...(typeof report['aspect'] === 'number' &&
    Number.isFinite(report['aspect']) &&
    report['aspect'] > 0
      ? { aspect: report['aspect'] }
      : {}),
    pageUrl: report['pageUrl'],
    title: report['title']
  }
}

export function parseVideoReport(message: string): WebVideoReport | null {
  if (!message.startsWith(VIDEO_REPORT_PREFIX)) return null
  try {
    return reportFrom(JSON.parse(message.slice(VIDEO_REPORT_PREFIX.length)))
  } catch {
    return null
  }
}

/** Top-frame media 상태만 보내며 이벤트 묶음은 마지막 변화 1초 뒤 보고한다. */
export const VIDEO_REPORTER_SOURCE = `(() => {
  if (window.top !== window || window.__bandalVideoReporterInstalledV1__ === true) return;
  Object.defineProperty(window, '__bandalVideoReporterInstalledV1__', {
    value: true, configurable: false, enumerable: false, writable: false
  });
  const prefix = ${JSON.stringify(VIDEO_REPORT_PREFIX)};
  const pick = () => {
    const videos = Array.from(document.querySelectorAll('video'));
    return videos.find((video) => !video.paused && !video.ended) ||
      videos.find((video) => video.currentTime > 0 && !video.ended) ||
      videos[0] || null;
  };
  let previous = '';
  let timer = 0;
  const report = () => {
    timer = 0;
    const video = pick();
    const payload = {
      hasPlayingVideo: video !== null,
      currentTime: video !== null && Number.isFinite(video.currentTime)
        ? Math.max(0, video.currentTime) : 0,
      playbackRate: video !== null && Number.isFinite(video.playbackRate) && video.playbackRate > 0
        ? video.playbackRate : 1,
      paused: video === null || video.paused,
      videoIndex: video === null ? -1 : Array.from(document.querySelectorAll('video')).indexOf(video),
      aspect: video !== null && video.videoWidth > 0 && video.videoHeight > 0
        ? video.videoWidth / video.videoHeight : undefined,
      pageUrl: location.href,
      title: document.title
    };
    const serialized = JSON.stringify(payload);
    if (serialized === previous) return;
    previous = serialized;
    console.log(prefix + serialized);
  };
  const schedule = () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(report, 1000);
  };
  for (const event of ['play', 'pause', 'timeupdate', 'ratechange', 'loadedmetadata', 'emptied']) {
    document.addEventListener(event, schedule, true);
  }
  new MutationObserver(schedule).observe(document.documentElement, {
    childList: true, subtree: true
  });
  report();
})();`

export const VIDEO_PAUSE_SOURCE = `(() => {
  const videos = Array.from(document.querySelectorAll('video'));
  const video = videos.find((item) => !item.paused && !item.ended) ||
    videos.find((item) => item.currentTime > 0 && !item.ended) ||
    videos[0] || null;
  if (video === null) return null;
  const paused = video.paused;
  const payload = {
    hasPlayingVideo: true,
    currentTime: Number.isFinite(video.currentTime) ? Math.max(0, video.currentTime) : 0,
    playbackRate: Number.isFinite(video.playbackRate) && video.playbackRate > 0
      ? video.playbackRate : 1,
    paused,
    videoIndex: Array.from(document.querySelectorAll('video')).indexOf(video),
    aspect: video.videoWidth > 0 && video.videoHeight > 0
      ? video.videoWidth / video.videoHeight : undefined,
    pageUrl: location.href,
    title: document.title
  };
  video.pause();
  return payload;
})()`

const reports = new Map<string, WebVideoReport>()
const listeners = new Map<string, Set<() => void>>()
const elements = new Map<string, BrowserPageHandle>()
const readyTabs = new Set<string>()
const pendingResumes = new Map<string, WebVideoResumeRequest>()

function notify(tabId: string): void {
  for (const listener of listeners.get(tabId) ?? []) listener()
}

function updateReport(tabId: string, report: WebVideoReport | null): void {
  const previous = reports.get(tabId)
  if (report === null) {
    if (previous === undefined) return
    reports.delete(tabId)
    notify(tabId)
    return
  }
  if (
    previous !== undefined &&
    previous.hasPlayingVideo === report.hasPlayingVideo &&
    previous.currentTime === report.currentTime &&
    previous.playbackRate === report.playbackRate &&
    previous.paused === report.paused &&
    previous.videoIndex === report.videoIndex &&
    previous.aspect === report.aspect &&
    previous.pageUrl === report.pageUrl &&
    previous.title === report.title
  ) {
    return
  }
  reports.set(tabId, report)
  notify(tabId)
}

export function videoReportForTab(tabId: string): WebVideoReport | null {
  return reports.get(tabId) ?? null
}

export function useWebVideoReport(tabId: string): WebVideoReport | null {
  return useSyncExternalStore(
    (listener) => {
      const tabListeners = listeners.get(tabId) ?? new Set<() => void>()
      tabListeners.add(listener)
      listeners.set(tabId, tabListeners)
      return () => {
        tabListeners.delete(listener)
        if (tabListeners.size === 0) listeners.delete(tabId)
      }
    },
    () => videoReportForTab(tabId),
    () => null
  )
}

function resumeSource(request: WebVideoResumeRequest): string {
  const positionSec = Number.isFinite(request.positionSec)
    ? Math.max(0, request.positionSec)
    : 0
  const playbackRate =
    Number.isFinite(request.playbackRate) && request.playbackRate > 0
      ? request.playbackRate
      : 1
  return `(() => {
    const resume = (video) => {
      const apply = () => {
        video.playbackRate = ${JSON.stringify(playbackRate)};
        video.currentTime = ${JSON.stringify(positionSec)};
        void video.play().catch(() => undefined);
      };
      if (video.readyState === 0) video.addEventListener('loadedmetadata', apply, { once: true });
      else apply();
    };
    const pick = () => {
      const videos = Array.from(document.querySelectorAll('video'));
      return videos.find((video) => !video.paused && !video.ended) ||
        videos.find((video) => video.currentTime > 0 && !video.ended) ||
        videos[0] || null;
    };
    const current = pick();
    if (current !== null) {
      resume(current);
      return true;
    }
    const observer = new MutationObserver(() => {
      const video = pick();
      if (video === null) return;
      observer.disconnect();
      resume(video);
    });
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.setTimeout(() => observer.disconnect(), 15000);
    return false;
  })()`
}

function applyPendingResume(tabId: string, webview: BrowserPageHandle): void {
  const request = pendingResumes.get(tabId)
  if (request === undefined || !readyTabs.has(tabId)) return
  pendingResumes.delete(tabId)
  try {
    void webview.executeJavaScript(resumeSource(request)).catch(() => {
      if (!pendingResumes.has(tabId)) pendingResumes.set(tabId, request)
    })
  } catch {
    if (!pendingResumes.has(tabId)) pendingResumes.set(tabId, request)
  }
}

export function requestWebVideoResume(
  tabId: string,
  request: WebVideoResumeRequest
): void {
  pendingResumes.set(tabId, request)
  const webview = elements.get(tabId)
  if (webview !== undefined) applyPendingResume(tabId, webview)
}

export async function openWebVideoInPip(
  tabId: string,
  fallback: { url: string; title: string }
): Promise<void> {
  const webview = elements.get(tabId)
  const reported = videoReportForTab(tabId)
  let pausedSnapshot: WebVideoReport | null = null
  if (webview !== undefined && readyTabs.has(tabId)) {
    try {
      pausedSnapshot = reportFrom(
        await webview.executeJavaScript(VIDEO_PAUSE_SOURCE)
      )
    } catch {
      pausedSnapshot = null
    }
  }
  const snapshot = pausedSnapshot ?? reported
  if (snapshot === null && fallback.url === '') return
  await invoke('pip:open', {
    source: {
      kind: 'web',
      url: snapshot?.pageUrl ?? fallback.url,
      title: snapshot?.title || fallback.title,
      ...(snapshot === null
        ? {}
        : {
            videoHint: {
              index: snapshot.videoIndex,
              ...(snapshot.aspect === undefined
                ? {}
                : { aspect: snapshot.aspect })
            }
          })
    },
    positionSec: snapshot?.currentTime ?? 0,
    playbackRate: snapshot?.playbackRate ?? 1,
    paused: snapshot?.paused ?? false
  })
}

export function useBrowserVideoBridge(
  tabId: string,
  webviewRef: RefObject<BrowserPageHandle | null>
): void {
  useEffect(() => {
    const webview = webviewRef.current
    if (webview === null) return
    elements.set(tabId, webview)

    const inject = (): void => {
      try {
        void webview
          .executeJavaScript(VIDEO_REPORTER_SOURCE)
          .catch(() => undefined)
      } catch {
        // 다음 dom-ready에서 다시 주입한다.
      }
    }
    const onDomReady = (): void => {
      readyTabs.add(tabId)
      inject()
      applyPendingResume(tabId, webview)
    }
    const onStartLoading = (): void => {
      try {
        if (!webview.isLoadingMainFrame()) return
      } catch {
        // attach 경쟁은 메인 프레임 이동으로 취급한다.
      }
      readyTabs.delete(tabId)
      updateReport(tabId, null)
    }
    const onConsoleMessage = (rawEvent: Event): void => {
      const event = rawEvent as WebviewConsoleMessageEvent
      if (typeof event.message !== 'string') return
      const report = parseVideoReport(event.message)
      if (report !== null) updateReport(tabId, report)
    }

    webview.addEventListener('dom-ready', onDomReady)
    webview.addEventListener('did-start-loading', onStartLoading)
    webview.addEventListener('console-message', onConsoleMessage)
    inject()
    return () => {
      webview.removeEventListener('dom-ready', onDomReady)
      webview.removeEventListener('did-start-loading', onStartLoading)
      webview.removeEventListener('console-message', onConsoleMessage)
      if (elements.get(tabId) === webview) elements.delete(tabId)
      readyTabs.delete(tabId)
      updateReport(tabId, null)
    }
  }, [tabId, webviewRef])
}
