// Wellout client runtime (SPEC §9.4): fragment swaps for links and forms,
// island loading and confirmation prompts. Pages without swaps or islands
// do not load it.

const FRAGMENT_HEADER = "Well-Fragment";
const loaded = new WeakSet();

function islandProps(element) {
  const script = element.querySelector(":scope > script[data-well-props]");
  if (!script) return { props: null, messages: {} };
  try {
    return JSON.parse(script.textContent || "{}");
  } catch {
    return { props: null, messages: {} };
  }
}

async function mountIsland(element) {
  if (loaded.has(element)) return;
  loaded.add(element);
  const url = element.dataset.module;
  if (!url) return;
  const { props, messages } = islandProps(element);
  try {
    const module = await import(/* @vite-ignore */ url);
    if (typeof module.mount !== "function") throw new Error(`${url} does not export mount`);
    await module.mount(element, props, messages || {});
    element.dataset.mounted = "";
  } catch (error) {
    console.error(`Island ${element.dataset.name} could not be mounted`, error);
  }
}

function scheduleIsland(element) {
  const load = element.dataset.load || "eager";
  if (load === "eager") {
    mountIsland(element);
  } else if (load === "idle") {
    const idle = window.requestIdleCallback || ((callback) => setTimeout(callback, 200));
    idle(() => mountIsland(element));
  } else if (load === "visible" && "IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) {
        observer.disconnect();
        mountIsland(element);
      }
    });
    observer.observe(element);
  } else {
    const start = () => {
      for (const type of ["pointerdown", "focusin", "keydown"]) {
        element.removeEventListener(type, start);
      }
      mountIsland(element);
    };
    for (const type of ["pointerdown", "focusin", "keydown"]) {
      element.addEventListener(type, start, { once: true });
    }
  }
}

export function mountIslands(root = document) {
  for (const element of root.querySelectorAll("well-island")) scheduleIsland(element);
}

function fragmentElement(name) {
  return document.querySelector(`[data-well-fragment="${CSS.escape(name)}"]`);
}

function replaceFragment(target, html) {
  const template = document.createElement("template");
  template.innerHTML = html.trim();
  const replacement = template.content.firstElementChild;
  if (!replacement) return null;
  const active = document.activeElement;
  const focusKey = active && (active.id || active.getAttribute("name"));
  target.replaceWith(replacement);
  mountIslands(replacement);
  const autofocus = replacement.querySelector("[autofocus]");
  if (autofocus) {
    autofocus.focus();
  } else if (focusKey) {
    const again =
      replacement.querySelector(`#${CSS.escape(focusKey)}`) ||
      replacement.querySelector(`[name="${CSS.escape(focusKey)}"]`);
    if (again) again.focus();
  }
  replacement.dispatchEvent(new CustomEvent("well:swapped", { bubbles: true }));
  return replacement;
}

/** Fetches `url` and replaces the fragment `name`, or navigates when no fragment comes back. */
export async function swap(name, url, init = {}, push = false) {
  const target = fragmentElement(name);
  if (!target) {
    window.location.assign(url);
    return;
  }
  target.setAttribute("aria-busy", "true");
  let response;
  try {
    response = await fetch(url, {
      ...init,
      credentials: "same-origin",
      headers: { ...(init.headers || {}), [FRAGMENT_HEADER]: name, Accept: "text/html" },
    });
  } catch {
    target.removeAttribute("aria-busy");
    window.location.assign(url);
    return;
  }
  if (response.headers.get(FRAGMENT_HEADER) !== name) {
    window.location.assign(response.url || url);
    return;
  }
  const html = await response.text();
  const replacement = replaceFragment(target, html);
  if (!replacement) {
    target.removeAttribute("aria-busy");
    return;
  }
  if (push && response.url) {
    history.pushState({ wellout: true }, "", response.url);
  }
}

function confirmationFor(element) {
  return element?.closest("[data-well-confirm]")?.getAttribute("data-well-confirm") || "";
}

/**
 * Asks with the page's <dialog id="well-confirm">, so the prompt keeps the
 * site's design, or with window.confirm when the page has none.
 */
function ask(message) {
  const dialog = document.getElementById("well-confirm");
  if (!(dialog instanceof HTMLDialogElement)) return Promise.resolve(window.confirm(message));
  const text = dialog.querySelector("[data-well-confirm-message]");
  if (text) text.textContent = message;
  dialog.returnValue = "";
  dialog.showModal();
  return new Promise((resolve) => {
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "confirm"), {
      once: true,
    });
  });
}

