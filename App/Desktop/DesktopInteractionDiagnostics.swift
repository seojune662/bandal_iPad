import Foundation

/// Opt-in UI-test timing. This records event-to-next-render opportunity, not
/// physical display latency. No document content, control labels or text leave
/// the renderer. Real-device and simulator samples must be reported separately.
enum DesktopInteractionDiagnostics {
    /// An explicit, isolated test control exercises a real shell navigation
    /// after the same save barrier used by the visible recovery action.
    static let reloadScript = #"""
    document.addEventListener('DOMContentLoaded', () => {
      const key = 'bandal-ipad-reload-fixture';
      const count = Number(sessionStorage.getItem(key) || 0) + 1;
      sessionStorage.setItem(key, String(count));
      const button = document.createElement('button');
      button.textContent = '화면 다시 불러오기 검사 ' + count;
      button.setAttribute('data-bandal-native-overlay', 'true');
      Object.assign(button.style, {position:'fixed',right:'8px',bottom:'8px',minWidth:'44px',minHeight:'44px',zIndex:'99999',background:'white',color:'black'});
      button.onclick = async () => {
        button.disabled = true;
        try { await window.bandal.invoke('runtime:prepareReload', {}); window.location.reload(); }
        catch (error) { button.textContent = '화면 다시 불러오기 실패'; button.disabled = false; }
      };
      document.body.append(button);
    }, {once:true});
    """#

    static let script = #"""
    (() => {
      const samples = [];
      const publish = () => {
        let status = document.getElementById('ipad-interaction-timing');
        if (!status) {
          status = document.createElement('div'); status.id = 'ipad-interaction-timing';
          status.setAttribute('role', 'status');
          Object.assign(status.style, {position:'fixed',left:'0',bottom:'0',width:'1px',height:'1px',overflow:'hidden',pointerEvents:'none'});
          document.body.append(status);
        }
        const sorted = [...samples].sort((a,b) => a-b);
        const p95 = sorted[Math.min(sorted.length-1, Math.ceil(sorted.length*.95)-1)] || 0;
        status.setAttribute('aria-label', 'iPad interaction timing: count=' + samples.length + ' p95ms=' + p95.toFixed(2));
      };
      document.addEventListener('pointerdown', event => {
        if (!(event.target instanceof Element) || !event.target.closest('button,[role="button"],[role="switch"]')) return;
        const received = performance.now();
        const started = Number.isFinite(event.timeStamp) && event.timeStamp >= 0 && event.timeStamp <= received ? event.timeStamp : received;
        requestAnimationFrame(() => {
          samples.push(Math.max(0, performance.now()-started));
          if (samples.length > 1000) samples.shift();
          publish();
        });
      }, {capture:true,passive:true});
      // Tool changes happen on click, after pointerdown's RAF may have run.
      // Keep this separate: DOM selection at a RAF is not a native ACK or a
      // physical presentation timestamp. Failed selection is sampled too.
      const toolClicks = [];
      let toolSequence = 0;
      document.addEventListener('click', event => {
        const button = event.target instanceof Element ? event.target.closest('button[data-tool]') : null;
        if (!button) return;
        const received = performance.now(), sequence = ++toolSequence;
        const started = Number.isFinite(event.timeStamp) && event.timeStamp >= 0 && event.timeStamp <= received ? event.timeStamp : received;
        requestAnimationFrame(() => {
          const duration = Math.max(0, performance.now() - started);
          toolClicks.push(duration);
          if (toolClicks.length > 1000) toolClicks.shift();
          let status = document.getElementById('ipad-tool-click-timing');
          if (!status) {
            status = document.createElement('div'); status.id = 'ipad-tool-click-timing';
            status.setAttribute('role', 'status');
            Object.assign(status.style, {position:'fixed',left:'0',bottom:'0',width:'1px',height:'1px',overflow:'hidden',pointerEvents:'none'});
            document.body.append(status);
          }
          const sorted = [...toolClicks].sort((a,b) => a-b);
          const p95 = sorted[Math.min(sorted.length-1, Math.ceil(sorted.length*.95)-1)] || 0;
          status.setAttribute('aria-label', 'iPad tool click timing: count=' + toolClicks.length + ' seq=' + sequence
            + ' lastms=' + duration.toFixed(2) + ' p95ms=' + p95.toFixed(2)
            + ' selected=' + (button.isConnected && button.getAttribute('aria-pressed') === 'true')
            + ' latest=' + (sequence === toolSequence));
        });
      }, {capture:true,passive:true});
    })();
    """#
}
