import { readFile } from "node:fs/promises";
import path from "node:path";

class ClassList {
  constructor(element) {
    this.element = element;
    this.items = new Set();
  }

  add(name) {
    this.items.add(String(name));
  }

  remove(name) {
    this.items.delete(String(name));
  }

  toggle(name, force) {
    const key = String(name);
    const enabled = force === undefined ? !this.items.has(key) : Boolean(force);
    if (enabled) {
      this.items.add(key);
    } else {
      this.items.delete(key);
    }
    return enabled;
  }

  contains(name) {
    return this.items.has(String(name));
  }
}

class Element {
  constructor(tagName) {
    this.tagName = tagName.toLowerCase();
    this.children = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.listeners = new Map();
    this.classList = new ClassList(this);
    this.value = "";
    this.textContent = "";
  }

  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.children.push(child);
    return child;
  }

  removeChild(child) {
    const idx = this.children.indexOf(child);
    if (idx >= 0) {
      this.children.splice(idx, 1);
      child.parentNode = null;
    }
    return child;
  }

  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }

  setAttribute(key, value) {
    const attr = String(key);
    const text = String(value);
    this.attributes.set(attr, text);
    if (attr === "value") this.value = text;
    if (attr === "class") {
      this.classList.items = new Set(text.split(/\s+/).filter(Boolean));
    }
  }

  getAttribute(key) {
    const attr = String(key);
    return this.attributes.has(attr) ? this.attributes.get(attr) : null;
  }

  removeAttribute(key) {
    const attr = String(key);
    this.attributes.delete(attr);
    if (attr === "value") this.value = "";
    if (attr === "class") this.classList.items.clear();
  }

  addEventListener(type, listener) {
    const key = String(type);
    const list = this.listeners.get(key) ?? [];
    list.push(listener);
    this.listeners.set(key, list);
  }

  removeEventListener(type, listener) {
    const key = String(type);
    const list = this.listeners.get(key) ?? [];
    this.listeners.set(key, list.filter((item) => item !== listener));
  }

  dispatchEvent(event) {
    const type = typeof event === "string" ? event : event.type;
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event);
    }
    return true;
  }
}

class DocumentStub {
  constructor() {
    this.readyState = "loading";
    this.app = new Element("div");
    this.app.setAttribute("id", "app");
  }

  createElement(tagName) {
    return new Element(tagName);
  }

  querySelector(selector) {
    if (selector === "#app") return this.app;
    return findFirst(this.app, (node) => matchesSelector(node, selector));
  }

  querySelectorAll(selector) {
    return findAll(this.app, (node) => matchesSelector(node, selector));
  }
}

class WindowStub {
  constructor(document) {
    this.document = document;
    this.listeners = new Map();
  }

  addEventListener(type, listener) {
    const key = String(type);
    const list = this.listeners.get(key) ?? [];
    list.push(listener);
    this.listeners.set(key, list);
  }

  dispatchEvent(event) {
    const type = typeof event === "string" ? event : event.type;
    for (const listener of this.listeners.get(type) ?? []) {
      listener(event);
    }
  }
}

function matchesSelector(node, selector) {
  if (selector.startsWith("#")) return node.getAttribute("id") === selector.slice(1);
  if (selector.startsWith(".")) return node.classList.contains(selector.slice(1));
  return node.tagName === selector.toLowerCase();
}

function findAll(root, predicate) {
  const out = [];
  const visit = (node) => {
    if (predicate(node)) out.push(node);
    for (const child of node.children) visit(child);
  };
  visit(root);
  return out;
}

function findFirst(root, predicate) {
  return findAll(root, predicate)[0] ?? null;
}

function textOf(node) {
  return `${node.textContent}${node.children.map(textOf).join("")}`;
}

function textSnapshot(root) {
  return textOf(root).replace(/\s+/g, " ").trim();
}

function findButton(root, label) {
  const button = findAll(root, (node) => node.tagName === "button").find((node) => textOf(node) === label);
  if (!button) throw new Error(`missing button '${label}' in DOM: ${textSnapshot(root)}`);
  return button;
}

