"use strict";
var BandalWebPip = (() => {
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // upstream/src/main/windows/webPipIsolation.ts
  var webPipIsolation_exports = {};
  __export(webPipIsolation_exports, {
    isWebPipIsolationResult: () => isWebPipIsolationResult,
    webPipIsolationSource: () => webPipIsolationSource
  });
  function webPipIsolationSource(source, positionSec, playbackRate, paused) {
    const preferredIndex = source.videoHint?.index ?? -1;
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
  })`;
  }
  function isWebPipIsolationResult(value) {
    if (typeof value !== "object" || value === null) return false;
    const result = value;
    return typeof result["ready"] === "boolean" && (result["aspect"] === void 0 || typeof result["aspect"] === "number" && Number.isFinite(result["aspect"]) && result["aspect"] > 0);
  }
  return __toCommonJS(webPipIsolation_exports);
})();
