import Foundation
import UIKit
import WebKit

/// Opaque WebKit interaction state deliberately never goes to disk. The same
/// website data store remains retained by the page, including private cookies.
struct BrowserPageRestoration {
    let interaction: Any
    let state: [String: Any]
    let frame: CGRect
    let zoom: CGFloat
    let documentOffset: CGPoint
}

enum BrowserMemoryScripts {
    static let world = WKContentWorld.world(name: "bandal-browser-memory")
    static let observe = """
    (()=>{
      let edited=false;
      for(const name of ['input','change'])addEventListener(name,e=>{if(e.isTrusted)edited=true},true);
      addEventListener('click',e=>{if(e.isTrusted&&e.target instanceof Element&&!e.target.closest('a[href]'))edited=true},true);
      globalThis.__bandalWasEdited=()=>edited;
    })();
    """
    // Fail closed for controls, embedded contexts and media whose live state
    // cannot be reconstructed from a URL. Even untouched login forms stay live.
    static let canSuspend = """
    if(document.readyState!=='complete'||!globalThis.__bandalWasEdited||globalThis.__bandalWasEdited())return false;
    if(document.querySelector('form,input,textarea,select,[contenteditable]:not([contenteditable="false"]),iframe,frame,object,embed,canvas,audio,video'))return false;
    if(document.fullscreenElement||document.pictureInPictureElement)return false;
    return {x:scrollX,y:scrollY};
    """
    // A didFinish delegate callback can precede WebKit's final restoration of
    // its scroll tree. Restore in the document coordinate space and wait for a
    // short stable interval; never fight input that arrives during restoration.
    static let restoreScroll = """
    let interrupted=false,stable=0;
    const events=['pointerdown','touchstart','wheel','keydown'];
    const cancel=e=>{if(e.isTrusted)interrupted=true};
    for(const name of events)addEventListener(name,cancel,true);
    try{
      for(let attempt=0;attempt<30;attempt++){
        if(interrupted||location.href!==url)return false;
        scrollTo({left:x,top:y,behavior:'instant'});
        await new Promise(resolve=>setTimeout(resolve,50));
        if(interrupted||location.href!==url)return false;
        if(Math.abs(scrollX-x)<=1&&Math.abs(scrollY-y)<=1){if(++stable>=5)return true}
        else stable=0;
      }
      return false;
    }finally{for(const name of events)removeEventListener(name,cancel,true)}
    """
}
