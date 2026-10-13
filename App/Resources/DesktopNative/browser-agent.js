"use strict";
(() => {
  // DesktopRuntime/upstream/src/main/features/browserAgent/actionPolicy.ts
  var TYPEABLE_TAGS = /* @__PURE__ */ new Set(["input", "textarea"]);
  var NON_TEXT_INPUT_TYPES = /* @__PURE__ */ new Set([
    "button",
    "submit",
    "reset",
    "image",
    "file",
    "checkbox",
    "radio"
  ]);
  function isSubmitControl(facts2) {
    if (facts2.type === "submit" || facts2.type === "image") return true;
    if (facts2.tag === "button" && facts2.type === null && facts2.inNonGetForm) {
      return true;
    }
    return false;
  }
  function canClick(facts2) {
    if (facts2.disabled) {
      return {
        allowed: false,
        reason: "disabled",
        message: "\uADF8 \uD56D\uBAA9\uC740 \uC9C0\uAE08 \uB204\uB97C \uC218 \uC5C6\uB294 \uC0C1\uD0DC\uC608\uC694."
      };
    }
    if (isSubmitControl(facts2)) {
      return {
        allowed: false,
        reason: "submit",
        message: "\uC81C\uCD9C\uC740 \uBC18\uB2EC\uC774 \uB300\uC2E0 \uB204\uB974\uC9C0 \uC54A\uC2B5\uB2C8\uB2E4. \uB0B4\uC6A9\uC744 \uD655\uC778\uD558\uACE0 \uC9C1\uC811 \uB20C\uB7EC \uC8FC\uC138\uC694."
      };
    }
    return { allowed: true };
  }
  function canType(facts2) {
    if (facts2.disabled) {
      return {
        allowed: false,
        reason: "disabled",
        message: "\uADF8 \uCE78\uC740 \uC9C0\uAE08 \uC785\uB825\uD560 \uC218 \uC5C6\uB294 \uC0C1\uD0DC\uC608\uC694."
      };
    }
    if (facts2.type === "password") {
      return {
        allowed: false,
        reason: "password",
        message: "\uBE44\uBC00\uBC88\uD638 \uCE78\uC5D0\uB294 \uC785\uB825\uD558\uC9C0 \uC54A\uC2B5\uB2C8\uB2E4. \uC800\uC7A5\uB41C \uB85C\uADF8\uC778\uC744 \uC4F0\uAC70\uB098 \uC9C1\uC811 \uC785\uB825\uD574 \uC8FC\uC138\uC694."
      };
    }
    if (!TYPEABLE_TAGS.has(facts2.tag)) {
      return {
        allowed: false,
        reason: "not-typeable",
        message: "\uADF8 \uC694\uC18C\uC5D0\uB294 \uAE00\uC744 \uC785\uB825\uD560 \uC218 \uC5C6\uC5B4\uC694."
      };
    }
    if (facts2.tag === "input" && facts2.type !== null && NON_TEXT_INPUT_TYPES.has(facts2.type)) {
      return {
        allowed: false,
        reason: "not-typeable",
        message: "\uADF8 \uCE78\uC740 \uAE00\uC744 \uC785\uB825\uD558\uB294 \uCE78\uC774 \uC544\uB2C8\uC5D0\uC694."
      };
    }
    return { allowed: true };
  }
  function canSelect(facts2) {
    if (facts2.disabled) {
      return {
        allowed: false,
        reason: "disabled",
        message: "\uADF8 \uD56D\uBAA9\uC740 \uC9C0\uAE08 \uC120\uD0DD\uD560 \uC218 \uC5C6\uB294 \uC0C1\uD0DC\uC608\uC694."
      };
    }
    if (facts2.tag !== "select") {
      return {
        allowed: false,
        reason: "not-selectable",
        message: "\uADF8 \uC694\uC18C\uB294 \uC120\uD0DD \uBAA9\uB85D\uC774 \uC544\uB2C8\uC5D0\uC694."
      };
    }
    return { allowed: true };
  }

  // DesktopRuntime/upstream/src/main/features/browserAgent/snapshot.ts
  var DEFAULT_SNAPSHOT_CHARS = 6e3;
  var MAX_SNAPSHOT_CHARS = 2e4;
  var TARGET_SELECTOR = "a, button, input, select, textarea, h1, h2, h3, [role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [onclick], label, summary";
  var TARGET_INDEX_SOURCE = `
  const visible = (el) => {
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden') return false;
    if (Number(style.opacity) === 0) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };

  const textOf = (node, max = 120) => {
    const text = (node && node.textContent ? node.textContent : '')
      .replace(/\\s+/g, ' ')
      .trim();
    return text.slice(0, max);
  };

  const labelledByName = (el) => {
    const ids = (el.getAttribute('aria-labelledby') || '').trim().split(/\\s+/).filter(Boolean);
    if (ids.length === 0) return '';
    return ids.map((id) => textOf(document.getElementById(id))).filter(Boolean).join(' ').slice(0, 120);
  };

  // Korean portals commonly put a select after a th/td heading cell, or
  // directly after a text node, without a real label.
  const nearbySelectName = (el) => {
    let sibling = el.previousSibling;
    while (sibling) {
      const text = textOf(sibling, 60);
      if (text) return text;
      sibling = sibling.previousSibling;
    }
    const parent = el.parentElement;
    if (parent) {
      const previousCell = parent.previousElementSibling;
      const text = textOf(previousCell, 60);
      if (text) return text;
    }
    return '';
  };

  const nameOf = (el) => {
    const aria = el.getAttribute('aria-label');
    if (aria && aria.trim()) return aria.trim();
    if (el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA') {
      const id = el.getAttribute('id');
      if (id) {
        const label = document.querySelector('label[for="' + CSS.escape(id) + '"]');
        const labelText = textOf(label);
        if (labelText) return labelText;
      }
      const wrapping = el.closest('label');
      const wrappingText = textOf(wrapping);
      if (wrappingText) return wrappingText;
      const labelledBy = labelledByName(el);
      if (labelledBy) return labelledBy;
      if (el.tagName === 'SELECT') {
        const nearby = nearbySelectName(el);
        if (nearby) return nearby;
      }
      const placeholder = el.getAttribute('placeholder');
      if (placeholder && placeholder.trim()) return placeholder.trim();
      const name = el.getAttribute('name');
      if (name) return name;
      return '';
    } else {
      const labelledBy = labelledByName(el);
      if (labelledBy) return labelledBy;
    }
    return textOf(el);
  };

  const inNonGetForm = (el) => {
    const form = el.closest('form');
    if (!form) return false;
    return (form.getAttribute('method') || 'get').toLowerCase() !== 'get';
  };

  const roleOf = (el) => {
    const tag = el.tagName.toLowerCase();
    const explicitRole = (el.getAttribute('role') || '').toLowerCase();
    if (explicitRole === 'button' || explicitRole === 'link' || explicitRole === 'tab' ||
        explicitRole === 'menuitem' || explicitRole === 'checkbox') return explicitRole;
    if (tag === 'a') return 'link';
    if (tag === 'button') return 'button';
    if (tag === 'summary') return 'button';
    if (tag === 'select') return 'select';
    if (tag === 'textarea') return 'textbox';
    if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (type === 'checkbox' || type === 'radio') return 'checkbox';
      if (type === 'button' || type === 'submit' || type === 'reset' || type === 'image') {
        return 'button';
      }
      return 'textbox';
    }
    if (/^h[1-6]$/.test(tag)) return 'heading';
    if (el.hasAttribute('onclick')) return 'button';
    return 'text';
  };

  const __bandalTargets = () => {
    const seenTargets = new Set();
    const targets = [];
    document.querySelectorAll('${TARGET_SELECTOR}').forEach((el) => {
      if (seenTargets.has(el)) return;
      if (!visible(el)) return;
      seenTargets.add(el);
      // Nameless rows consume context without telling the model what it can
      // use \u2014 and they must be skipped HERE so every consumer skips them.
      if (!nameOf(el)) return;
      targets.push(el);
    });
    return targets;
  };
`;
  var SNAPSHOT_SOURCE = `(() => {
  const MAX_ELEMENTS = 250;
  const MAX_OPTIONS = 20;
  const out = [];
  let omittedElementCount = 0;

${TARGET_INDEX_SOURCE}

  const collect = (el) => {
    // Visibility, dedup and the nameless skip already happened in
    // __bandalTargets \u2014 doing them again here is how the copies drifted.
    const name = nameOf(el);
    if (out.length >= MAX_ELEMENTS) {
      omittedElementCount += 1;
      return;
    }
    const tag = el.tagName.toLowerCase();
    const type = el.getAttribute ? (el.getAttribute('type') || '').toLowerCase() : '';
    const selectOptions = tag === 'select' ? Array.from(el.options || []) : [];
    out.push({
      index: out.length,
      role: roleOf(el),
      name,
      href: tag === 'a' ? el.getAttribute('href') : null,
      tag: tag,
      type: type === '' ? null : type,
      inNonGetForm: inNonGetForm(el),
      disabled: Boolean(el.disabled),
      // Never report the contents of a password field, not even its length.
      value: type === 'password' ? null : (el.value == null ? null : String(el.value).slice(0, 80)),
      required: Boolean(el.required),
      options: tag === 'select'
        ? selectOptions.slice(0, MAX_OPTIONS).map((option) => ({
            value: String(option.value),
            label: String(option.label || option.textContent || '')
              .replace(/\\s+/g, ' ')
              .trim()
              .slice(0, 60)
          }))
        : undefined,
      optionCount: tag === 'select' ? selectOptions.length : undefined
    });
  };

  __bandalTargets().forEach(collect);

  return { url: location.href, elements: out, omittedElementCount };
})()`;
  function renderSnapshot(frames, generation, maxChars = DEFAULT_SNAPSHOT_CHARS) {
    const budget = Math.min(Math.max(maxChars, 500), MAX_SNAPSHOT_CHARS);
    const lines = [];
    let used = 0;
    let currentFrameElementsOmitted = 0;
    let currentFrameCappedElements = 0;
    let wholeFramesOmitted = 0;
    let budgetTruncated = false;
    const pushWithinBudget = (line) => {
      const cost = line.length + (lines.length === 0 ? 0 : 1);
      if (used + cost > budget) return false;
      lines.push(line);
      used += cost;
      return true;
    };
    for (const [framePosition, frame] of frames.entries()) {
      currentFrameCappedElements = frame.omittedElementCount ?? 0;
      const header = renderFrameHeader(frame);
      if (!pushWithinBudget(header)) {
        budgetTruncated = true;
        wholeFramesOmitted = frames.length - framePosition;
        break;
      }
      for (const [elementPosition, element] of frame.elements.entries()) {
        const line = renderElement(frame.frameIndex, element, generation);
        if (!pushWithinBudget(line)) {
          budgetTruncated = true;
          currentFrameElementsOmitted = frame.elements.length - elementPosition;
          wholeFramesOmitted = frames.length - framePosition - 1;
          break;
        }
      }
      if (budgetTruncated) break;
      const omitted = frame.omittedElementCount ?? 0;
      if (omitted > 0) {
        const notice = `(\uC774 \uD504\uB808\uC784\uC5D0\uC11C ${omitted}\uAC1C \uB354 \uC788\uB294\uB370 \uC0DD\uB7B5\uD588\uC5B4\uC694)`;
        const cost = notice.length + (lines.length === 0 ? 0 : 1);
        lines.push(notice);
        used += cost;
      }
    }
    if (budgetTruncated) {
      if (currentFrameElementsOmitted > 0) {
        lines.push(`(\uBB38\uC790 \uC608\uC0B0 \uB54C\uBB38\uC5D0 \uC774 \uD504\uB808\uC784 \uC694\uC18C ${currentFrameElementsOmitted}\uAC1C\uB97C \uB354 \uBCF4\uC5EC\uC8FC\uC9C0 \uBABB\uD588\uC5B4\uC694)`);
      }
      if (currentFrameElementsOmitted > 0 && currentFrameCappedElements > 0) {
        lines.push(
          `(\uC774 \uD504\uB808\uC784\uC5D0\uC11C ${currentFrameCappedElements}\uAC1C \uB354 \uC788\uB294\uB370 \uC0DD\uB7B5\uD588\uC5B4\uC694)`
        );
      }
      if (wholeFramesOmitted > 0) {
        lines.push(`(\uD504\uB808\uC784 ${wholeFramesOmitted}\uAC1C\uB97C \uB354 \uBCF4\uC5EC\uC8FC\uC9C0 \uBABB\uD588\uC5B4\uC694 \u2014 maxChars\uB97C \uC62C\uB824 \uBCF4\uC138\uC694)`);
      } else if (currentFrameElementsOmitted === 0) {
        lines.push("(\uBB38\uC790 \uC608\uC0B0 \uB54C\uBB38\uC5D0 \uC77C\uBD80 \uC815\uBCF4\uB97C \uB354 \uBCF4\uC5EC\uC8FC\uC9C0 \uBABB\uD588\uC5B4\uC694)");
      }
    }
    return lines.join("\n");
  }
  function renderFrameHeader(frame) {
    const address = frame.url === "" ? "(\uC8FC\uC18C \uC5C6\uC74C)" : frame.url;
    return `[f${frame.frameIndex}] ${address} (\uC694\uC18C ${frame.elements.length}\uAC1C)`;
  }
  function renderElement(frameIndex, element, generation) {
    const ref = `f${frameIndex}:e${element.index}@${generation}`;
    const name = element.name === "" ? "" : ` "${element.name}"`;
    const parts = [`${ref} ${element.role}${name}`];
    if (element.href !== null && element.href !== "") {
      parts.push(`\u2192 ${element.href}`);
    }
    const flags = [];
    if (element.disabled) flags.push("disabled");
    if (element.required) flags.push("required");
    if (element.type === "password") flags.push("password");
    if (element.value !== null && element.value !== "") {
      flags.push(`value=${JSON.stringify(element.value)}`);
    }
    if (flags.length > 0) parts.push(`(${flags.join(", ")})`);
    if (element.options !== void 0) {
      const visibleOptions = element.options.slice(0, 20);
      const renderedOptions = visibleOptions.map(
        ({ value, label }) => label === value ? label : `${label}=${value}`
      );
      const totalOptions = Math.max(
        element.optionCount ?? element.options.length,
        element.options.length
      );
      const omitted = totalOptions - visibleOptions.length;
      const suffix = omitted > 0 ? ` | \u2026\uC678 ${omitted}\uAC1C` : "";
      parts.push(`[\uC635\uC158 ${renderedOptions.join(" | ")}${suffix}]`);
    }
    return parts.join(" ");
  }
  var READ_SOURCE = `(() => {
  const text = (document.body ? document.body.innerText : '') || '';
  return { url: location.href, text: text.replace(/\\n{3,}/g, '\\n\\n') };
})()`;

  // DesktopRuntime/upstream/src/main/features/browserAgent/pageDriver.ts
  function toElements(raw) {
    if (!Array.isArray(raw)) return [];
    return raw.flatMap((entry, index) => {
      if (typeof entry !== "object" || entry === null) return [];
      const row = entry;
      return [
        {
          index: typeof row["index"] === "number" ? row["index"] : index,
          role: typeof row["role"] === "string" ? row["role"] : "text",
          name: typeof row["name"] === "string" ? row["name"] : "",
          href: typeof row["href"] === "string" ? row["href"] : null,
          tag: typeof row["tag"] === "string" ? row["tag"] : "",
          type: typeof row["type"] === "string" ? row["type"] : null,
          inNonGetForm: row["inNonGetForm"] === true,
          disabled: row["disabled"] === true,
          value: typeof row["value"] === "string" ? row["value"] : null,
          required: row["required"] === true
        }
      ];
    });
  }
  function toActResult(raw) {
    const row = typeof raw === "object" && raw !== null ? raw : {};
    const result = {
      ok: row["ok"] === true,
      facts: row["facts"] ?? null,
      problem: typeof row["problem"] === "string" ? row["problem"] : null
    };
    if (Array.isArray(row["options"])) {
      result.options = row["options"].flatMap((option) => {
        if (typeof option !== "object" || option === null) return [];
        const item = option;
        if (typeof item["value"] !== "string" || typeof item["label"] !== "string") {
          return [];
        }
        return [{ value: item["value"], label: item["label"] }];
      });
    }
    return result;
  }
  var PAGE_SCRIPT_TIMEOUT_MS = 5e3;
  var PageScriptTimeout = class extends Error {
    constructor() {
      super("\uD398\uC774\uC9C0\uAC00 \uC751\uB2F5\uD558\uC9C0 \uC54A\uC544\uC694. \uC54C\uB9BC \uCC3D\uC774 \uB5A0 \uC788\uB294\uC9C0 \uD655\uC778\uD574 \uC8FC\uC138\uC694.");
      this.name = "PageScriptTimeout";
    }
  };
  function runGuestScript(exec, timeoutMs = PAGE_SCRIPT_TIMEOUT_MS) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        reject(new PageScriptTimeout());
      }, timeoutMs);
      let pending;
      try {
        pending = exec();
      } catch (error) {
        settled = true;
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      pending.then(
        (value) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(value);
        },
        (error) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      );
    });
  }
  function createPageDriver(deps) {
    async function snapshot(generation, maxChars = DEFAULT_SNAPSHOT_CHARS) {
      const frames = deps.frames();
      const collected = [];
      for (const [frameIndex, frame] of frames.entries()) {
        try {
          const raw = await runGuestScript(
            () => frame.executeJavaScript(SNAPSHOT_SOURCE)
          );
          collected.push({
            frameIndex,
            url: typeof raw?.url === "string" ? raw.url : "",
            elements: toElements(raw?.elements)
          });
        } catch {
        }
      }
      return {
        url: deps.currentUrl(),
        outline: renderSnapshot(collected, generation, maxChars),
        frames: collected
      };
    }
    async function read(maxChars) {
      const [main] = deps.frames();
      if (main === void 0) return { url: deps.currentUrl(), text: "" };
      try {
        const raw = await runGuestScript(() => main.executeJavaScript(READ_SOURCE));
        const text = typeof raw?.text === "string" ? raw.text : "";
        return {
          url: deps.currentUrl(),
          text: text.slice(0, Math.max(500, maxChars))
        };
      } catch {
        return { url: deps.currentUrl(), text: "" };
      }
    }
    async function act(frameIndex, elementIndex, action) {
      const frame = deps.frames()[frameIndex];
      if (frame === void 0) {
        return {
          ok: false,
          facts: null,
          problem: "\uADF8 \uD504\uB808\uC784\uC744 \uCC3E\uC9C0 \uBABB\uD588\uC5B4\uC694."
        };
      }
      const payload = JSON.stringify({ index: elementIndex, action });
      const source = `(() => {
      const input = ${payload};
      ${TARGET_INDEX_SOURCE}
      // The SAME enumeration the snapshot used. Three copies of this had
      // drifted: this one did not filter \`opacity: 0\`, so one faded element
      // shifted every ordinal and a click landed on the neighbouring row \u2014
      // reporting success.
      const target = __bandalTargets()[input.index] || null;
      if (!target) return {
        ok: false,
        facts: null,
        problem: '\uADF8 \uC694\uC18C\uB97C \uCC3E\uC9C0 \uBABB\uD588\uC5B4\uC694. \uD398\uC774\uC9C0\uAC00 \uBC14\uB00C\uC5C8\uC744 \uC218 \uC788\uC5B4\uC694.'
      };
      const tag = target.tagName.toLowerCase();
      const type = (target.getAttribute('type') || '').toLowerCase();
      const form = target.closest('form');
      const facts = {
        tag: tag,
        type: type === '' ? null : type,
        inNonGetForm: form ? (form.getAttribute('method') || 'get').toLowerCase() !== 'get' : false,
        href: tag === 'a' ? target.getAttribute('href') : null,
        disabled: Boolean(target.disabled)
      };
      if (input.action.kind === 'facts') return { ok: true, facts: facts, problem: null };
      if (input.action.kind === 'click') {
        target.click();
        return { ok: true, facts: facts, problem: null };
      }
      if (input.action.kind === 'type') {
        const setter = Object.getOwnPropertyDescriptor(
          tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype,
          'value'
        );
        if (setter && setter.set) setter.set.call(target, input.action.text);
        else target.value = input.action.text;
        target.dispatchEvent(new Event('input', { bubbles: true }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
        if (target.value !== input.action.text) return {
          ok: false,
          facts: facts,
          problem: '\uC785\uB825\uC774 \uBC18\uC601\uB418\uC9C0 \uC54A\uC558\uC5B4\uC694.'
        };
        return { ok: true, facts: facts, problem: null };
      }
      if (input.action.kind === 'select') {
        if (target.tagName !== 'SELECT') return {
          ok: false,
          facts: facts,
          problem: 'select \uC694\uC18C\uAC00 \uC544\uB2C8\uC5D0\uC694.'
        };
        const selectOptions = Array.from(target.options);
        const options = selectOptions.slice(0, 200).map((option) => ({
          value: option.value,
          label: (option.textContent || '').trim().slice(0, 100)
        }));
        const wanted = input.action.value;
        let selectedIndex = selectOptions.findIndex((option) => option.value === wanted);
        if (selectedIndex < 0) {
          const wantedLabel = wanted.trim();
          selectedIndex = selectOptions.findIndex(
            (option) => (option.textContent || '').trim() === wantedLabel
          );
        }
        if (selectedIndex < 0) {
          const normalizedWanted = wanted.replace(/\\s+/g, '');
          selectedIndex = selectOptions.findIndex(
            (option) => (option.textContent || '').replace(/\\s+/g, '') === normalizedWanted
          );
        }
        if (selectedIndex < 0) return {
          ok: false,
          facts: facts,
          problem: '\uADF8 \uAC12\uC744 \uACE0\uB97C \uC218 \uC5C6\uC5B4\uC694.',
          options: options
        };
        const intendedValue = selectOptions[selectedIndex].value;
        target.selectedIndex = selectedIndex;
        target.dispatchEvent(new Event('input', { bubbles: true }));
        target.dispatchEvent(new Event('change', { bubbles: true }));
        if (target.value !== intendedValue) return {
          ok: false,
          facts: facts,
          problem: '\uAC12\uC744 \uBC14\uAFB8\uC9C0 \uBABB\uD588\uC5B4\uC694.',
          options: options
        };
        return { ok: true, facts: facts, problem: null, options: options };
      }
      return { ok: false, facts: facts, problem: '\uC9C0\uC6D0\uD558\uC9C0 \uC54A\uB294 \uD589\uB3D9\uC774\uC5D0\uC694.' };
    })()`;
      try {
        return toActResult(await runGuestScript(() => frame.executeJavaScript(source)));
      } catch {
        return {
          ok: false,
          facts: null,
          problem: "\uD398\uC774\uC9C0\uC5D0\uC11C \uC2E4\uD589\uD558\uC9C0 \uBABB\uD588\uC5B4\uC694."
        };
      }
    }
    async function factsFor(frameIndex, elementIndex) {
      const result = await act(frameIndex, elementIndex, {
        kind: "facts"
      });
      return result.facts;
    }
    async function scroll(to) {
      const frameIndex = to.kind === "ref" ? to.frameIndex : 0;
      const frame = deps.frames()[frameIndex];
      if (frame === void 0) {
        return { ok: false, facts: null, problem: "\uADF8 \uD504\uB808\uC784\uC744 \uCC3E\uC9C0 \uBABB\uD588\uC5B4\uC694." };
      }
      const payload = JSON.stringify(to);
      const source = `(() => {
      const input = ${payload};
      if (input.kind === 'ref') {
        ${TARGET_INDEX_SOURCE}
        const target = __bandalTargets()[input.elementIndex] || null;
        if (!target) return {
          ok: false,
          facts: null,
          problem: '\uADF8 \uC694\uC18C\uB97C \uCC3E\uC9C0 \uBABB\uD588\uC5B4\uC694. \uD398\uC774\uC9C0\uAC00 \uBC14\uB00C\uC5C8\uC744 \uC218 \uC788\uC5B4\uC694.'
        };
        target.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' });
        return { ok: true, facts: null, problem: null };
      }
      const height = Math.max(1, Math.floor(window.innerHeight * 0.8));
      if (input.kind === 'down') window.scrollBy({ top: height, behavior: 'auto' });
      else if (input.kind === 'up') window.scrollBy({ top: -height, behavior: 'auto' });
      else if (input.kind === 'top') window.scrollTo({ top: 0, behavior: 'auto' });
      else if (input.kind === 'bottom') window.scrollTo({
        top: Math.max(document.documentElement.scrollHeight, document.body?.scrollHeight || 0),
        behavior: 'auto'
      });
      else return { ok: false, facts: null, problem: '\uC9C0\uC6D0\uD558\uC9C0 \uC54A\uB294 \uC2A4\uD06C\uB864\uC774\uC5D0\uC694.' };
      return { ok: true, facts: null, problem: null };
    })()`;
      try {
        return toActResult(await runGuestScript(() => frame.executeJavaScript(source)));
      } catch {
        return { ok: false, facts: null, problem: "\uD398\uC774\uC9C0\uC5D0\uC11C \uC2A4\uD06C\uB864\uD558\uC9C0 \uBABB\uD588\uC5B4\uC694." };
      }
    }
    async function hover(frameIndex, elementIndex) {
      const frame = deps.frames()[frameIndex];
      if (frame === void 0) {
        return { ok: false, facts: null, problem: "\uADF8 \uD504\uB808\uC784\uC744 \uCC3E\uC9C0 \uBABB\uD588\uC5B4\uC694." };
      }
      const source = `(() => {
      ${TARGET_INDEX_SOURCE}
      const target = __bandalTargets()[${JSON.stringify(elementIndex)}] || null;
      if (!target) return {
        ok: false,
        facts: null,
        problem: '\uADF8 \uC694\uC18C\uB97C \uCC3E\uC9C0 \uBABB\uD588\uC5B4\uC694. \uD398\uC774\uC9C0\uAC00 \uBC14\uB00C\uC5C8\uC744 \uC218 \uC788\uC5B4\uC694.'
      };
      for (const type of ['pointerover', 'mouseover', 'mouseenter', 'mousemove']) {
        const EventClass = type === 'pointerover' && typeof PointerEvent === 'function'
          ? PointerEvent
          : MouseEvent;
        target.dispatchEvent(new EventClass(type, {
          bubbles: type !== 'mouseenter', cancelable: true, view: window
        }));
      }
      return { ok: true, facts: null, problem: null };
    })()`;
      try {
        return toActResult(await runGuestScript(() => frame.executeJavaScript(source)));
      } catch {
        return { ok: false, facts: null, problem: "\uD398\uC774\uC9C0\uC5D0\uC11C \uB9C8\uC6B0\uC2A4\uB97C \uC62C\uB9AC\uC9C0 \uBABB\uD588\uC5B4\uC694." };
      }
    }
    return { snapshot, read, act, factsFor, scroll, hover };
  }
  function verdictFor(kind, facts2) {
    if (kind === "click") return canClick(facts2);
    if (kind === "type") return canType(facts2);
    return canSelect(facts2);
  }

  // DesktopRuntime/upstream/src/main/features/browserAgent/refs.ts
  var REF_PATTERN = /^f(\d+):e(\d+)@(\d+)$/;
  function parseRef(ref) {
    if (typeof ref !== "string") return null;
    const match = REF_PATTERN.exec(ref.trim());
    if (match === null) return null;
    const [, frame, element, generation] = match;
    return {
      frameIndex: Number(frame),
      elementIndex: Number(element),
      generation: Number(generation)
    };
  }
  function resolveRef(ref, generation) {
    const parsed = parseRef(ref);
    if (parsed === null) {
      return {
        ok: false,
        reason: "malformed",
        message: "\uC694\uC18C \uCC38\uC870 \uD615\uC2DD\uC774 \uC62C\uBC14\uB974\uC9C0 \uC54A\uC544\uC694. \uD398\uC774\uC9C0\uB97C \uB2E4\uC2DC \uC0B4\uD3B4\uBD10 \uC8FC\uC138\uC694."
      };
    }
    if (parsed.generation !== generation) {
      return {
        ok: false,
        reason: "stale",
        message: "\uD398\uC774\uC9C0\uAC00 \uADF8 \uC0AC\uC774\uC5D0 \uBC14\uB00C\uC5C8\uC5B4\uC694. \uB2E4\uC2DC \uC0B4\uD3B4\uBCF8 \uB4A4\uC5D0 \uC9C4\uD589\uD574 \uC8FC\uC138\uC694."
      };
    }
    return {
      ok: true,
      frameIndex: parsed.frameIndex,
      elementIndex: parsed.elementIndex
    };
  }

  // DesktopRuntime/native/browser-agent.ts
  var captured = [];
  var capturedGeneration = -1;
  var focused = null;
  var focusGeneration = -1;
  var focusToken = 0;
  var targets = () => (0, eval)(`(() => { ${TARGET_INDEX_SOURCE}; return __bandalTargets() })()`);
  function facts(node) {
    const tag = node.tagName.toLowerCase(), type = (node.getAttribute("type") || "").toLowerCase(), form = node.form ?? node.closest("form");
    return {
      tag,
      type: type || null,
      inNonGetForm: form ? (form.getAttribute("method") || "get").toLowerCase() !== "get" : false,
      href: tag === "a" ? node.getAttribute("href") : null,
      disabled: Boolean(node.disabled),
      formAction: form ? node.hasAttribute("formaction") ? node.formAction : form.action : null,
      formMethod: form ? (node.getAttribute("formmethod") ?? form.method).toLowerCase() : null,
      formTarget: form ? node.getAttribute("formtarget") ?? form.target : null
    };
  }
  async function run(input) {
    const samePage = () => {
      if (location.href !== input.expectedUrl) throw new Error("\uD398\uC774\uC9C0\uAC00 \uBCC0\uACBD\uB418\uC5C8\uC2B5\uB2C8\uB2E4. \uB2E4\uC2DC \uC0B4\uD3B4\uBD10 \uC8FC\uC138\uC694.");
    };
    samePage();
    const max = Math.max(500, Math.min(2e4, input.maxChars ?? 6e3));
    let resolved;
    if (input.ref) {
      const value = resolveRef(input.ref, input.generation);
      if (!value.ok) throw new Error(value.message);
      if (value.frameIndex !== 0) throw new Error("iPad\uC5D0\uC11C\uB294 \uB2E4\uB978 \uCD9C\uCC98\uC758 \uB0B4\uC7A5 \uD504\uB808\uC784\uC744 \uC790\uB3D9\uC73C\uB85C \uC870\uC791\uD560 \uC218 \uC5C6\uC2B5\uB2C8\uB2E4. \uC6D0\uBB38\uC744 \uC9C1\uC811 \uC5F4\uC5B4 \uC8FC\uC138\uC694.");
      resolved = value;
    }
    const validateTarget = () => {
      if (!resolved) return;
      const node = targets()[resolved.elementIndex];
      if (capturedGeneration !== input.generation || !node || captured[resolved.elementIndex] !== node) throw new Error("\uC694\uC18C \uC21C\uC11C\uAC00 \uBCC0\uACBD\uB418\uC5C8\uC2B5\uB2C8\uB2E4. \uB2E4\uC2DC \uC0B4\uD3B4\uBD10 \uC8FC\uC138\uC694.");
      if (input.expectedFacts && Object.entries(facts(node)).some(([key, value]) => input.expectedFacts[key] !== value)) throw new Error("\uD655\uC778\uD55C \uC694\uC18C\uAC00 \uBCC0\uACBD\uB418\uC5C8\uC2B5\uB2C8\uB2E4. \uB2E4\uC2DC \uC0B4\uD3B4\uBD10 \uC8FC\uC138\uC694.");
      if (input.tool === "act" && input.action) {
        if (input.action.kind === "click" && (node instanceof HTMLButtonElement && node.form && node.type === "submit" || node instanceof HTMLInputElement && ["submit", "image", "file"].includes(node.type))) throw new Error("\uC81C\uCD9C \uB610\uB294 \uD30C\uC77C \uCCA8\uBD80\uB294 \uBCC4\uB3C4 \uD655\uC778 \uD6C4 \uC9C4\uD589\uD574 \uC8FC\uC138\uC694.");
        const verdict = verdictFor(input.action.kind, facts(node));
        if (!verdict.allowed) throw new Error(verdict.message);
      }
    };
    const driver = createPageDriver({ currentUrl: () => location.href, frames: () => [{ executeJavaScript: async (source) => {
      samePage();
      validateTarget();
      return (0, eval)(source);
    } }] });
    switch (input.tool) {
      case "snapshot": {
        captured = targets();
        capturedGeneration = input.generation;
        const result = await driver.snapshot(input.generation, max);
        const current = targets();
        if (captured.length !== current.length || captured.some((node, index) => current[index] !== node)) throw new Error("\uD398\uC774\uC9C0\uAC00 \uBCC0\uACBD\uB418\uC5C8\uC2B5\uB2C8\uB2E4. \uB2E4\uC2DC \uC0B4\uD3B4\uBD10 \uC8FC\uC138\uC694.");
        return { status: "ok", url: result.url, title: document.title, outline: result.outline, generation: input.generation };
      }
      case "read":
        return { status: "ok", ...await driver.read(max), title: document.title, generation: input.generation };
      case "inspect": {
        if (input.focused) {
          focused = document.activeElement;
          focusGeneration = input.generation;
          focusToken++;
          return { status: "ok", url: location.href, generation: input.generation, focusToken, facts: focused ? facts(focused) : null };
        }
        validateTarget();
        return { status: "ok", url: location.href, generation: input.generation, ...resolved ? { facts: facts(targets()[resolved.elementIndex]) } : {} };
      }
      case "submit": {
        if (!input.approved || !input.expectedFacts || !resolved) throw new Error("\uC774\uBC88 \uC81C\uCD9C\uC5D0 \uB300\uD55C \uD655\uC778\uC774 \uD544\uC694\uD569\uB2C8\uB2E4.");
        validateTarget();
        const node = targets()[resolved.elementIndex];
        if (!(node instanceof HTMLElement) || node.disabled || !(node instanceof HTMLButtonElement || node instanceof HTMLInputElement && ["submit", "image", "button"].includes(node.type) || node.getAttribute("role") === "button")) throw new Error("\uC81C\uCD9C\uD560 \uBC84\uD2BC\uC744 \uB2E4\uC2DC \uD655\uC778\uD574 \uC8FC\uC138\uC694.");
        node.click();
        return { status: "ok", url: location.href, title: document.title, semanticAction: "activate-approved-submit-control", navigated: location.href !== input.expectedUrl };
      }
      case "attachFile": {
        if (!input.approved || !input.expectedFacts || !resolved || !input.file) throw new Error("\uD30C\uC77C \uCCA8\uBD80 \uD655\uC778\uC774 \uD544\uC694\uD569\uB2C8\uB2E4.");
        validateTarget();
        const node = targets()[resolved.elementIndex], file = input.file;
        if (!(node instanceof HTMLInputElement) || node.type !== "file" || node.disabled) throw new Error("\uD30C\uC77C \uC785\uB825 \uD56D\uBAA9\uC744 \uB2E4\uC2DC \uD655\uC778\uD574 \uC8FC\uC138\uC694.");
        const raw = atob(file.dataBase64);
        if (raw.length > 25 * 1024 * 1024 || !file.name || file.name.includes("/") || file.name.includes("\\")) throw new Error("25MB \uC774\uD558 \uD30C\uC77C\uC744 \uC120\uD0DD\uD574 \uC8FC\uC138\uC694.");
        const bytes = Uint8Array.from(raw, (value) => value.charCodeAt(0)), transfer = new DataTransfer();
        transfer.items.add(new File([bytes], file.name, { type: file.mimeType }));
        node.files = transfer.files;
        if (node.files.length !== 1 || node.files[0].size !== bytes.length || node.files[0].name !== file.name) throw new Error("\uC774 \uD398\uC774\uC9C0\uC5D0 \uD30C\uC77C\uC744 \uCCA8\uBD80\uD558\uC9C0 \uBABB\uD588\uC2B5\uB2C8\uB2E4.");
        node.dispatchEvent(new Event("input", { bubbles: true }));
        node.dispatchEvent(new Event("change", { bubbles: true }));
        return { status: "ok", url: location.href, title: document.title, attached: true, semanticAction: "set-file-input", submitted: false };
      }
      case "key": {
        if (!input.expectedFacts || input.focusToken !== focusToken || input.generation !== focusGeneration || focused !== document.activeElement || !focused) throw new Error("\uC785\uB825 \uC704\uCE58\uAC00 \uBC14\uB00C\uC5C8\uC2B5\uB2C8\uB2E4. \uB2E4\uC2DC \uD655\uC778\uD574 \uC8FC\uC138\uC694.");
        if (input.expectedFacts && Object.entries(facts(focused)).some(([key, value]) => input.expectedFacts[key] !== value)) throw new Error("\uC785\uB825 \uD56D\uBAA9\uC774 \uBC14\uB00C\uC5C8\uC2B5\uB2C8\uB2E4. \uB2E4\uC2DC \uD655\uC778\uD574 \uC8FC\uC138\uC694.");
        const action = semanticKey(focused, input.key, input.approved === true);
        return { status: "ok", url: location.href, title: document.title, semanticAction: action, navigated: location.href !== input.expectedUrl };
      }
      case "act": {
        if (!resolved || !input.action || !["click", "type", "select"].includes(input.action.kind)) throw new Error("\uD589\uB3D9\uACFC \uC694\uC18C\uB97C \uD655\uC778\uD574 \uC8FC\uC138\uC694.");
        if ((input.action.text?.length ?? 0) > 2e4 || (input.action.value?.length ?? 0) > 2e4) throw new Error("\uC785\uB825 \uAE38\uC774\uAC00 \uB108\uBB34 \uAE41\uB2C8\uB2E4.");
        validateTarget();
        const result = await driver.act(0, resolved.elementIndex, input.action);
        if (!result.ok) throw new Error(result.problem ?? "\uD589\uB3D9\uC774 \uBC18\uC601\uB418\uC9C0 \uC54A\uC558\uC2B5\uB2C8\uB2E4.");
        return { status: "ok", url: location.href, title: document.title, navigated: location.href !== input.expectedUrl };
      }
      case "scroll": {
        const target = resolved ? { kind: "ref", frameIndex: 0, elementIndex: resolved.elementIndex } : input.to;
        if (!target || !["down", "up", "top", "bottom", "ref"].includes(target.kind)) throw new Error("\uC2A4\uD06C\uB864 \uC704\uCE58\uB97C \uD655\uC778\uD574 \uC8FC\uC138\uC694.");
        const result = await driver.scroll(target);
        if (!result.ok) throw new Error(result.problem ?? "\uD398\uC774\uC9C0\uB97C \uC774\uB3D9\uD558\uC9C0 \uBABB\uD588\uC2B5\uB2C8\uB2E4.");
        return { status: "ok", url: location.href, title: document.title };
      }
      case "hover": {
        if (!resolved) throw new Error("\uC694\uC18C \uCC38\uC870\uAC00 \uC5C6\uC2B5\uB2C8\uB2E4.");
        const result = await driver.hover(0, resolved.elementIndex);
        if (!result.ok) throw new Error(result.problem ?? "\uC694\uC18C\uB97C \uD655\uC778\uD558\uC9C0 \uBABB\uD588\uC2B5\uB2C8\uB2E4.");
        return { status: "ok", url: location.href, title: document.title };
      }
      default:
        throw new Error("iPad \uBE0C\uB77C\uC6B0\uC800\uC5D0\uC11C \uC9C0\uC6D0\uD558\uC9C0 \uC54A\uB294 \uB3D9\uC791\uC785\uB2C8\uB2E4.");
    }
  }
  function semanticKey(node, key, approved) {
    if (key === "Tab") {
      const candidates = Array.from(document.querySelectorAll("a[href],button,input,select,textarea,[tabindex]")).filter((item) => item.tabIndex >= 0 && !item.disabled && item.getBoundingClientRect().width > 0 && item.getBoundingClientRect().height > 0 && getComputedStyle(item).visibility !== "hidden");
      const next = candidates[(candidates.indexOf(node) + 1) % candidates.length];
      if (!next || next === node) throw new Error("\uB2E4\uC74C \uC785\uB825 \uD56D\uBAA9\uC774 \uC5C6\uC2B5\uB2C8\uB2E4.");
      next.focus();
      if (document.activeElement !== next) throw new Error("\uC785\uB825 \uD56D\uBAA9\uC73C\uB85C \uC774\uB3D9\uD558\uC9C0 \uBABB\uD588\uC2B5\uB2C8\uB2E4.");
      return "focus-next-element";
    }
    if (key === "Escape") {
      const dialog = node.closest("dialog[open]");
      if (dialog instanceof HTMLDialogElement) {
        dialog.close();
        return "close-dialog";
      }
      if (node instanceof HTMLElement && node !== document.body) {
        node.blur();
        if (document.activeElement !== node) return "blur-active-element";
      }
      throw new Error("\uB2EB\uAC70\uB098 \uC785\uB825\uC744 \uD574\uC81C\uD560 \uD56D\uBAA9\uC774 \uC5C6\uC2B5\uB2C8\uB2E4.");
    }
    if (key === "Enter") {
      if (!approved) throw new Error("Enter \uB3D9\uC791\uC744 \uC2E4\uD589\uD558\uB824\uBA74 \uC774\uBC88 \uD55C \uBC88\uC758 \uD655\uC778\uC774 \uD544\uC694\uD569\uB2C8\uB2E4.");
      if (node instanceof HTMLTextAreaElement && !node.disabled && !node.readOnly) {
        node.setRangeText("\n", node.selectionStart, node.selectionEnd, "end");
        node.dispatchEvent(new Event("input", { bubbles: true }));
        return "insert-newline";
      }
      if (node instanceof HTMLButtonElement || node instanceof HTMLAnchorElement || node instanceof HTMLInputElement && ["button", "submit", "image"].includes(node.type)) {
        if (node.disabled) throw new Error("\uC774 \uD56D\uBAA9\uC740 \uBE44\uD65C\uC131 \uC0C1\uD0DC\uC785\uB2C8\uB2E4.");
        node.click();
        return "activate-focused-control";
      }
      if (node instanceof HTMLInputElement && node.form && !node.disabled && node.type !== "file") {
        node.form.requestSubmit();
        return "submit-focused-form";
      }
      throw new Error("\uC774 \uC785\uB825 \uD56D\uBAA9\uC758 Enter \uB3D9\uC791\uC740 iPad\uC5D0\uC11C \uC9C1\uC811 \uC2E4\uD589\uD574 \uC8FC\uC138\uC694.");
    }
    if (!["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(key ?? "")) throw new Error("\uC9C0\uC6D0\uD558\uC9C0 \uC54A\uB294 \uD0A4\uC785\uB2C8\uB2E4.");
    if (node instanceof HTMLSelectElement && !node.disabled) {
      const direction = key === "ArrowUp" || key === "ArrowLeft" ? -1 : 1;
      let next = node.selectedIndex + direction;
      while (next >= 0 && next < node.options.length && node.options[next].disabled) next += direction;
      if (next < 0 || next >= node.options.length) throw new Error("\uB2E4\uC74C \uC120\uD0DD \uD56D\uBAA9\uC774 \uC5C6\uC2B5\uB2C8\uB2E4.");
      node.selectedIndex = next;
      node.dispatchEvent(new Event("input", { bubbles: true }));
      node.dispatchEvent(new Event("change", { bubbles: true }));
      return "select-adjacent-option";
    }
    if ((node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement) && ["ArrowLeft", "ArrowRight"].includes(key) && node.selectionStart !== null && node.selectionEnd !== null && node.type !== "password") {
      const before = key === "ArrowLeft" ? node.selectionStart : node.selectionEnd;
      const next = Math.max(0, Math.min(node.value.length, before + (key === "ArrowLeft" ? -1 : 1)));
      if (next === before && node.selectionStart === node.selectionEnd) throw new Error("\uCEE4\uC11C\uAC00 \uC785\uB825\uC758 \uB05D\uC5D0 \uC788\uC2B5\uB2C8\uB2E4.");
      node.setSelectionRange(next, next);
      return "move-text-caret";
    }
    if (node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement || node instanceof HTMLElement && node.isContentEditable) throw new Error("\uC774 \uC785\uB825 \uD56D\uBAA9\uC758 \uBC29\uD5A5\uD0A4\uB294 \uC9C1\uC811 \uC0AC\uC6A9\uD574 \uC8FC\uC138\uC694.");
    const scroller = document.scrollingElement;
    if (!scroller) throw new Error("\uC2A4\uD06C\uB864\uD560 \uD398\uC774\uC9C0\uAC00 \uC5C6\uC2B5\uB2C8\uB2E4.");
    const top = scroller.scrollTop, left = scroller.scrollLeft;
    if (key === "ArrowUp") scroller.scrollTop -= 40;
    if (key === "ArrowDown") scroller.scrollTop += 40;
    if (key === "ArrowLeft") scroller.scrollLeft -= 40;
    if (key === "ArrowRight") scroller.scrollLeft += 40;
    if (top === scroller.scrollTop && left === scroller.scrollLeft) throw new Error("\uC2A4\uD06C\uB864\uD560 \uC5EC\uBC31\uC774 \uC5C6\uC2B5\uB2C8\uB2E4.");
    return "scroll-document";
  }
  globalThis.__bandalBrowserAgent = run;
})();
