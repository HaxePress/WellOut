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

function confirmed(element) {
  const message = element.closest("[data-well-confirm]")?.getAttribute("data-well-confirm");
  return !message || window.confirm(message);
}

document.addEventListener("click", (event) => {
  if (event.defaultPrevented || event.button !== 0) return;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const control = event.target.closest("button[data-well-confirm], a[data-well-confirm]");
  if (control && !control.closest("form") && !confirmed(control)) {
    event.preventDefault();
    return;
  }
  const link = event.target.closest("a[data-well-swap]");
  if (!link || link.target || link.hasAttribute("download")) return;
  const url = new URL(link.href, window.location.href);
  if (url.origin !== window.location.origin) return;
  if (!confirmed(link)) {
    event.preventDefault();
    return;
  }
  event.preventDefault();
  swap(link.dataset.wellSwap, url.href, {}, true);
});

document.addEventListener("submit", (event) => {
  if (event.defaultPrevented) return;
  const form = event.target;
  const submitter = event.submitter;
  if (!confirmed(submitter || form)) {
    event.preventDefault();
    return;
  }
  const name = (submitter && submitter.dataset.wellSwap) || form.dataset.wellSwap;
  if (!name) return;
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
    swap(name, action.href, { method: "POST", body: data }, false);
  }
});

document.addEventListener("change", (event) => {
  const field = event.target.closest("[data-well-autosubmit]");
  if (field && field.form) field.form.requestSubmit();
});

window.addEventListener("popstate", (event) => {
  if (event.state && event.state.wellout) window.location.reload();
});

window.Wellout = { swap, mountIslands };
mountIslands();