function findInput(root, index = 0) {
  const matches = findAll(root, (node) => node.tagName === "input");
  const node = matches[index];
  if (!node) throw new Error(`missing <input>[${index}] in DOM: ${textSnapshot(root)}`);
  return node;
}

function findTextByTag(root, tagName, index = 0) {
  const matches = findAll(root, (node) => node.tagName === tagName.toLowerCase());
  const node = matches[index];
  if (!node) throw new Error(`missing <${tagName}>[${index}] in DOM: ${textSnapshot(root)}`);
  return textOf(node);
}

function expectText(root, expected) {
  const text = textSnapshot(root);
  if (!text.includes(expected)) {
    throw new Error(`expected DOM text '${expected}', got '${text}'`);
  }
}

function expectTagText(root, tagName, index, expected) {
  const actual = findTextByTag(root, tagName, index);
  if (actual !== expected) {
    throw new Error(`expected <${tagName}>[${index}] text '${expected}', got '${actual}'`);
  }
}

async function waitFor(predicate, description) {
  for (let i = 0; i < 100; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timeout waiting for ${description}`);
}

async function boot(outDir) {
  const bootErrors = [];
  const originalConsoleError = console.error;
  console.error = (...args) => {
    bootErrors.push(args.map((arg) => (arg instanceof Error ? arg.stack : String(arg))).join(" "));
    originalConsoleError(...args);
  };

  const document = new DocumentStub();
  const window = new WindowStub(document);
  globalThis.document = document;
  globalThis.window = window;
  globalThis.location = { pathname: "/", search: "", hash: "" };
  globalThis.history = {
    pushState(_state, _title, url) {
      globalThis.location.pathname = String(url);
    },
    replaceState(_state, _title, url) {
      globalThis.location.pathname = String(url);
    },
  };
  globalThis.XMLHttpRequest = class {
    open() {}
    send() {
      this.status = 501;
      this.responseText = "";
    }
  };
  globalThis.fetch = async (url) => {
    const fileName = String(url).replace(/^\.\//, "");
    const bytes = await readFile(path.join(outDir, fileName));
    return new Response(bytes, { headers: { "Content-Type": "application/wasm" } });
  };

  const airlockSource = await readFile(path.join(outDir, "airlock.js"), "utf8");
  const moduleUrl = `data:text/javascript;base64,${Buffer.from(airlockSource).toString("base64")}#runtime=${Date.now()}`;
  const airlockModule = await import(moduleUrl);
  document.readyState = "complete";
  window.dispatchEvent({ type: "DOMContentLoaded" });
  try {
    await waitFor(() => document.app.children.length > 0 || bootErrors.length !== 0, "SAX app mount");
    if (bootErrors.length !== 0) {
      throw new Error(`SAX boot failed: ${bootErrors.join("\n")}`);
    }
    return { root: document.app, document, airlockModule };
  } finally {
    console.error = originalConsoleError;
  }
}

async function verifyDashboard(outDir) {
  const { root } = await boot(outDir);
  expectText(root, "SAX Ops Dashboard");
  expectText(root, "12");
  expectText(root, "2");
  expectText(root, "180 ms");

  findButton(root, "Record visit").dispatchEvent({ type: "click" });
  expectText(root, "13");

  findButton(root, "Ack alert").dispatchEvent({ type: "click" });
  expectText(root, "1");

  findButton(root, "Improve").dispatchEvent({ type: "click" });
  expectText(root, "170 ms");
}

async function verifyTyped(outDir) {
  const { root } = await boot(outDir);
  expectText(root, "Score: 7");
  expectText(root, "Active: 0");
  expectText(root, "Ratio: 0.750000");

  findButton(root, "Bump").dispatchEvent({ type: "click" });
  expectText(root, "Score: 8");
  expectText(root, "Active: 1");
  expectText(root, "Ratio: 0.750000");
}

async function verifyCounter(outDir) {
  const { root } = await boot(outDir);
  expectTagText(root, "h1", 0, "0");
  expectText(root, "Last updated: 0 ms ago");

  findButton(root, "+1").dispatchEvent({ type: "click" });
  expectTagText(root, "h1", 0, "1");

  findButton(root, "-1").dispatchEvent({ type: "click" });
  expectTagText(root, "h1", 0, "0");

  findButton(root, "-1").dispatchEvent({ type: "click" });
  expectTagText(root, "h1", 0, "-1");

  findButton(root, "Reset").dispatchEvent({ type: "click" });
  expectTagText(root, "h1", 0, "0");
}

async function verifyTodo(outDir) {
  const { root } = await boot(outDir);
  expectText(root, "TodoList");
  expectText(root, "Items: 0");

  const input = findInput(root);
  input.value = "write sax demo";
  findButton(root, "Add").dispatchEvent({ type: "click" });
  expectText(root, "Items: 1");
  expectTagText(root, "li", 0, "write sax demo");
  if (input.value !== "") throw new Error(`expected input to clear after add, got '${input.value}'`);

  input.value = "ship wasm";
  findButton(root, "Add").dispatchEvent({ type: "click" });
  expectText(root, "Items: 2");
  expectTagText(root, "li", 1, "ship wasm");

  findButton(root, "Delete last").dispatchEvent({ type: "click" });
  expectText(root, "Items: 1");
  expectTagText(root, "li", 0, "write sax demo");
  expectTagText(root, "li", 1, "");
}

async function verifySecurity(outDir) {
  const { document, airlockModule } = await boot(outDir);
  const { sax_airlock, sax_debug_get_memory } = airlockModule;
  const mem = sax_debug_get_memory();
  if (!mem) throw new Error("missing airlock memory after boot");

  const writeBytes = (text) => {
    const bytes = new TextEncoder().encode(text);
    const ptr = sax_airlock.malloc(bytes.length || 1);
    new Uint8Array(mem.buffer, Number(ptr), bytes.length).set(bytes);
    return { ptr, len: bytes.length };
  };

  const expectThrow = async (name, fn, expected) => {
    try {
      await fn();
      throw new Error(`${name} should have thrown`);
    } catch (err) {
      const text = err instanceof Error ? err.message : String(err);
      if (!text.includes(expected)) {
        throw new Error(`${name} expected '${expected}', got '${text}'`);
      }
    }
  };

  const badTag = writeBytes("script");
  await expectThrow("script tag", () => sax_airlock.sax_dom_create(badTag.ptr, badTag.len), "SaxUnknownTag");

  const divTag = writeBytes("div");
  const divHandle = sax_airlock.sax_dom_create(divTag.ptr, divTag.len);
  const badAttr = writeBytes("innerHTML");
  const badValue = writeBytes("<img src=x onerror=alert(1)>");
  await expectThrow(
    "innerHTML attr",
    () => sax_airlock.sax_dom_set_attr(divHandle, badAttr.ptr, badAttr.len, badValue.ptr, badValue.len),
    "SaxInvalidAttribute",
  );

  const buttonTag = writeBytes("button");
  const buttonHandle = sax_airlock.sax_dom_create(buttonTag.ptr, buttonTag.len);
  const evalAttr = writeBytes("onclick");
  const evalValue = writeBytes("eval(alert(1))");
  await expectThrow(
    "inline onclick attr",
    () => sax_airlock.sax_dom_set_attr(buttonHandle, evalAttr.ptr, evalAttr.len, evalValue.ptr, evalValue.len),
    "SaxInvalidAttribute",
  );

  if (document.app.children.length === 0) {
    throw new Error("security boot should preserve mounted SAX app");
  }
}

const [, , outDir, scenario] = process.argv;
if (!outDir || !scenario) {
  console.error("usage: node tools/verify_sax_runtime.mjs <sax-output-dir> <counter|dashboard|security|todo|typed>");
  process.exit(2);
}

try {
  if (scenario === "counter") {
    await verifyCounter(outDir);
  } else if (scenario === "dashboard") {
    await verifyDashboard(outDir);
  } else if (scenario === "security") {
    await verifySecurity(outDir);
  } else if (scenario === "todo") {
    await verifyTodo(outDir);
  } else if (scenario === "typed") {
    await verifyTyped(outDir);
  } else {
    throw new Error(`unknown SAX runtime scenario '${scenario}'`);
  }
  console.log(`[PASS] sax runtime ${scenario}`);
} catch (err) {
  console.error(err instanceof Error ? err.stack : err);
  process.exit(1);
}