document.addEventListener("click", async (event) => {
  if (event.defaultPrevented || event.button !== 0) return;
  const answer = event.target.closest("[data-well-answer]");
  if (answer) {
    answer.closest("dialog")?.close(answer.getAttribute("data-well-answer"));
    return;
  }
  const opener = event.target.closest("[data-well-open]");
  if (opener) {
    const dialog = document.getElementById(opener.getAttribute("data-well-open"));
    if (dialog instanceof HTMLDialogElement) {
      dialog.showModal();
      opener.setAttribute("aria-expanded", "true");
      dialog.addEventListener("close", () => opener.setAttribute("aria-expanded", "false"), {
        once: true,
      });
    }
    return;
  }
  if (event.target.closest("[data-well-close]")) {
    event.target.closest("dialog")?.close();
    return;
  }
  if (event.target instanceof HTMLDialogElement && event.target.hasAttribute("data-well-dismiss")) {
    event.target.close();
    return;
  }
  const toggle = event.target.closest("[data-well-toggle]");
  if (toggle) {
    const target = document.getElementById(toggle.getAttribute("data-well-toggle"));
    if (target) {
      const opening = target.hidden;
      target.hidden = !opening;
      toggle.setAttribute("aria-expanded", String(opening));
      const label = toggle.getAttribute(opening ? "data-well-hide-label" : "data-well-show-label");
      if (label) toggle.setAttribute("aria-label", label);
    }
    return;
  }
  const reveal = event.target.closest("[data-well-reveal]");
  if (reveal) {
    const input = document.getElementById(reveal.getAttribute("data-well-reveal"));
    if (input instanceof HTMLInputElement) {
      const visible = input.type === "password";
      input.type = visible ? "text" : "password";
      reveal.setAttribute("aria-pressed", String(visible));
      const label = reveal.getAttribute(visible ? "data-well-hide-label" : "data-well-show-label");
      if (label) reveal.setAttribute("aria-label", label);
      for (const state of reveal.querySelectorAll("[data-well-pressed]")) {
        state.hidden = state.getAttribute("data-well-pressed") !== String(visible);
      }
    }
    return;
  }
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const control = event.target.closest("a[data-well-confirm], button[data-well-confirm]");
  // A submit button is confirmed when its form submits, including one linked with form="…".
  const submits = control instanceof HTMLButtonElement && control.form && control.type === "submit";
  if (control && !submits && control.dataset.wellConfirmed !== "1") {
    event.preventDefault();
    if (await ask(confirmationFor(control))) {
      control.dataset.wellConfirmed = "1";
      control.click();
      delete control.dataset.wellConfirmed;
    }
    return;
  }
  const link = event.target.closest("a[data-well-swap]");
  if (!link || link.target || link.hasAttribute("download")) return;
  const url = new URL(link.href, window.location.href);
  if (url.origin !== window.location.origin) return;
  event.preventDefault();
  swap(link.dataset.wellSwap, url.href, {}, true);
});

function busy(form, submitter) {
  const button = submitter || form.querySelector("[data-well-busy]");
  const label = button?.getAttribute("data-well-busy");
  if (!button || !label) return;
  button.setAttribute("data-well-label", button.textContent || "");
  for (const node of button.childNodes) {
    if (node.nodeType === Node.TEXT_NODE && node.textContent.trim()) node.textContent = ` ${label}`;
  }
  // Disable after the form data is built, so the submitter's name and value are still sent.
  setTimeout(() => {
    button.disabled = true;
  }, 0);
}

document.addEventListener("submit", async (event) => {
  if (event.defaultPrevented) return;
  const form = event.target;
  const submitter = event.submitter;
  const message = confirmationFor(submitter) || confirmationFor(form);
  if (message && form.dataset.wellConfirmed !== "1") {
    event.preventDefault();
    if (await ask(message)) {
      form.dataset.wellConfirmed = "1";
      form.requestSubmit(submitter || undefined);
      delete form.dataset.wellConfirmed;
    }
    return;
  }
  const name = (submitter && submitter.dataset.wellSwap) || form.dataset.wellSwap;
  if (!name) {
    busy(form, submitter);
    return;
  }
  event.preventDefault();
  const data = new FormData(form, submitter || undefined);
  const action = new URL(
    (submitter && submitter.getAttribute("formaction")) || form.action || window.location.href,
    window.location.href,
  );
  const method = (
    (submitter && submitter.getAttribute("formmethod")) ||
    form.method ||
    "get"
  ).toLowerCase();
  if (method === "get") {
    action.search = new URLSearchParams(data).toString();
    swap(name, action.href, {}, true);
  } else {
    // Send what the browser would: URL-encoded fields unless the form asks for multipart.
    const multipart = form.enctype === "multipart/form-data";
    const body = multipart ? data : new URLSearchParams(data);
    swap(name, action.href, { method: "POST", body }, false);
  }
});

document.addEventListener("keydown", (event) => {
  if (!(event.metaKey || event.ctrlKey) || event.altKey || event.key.length !== 1) return;
  const control = document.querySelector(
    `[data-well-hotkey="${CSS.escape(event.key.toLowerCase())}"]`,
  );
  if (!control) return;
  event.preventDefault();
  control.click();
});

document.addEventListener("change", (event) => {
  const field = event.target.closest("[data-well-autosubmit]");
  if (!field || !field.form) return;
  // The attribute may name the submit button to use, for its name, value or formaction.
  const submitter = document.getElementById(field.getAttribute("data-well-autosubmit") || "");
  const usable = submitter && submitter.form === field.form && submitter.type === "submit";
  field.form.requestSubmit(usable ? submitter : undefined);
});

window.addEventListener("popstate", (event) => {
  if (event.state && event.state.wellout) window.location.reload();
});

window.Wellout = { swap, mountIslands };
mountIslands();
