// Airlock JS 生成器：自动生成 WASM ↔ DOM 胶水层

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const AirlockOptions = struct {
    wgpu: bool = false,
    sa3d: bool = false,
};

pub const AirlockGenerator = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) AirlockGenerator {
        return .{ .allocator = allocator };
    }

    /// 生成 airlock.js 胶水层代码
    pub fn generateAirlockJS(self: *AirlockGenerator) !std.ArrayList(u8) {
        return self.generateAirlockJSWithOptions(.{});
    }

    /// 生成 airlock.js 胶水层代码，可按需要求加载浏览器 sidecar。
    pub fn generateAirlockJSWithOptions(self: *AirlockGenerator, options: AirlockOptions) !std.ArrayList(u8) {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        try output.writer().print("const SAX_WGPU_REQUIRED = {};\n", .{options.wgpu});
        try output.writer().print("const SAX_SA3D_REQUIRED = {};\n", .{options.sa3d});

        const airlock_template =
            \\// airlock.js — SAX 自动生成，请勿手动修改
            \\// WASM ↔ DOM 胶水层（Airlock 气闸舱）
            \\
            \\const SAX_AIRLOCK_VERSION = "1.0";
            \\
            \\// ── 节点句柄映射表
            \\const _nodeMap = new Map();
            \\const _bindingMap = new Map();
            \\const SAX_ALLOWED_TAGS = new Set([
            \\  "div", "section", "article", "header", "footer", "main", "nav", "aside",
            \\  "h1", "h2", "h3", "h4", "h5", "h6", "p", "span", "label", "strong", "em",
            \\  "button", "input", "textarea", "select", "option", "form",
            \\  "ul", "ol", "li",
            \\  "img", "video", "canvas",
            \\  "table", "thead", "tbody", "tr", "th", "td",
            \\]);
            \\const SAX_ALLOWED_ATTRS = new Set(["class", "style", "value", "placeholder", "disabled", "id", "width", "height", "renderer"]);
            \\let _nextHandle = 1;
            \\let _malloc_next = 0;
            \\let _router_path = "";
            \\let _router_listener_installed = false;
            \\function _alloc_handle(el) {
            \\  const h = _nextHandle++;
            \\  _nodeMap.set(h, el);
            \\  return h;
            \\}
            \\function _get_node(h) {
            \\  return _nodeMap.get(Number(h));
            \\}
            \\function _free_handle(h) {
            \\  _nodeMap.delete(Number(h));
            \\}
            \\function _align_up(value, align) {
            \\  return Math.ceil(value / align) * align;
            \\}
            \\function _heap_base() {
            \\  const base = _wasm_instance && _wasm_instance.exports ? _wasm_instance.exports.__heap_base : null;
            \\  if (base && typeof base.value === "number") return base.value;
            \\  return 1024;
            \\}
            \\function _ensure_mem(bytes) {
            \\  while (_mem.buffer.byteLength < bytes) {
            \\    _mem.grow(1);
            \\  }
            \\}
            \\function _malloc(size) {
            \\  const n = Math.max(1, Number(size));
            \\  if (_malloc_next === 0) _malloc_next = _align_up(_heap_base(), 8);
            \\  const ptr = _malloc_next;
            \\  _malloc_next = _align_up(ptr + n, 8);
            \\  _ensure_mem(_malloc_next);
            \\  return ptr;
            \\}
            \\function _write_u32(ptr, value) {
            \\  new DataView(_mem.buffer).setUint32(Number(ptr), Number(value), true);
            \\}
            \\function _write_u64(ptr, value) {
            \\  new DataView(_mem.buffer).setBigUint64(Number(ptr), BigInt(value), true);
            \\}
            \\function _router_sync_path() {
            \\  if (typeof location === "undefined") return;
            \\  _router_path = `${location.pathname}${location.search}${location.hash}`;
            \\}
            \\function _router_install_listeners() {
            \\  if (_router_listener_installed || typeof window === "undefined") return;
            \\  const sync = () => _router_sync_path();
            \\  window.addEventListener("popstate", sync);
            \\  window.addEventListener("hashchange", sync);
            \\  _router_listener_installed = true;
            \\}
            \\function _http_result(status, body_text) {
            \\  const body_bytes = new TextEncoder().encode(body_text);
            \\  const body_ptr = body_bytes.length === 0 ? 0 : _malloc(body_bytes.length);
            \\  if (body_bytes.length !== 0) {
            \\    new Uint8Array(_mem.buffer, Number(body_ptr), body_bytes.length).set(body_bytes);
            \\  }
            \\  const result_ptr = _malloc(24);
            \\  _write_u32(result_ptr, status >>> 0);
            \\  _write_u64(result_ptr + 8, body_ptr);
            \\  _write_u64(result_ptr + 16, body_bytes.length);
            \\  return BigInt(result_ptr);
            \\}
            \\function _http_request(method, url, body) {
            \\  const xhr = new XMLHttpRequest();
            \\  xhr.open(method, url, false);
            \\  xhr.send(body);
            \\  return _http_result(xhr.status || 0, xhr.responseText || "");
            \\}
            \\function _unbind_handle_events(node_h) {
            \\  const prefix = String(Number(node_h)) + "::";
            \\  for (const [key, binding] of _bindingMap.entries()) {
            \\    if (key.startsWith(prefix)) {
            \\      binding.node.removeEventListener(binding.evt, binding.listener);
            \\      _bindingMap.delete(key);
            \\    }
            \\  }
            \\}
            \\
            \\// ── WASM 内存读写工具
            \\let _mem;
            \\function _read_str(ptr, len) {
            \\  return new TextDecoder().decode(
            \\    new Uint8Array(_mem.buffer, Number(ptr), Number(len))
            \\  );
            \\}
            \\function _write_str(ptr, len, str) {
            \\  const bytes = new TextEncoder().encode(str);
            \\  const n = Math.min(bytes.length, Number(len));
            \\  new Uint8Array(_mem.buffer, Number(ptr), n).set(bytes.subarray(0, n));
            \\  return BigInt(n);
            \\}
            \\
            \\// ── Airlock 白名单 API
            \\export const sax_airlock = {
            \\  malloc(size) {
            \\    return _malloc(size);
            \\  },
            \\
            \\  free(_ptr) {
            \\  },
            \\
            \\  write(_fd, _ptr, len) {
            \\    return Number(len ?? 0);
            \\  },
            \\
            \\  exit(code) {
            \\    throw new Error(`SAX wasm called exit(${Number(code)})`);
            \\  },
            \\
            \\  // DOM 查询
            \\  sax_dom_query(sel_ptr, sel_len) {
            \\    const sel = _read_str(sel_ptr, sel_len);
            \\    const el = document.querySelector(sel);
            \\    return el ? BigInt(_alloc_handle(el)) : -1n;
            \\  },
            \\
            \\  sax_dom_query_all(sel_ptr, sel_len, out_ptr, max_count) {
            \\    const sel = _read_str(sel_ptr, sel_len);
            \\    const els = document.querySelectorAll(sel);
            \\    const count = Math.min(els.length, Number(max_count));
            \\    for (let i = 0; i < count; i++) {
            \\      const h = BigInt(_alloc_handle(els[i]));
            \\      new BigInt64Array(_mem.buffer, Number(out_ptr) + i * 8, 1).set([h]);
            \\    }
            \\    return BigInt(count);
            \\  },
            \\
            \\  // 节点操作
            \\  sax_dom_create(tag_ptr, tag_len) {
            \\    const tag = _read_str(tag_ptr, tag_len);
            \\    if (!SAX_ALLOWED_TAGS.has(tag)) {
            \\      throw new Error(`SaxUnknownTag: tag '${tag}' is not allowed in SAX`);
            \\    }
            \\    const el = document.createElement(tag);
            \\    return BigInt(_alloc_handle(el));
            \\  },
            \\
            \\  sax_dom_append_child(parent_h, child_h) {
            \\    _get_node(parent_h).appendChild(_get_node(child_h));
            \\  },
            \\
            \\  sax_dom_remove_child(parent_h, child_h) {
            \\    _get_node(parent_h).removeChild(_get_node(child_h));
            \\  },
            \\
            \\  sax_dom_remove_self(node_h) {
            \\    _get_node(node_h).remove();
            \\    _unbind_handle_events(node_h);
            \\    _free_handle(node_h);
            \\  },
            \\
            \\  sax_dom_insert_before(parent_h, new_h, ref_h) {
            \\    _get_node(parent_h).insertBefore(_get_node(new_h), _get_node(ref_h));
            \\  },
            \\
            \\  // 内容操作
            \\  sax_dom_set_text(node_h, text_ptr, text_len) {
            \\    _get_node(node_h).textContent = _read_str(text_ptr, text_len);
            \\  },
            \\
            \\  sax_dom_get_text(node_h, buf_ptr, buf_len) {
            \\    return _write_str(buf_ptr, buf_len, _get_node(node_h).textContent ?? "");
            \\  },
            \\
            \\  // 属性操作
            \\  sax_dom_set_attr(node_h, key_ptr, key_len, val_ptr, val_len) {
            \\    const key = _read_str(key_ptr, key_len);
            \\    const val = _read_str(val_ptr, val_len);
            \\    if (!SAX_ALLOWED_ATTRS.has(key)) {
            \\      throw new Error(`SaxInvalidAttribute: attribute '${key}' is not allowed in SAX`);
            \\    }
            \\    _get_node(node_h).setAttribute(key, val);
            \\  },
            \\
            \\  sax_dom_remove_attr(node_h, key_ptr, key_len) {
            \\    const key = _read_str(key_ptr, key_len);
            \\    _get_node(node_h).removeAttribute(key);
            \\  },
            \\
            \\  sax_dom_get_attr(node_h, key_ptr, key_len, buf_ptr, buf_len) {
            \\    const key = _read_str(key_ptr, key_len);
            \\    const val = _get_node(node_h).getAttribute(key) ?? "";
            \\    return _write_str(buf_ptr, buf_len, val);
            \\  },
            \\
            \\  // CSS class 操作
            \\  sax_dom_add_class(node_h, cls_ptr, cls_len) {
            \\    const cls = _read_str(cls_ptr, cls_len);
            \\    _get_node(node_h).classList.add(cls);
            \\  },
            \\
            \\  sax_dom_remove_class(node_h, cls_ptr, cls_len) {
            \\    const cls = _read_str(cls_ptr, cls_len);
            \\    _get_node(node_h).classList.remove(cls);
            \\  },
            \\
            \\  sax_dom_toggle_class(node_h, cls_ptr, cls_len, force) {
            \\    const cls = _read_str(cls_ptr, cls_len);
            \\    return BigInt(_get_node(node_h).classList.toggle(cls, !!force) ? 1 : 0);
            \\  },
            \\
            \\  // 表单值
            \\  sax_dom_get_value(node_h, buf_ptr, buf_len) {
            \\    return _write_str(buf_ptr, buf_len, _get_node(node_h).value ?? "");
            \\  },
            \\
            \\  sax_dom_set_value(node_h, val_ptr, val_len) {
            \\    _get_node(node_h).value = _read_str(val_ptr, val_len);
            \\  },
            \\
            \\  // 事件系统
            \\  sax_dom_bind_event(node_h, evt_ptr, evt_len, handler_ptr, handler_len, ctx) {
            \\    const evt = _read_str(evt_ptr, evt_len);
            \\    const handler = _read_str(handler_ptr, handler_len);
            \\    const el = _get_node(node_h);
            \\    const listener = () => {
            \\      if (_wasm_instance && _wasm_instance.exports[handler]) {
            \\        _wasm_instance.exports[handler](ctx);
            \\      }
            \\    };
            \\    const key = `${Number(node_h)}::${evt}::${handler}::${ctx}`;
            \\    const prev = _bindingMap.get(key);
            \\    if (prev) {
            \\      prev.node.removeEventListener(prev.evt, prev.listener);
            \\    }
            \\    el.addEventListener(evt, listener);
            \\    _bindingMap.set(key, { node: el, evt, listener });
            \\  },
            \\
            \\  sax_dom_unbind_event(node_h, evt_ptr, evt_len, handler_ptr, handler_len, ctx) {
            \\    const evt = _read_str(evt_ptr, evt_len);
            \\    const handler = _read_str(handler_ptr, handler_len);
            \\    const key = `${Number(node_h)}::${evt}::${handler}::${ctx}`;
            \\    const binding = _bindingMap.get(key);
            \\    if (binding) {
            \\      binding.node.removeEventListener(binding.evt, binding.listener);
            \\      _bindingMap.delete(key);
            \\    }
            \\  },
            \\
            \\  sax_set_timeout(handler_ptr, handler_len, delay_ms) {
            \\    const handler = _read_str(handler_ptr, handler_len);
            \\    return BigInt(setTimeout(() => {
            \\      if (_wasm_instance && _wasm_instance.exports[handler]) {
            \\        _wasm_instance.exports[handler](0n);
            \\      }
            \\    }, Number(delay_ms)));
            \\  },
            \\
            \\  sax_set_interval(handler_ptr, handler_len, delay_ms) {
            \\    const handler = _read_str(handler_ptr, handler_len);
            \\    return BigInt(setInterval(() => {
            \\      if (_wasm_instance && _wasm_instance.exports[handler]) {
            \\        _wasm_instance.exports[handler](0n);
            \\      }
            \\    }, Number(delay_ms)));
            \\  },
            \\
            \\  sax_clear_timeout(id) {
            \\    clearTimeout(Number(id));
            \\  },
            \\
            \\  sax_clear_interval(id) {
            \\    clearInterval(Number(id));
            \\  },
            \\
            \\  sax_router_init(path_ptr, path_len) {
            \\    _router_sync_path();
            \\    _router_install_listeners();
            \\    return _write_str(path_ptr, path_len, _router_path);
            \\  },
            \\
            \\  // 路由
            \\  sax_router_get_path(buf_ptr, buf_len) {
            \\    _router_sync_path();
            \\    return _write_str(buf_ptr, buf_len, _router_path);
            \\  },
            \\
            \\  sax_router_push(path_ptr, path_len) {
            \\    const path = _read_str(path_ptr, path_len);
            \\    _router_path = path;
            \\    if (typeof history !== "undefined" && history.pushState) {
            \\      history.pushState({}, "", path);
            \\    } else if (typeof location !== "undefined") {
            \\      location.hash = path;
            \\    }
            \\  },
            \\
            \\  sax_router_replace(path_ptr, path_len) {
            \\    const path = _read_str(path_ptr, path_len);
            \\    _router_path = path;
            \\    if (typeof history !== "undefined" && history.replaceState) {
            \\      history.replaceState({}, "", path);
            \\    } else if (typeof location !== "undefined") {
            \\      location.hash = path;
            \\    }
            \\  },
            \\
            \\  // HTTP
            \\  sax_http_get(url_ptr, url_len) {
            \\    const url = _read_str(url_ptr, url_len);
            \\    return _http_request("GET", url, null);
            \\  },
            \\
            \\  sax_http_post(url_ptr, url_len, body_ptr, body_len) {
            \\    const url = _read_str(url_ptr, url_len);
            \\    const body = _read_str(body_ptr, body_len);
            \\    return _http_request("POST", url, body);
            \\  },
            \\
            \\  // 工具函数
            \\  sax_get_time() {
            \\    return BigInt(Date.now());
            \\  },
            \\
            \\  sax_itoa(value, buf_ptr, buf_len) {
            \\    return _write_str(buf_ptr, buf_len, value.toString());
            \\  },
            \\
            \\  sax_ftoa(value, decimals, buf_ptr, buf_len) {
            \\    return _write_str(buf_ptr, buf_len, value.toFixed(Number(decimals)));
            \\  },
            \\
            \\  sax_ftoa_bits(value_bits, decimals, buf_ptr, buf_len) {
            \\    const scratch = new ArrayBuffer(8);
            \\    const view = new DataView(scratch);
            \\    view.setBigInt64(0, BigInt(value_bits), true);
            \\    const value = view.getFloat64(0, true);
            \\    return _write_str(buf_ptr, buf_len, value.toFixed(Number(decimals)));
            \\  },
            \\
            \\  sax_mem_copy(dst_ptr, src_ptr, len) {
            \\    const dst = new Uint8Array(_mem.buffer, Number(dst_ptr), Number(len));
            \\    const src = new Uint8Array(_mem.buffer, Number(src_ptr), Number(len));
            \\    dst.set(src);
            \\  },
            \\};
            \\
            \\export function sax_debug_get_memory() {
            \\  return _mem;
            \\}
            \\
            \\export function sax_debug_get_node(h) {
            \\  return _get_node(h);
            \\}
            \\
            \\async function _load_wgpu_airlock() {
            \\  if (!SAX_WGPU_REQUIRED) return null;
            \\  const mod = await import("./wgpu_airlock.js");
            \\  if (!mod.sax_wgpu_airlock || !mod.sax_wgpu_bind_wasm) {
            \\    throw new Error("wgpu_airlock.js does not expose the SAX WGPU broker surface");
            \\  }
            \\  return mod;
            \\}
            \\
            \\async function _load_sa3d_airlock() {
            \\  if (!SAX_SA3D_REQUIRED) return null;
            \\  const mod = await import("./sa3d_airlock.js");
            \\  if (!mod.sax_sa3d_airlock || !mod.sax_sa3d_bind_wasm) {
            \\    throw new Error("sa3d_airlock.js does not expose the SAX SA3D broker surface");
            \\  }
            \\  return mod;
            \\}
            \\
            \\// ── WASM 加载入口
            \\let _wasm_instance;
            \\export async function sax_init(wasm_url) {
            \\  const wgpu_module = await _load_wgpu_airlock();
            \\  const sa3d_module = await _load_sa3d_airlock();
            \\  const imports = { ...sax_airlock };
            \\  if (wgpu_module) Object.assign(imports, wgpu_module.sax_wgpu_airlock);
            \\  if (sa3d_module) Object.assign(imports, sa3d_module.sax_sa3d_airlock);
            \\  const { instance } = await WebAssembly.instantiateStreaming(
            \\    fetch(wasm_url),
            \\    { env: imports }
            \\  );
            \\  _wasm_instance = instance;
            \\  _mem = instance.exports.memory;
            \\  if (wgpu_module) wgpu_module.sax_wgpu_bind_wasm(instance, _mem);
            \\  if (sa3d_module) sa3d_module.sax_sa3d_bind_wasm(instance, _mem);
            \\  _malloc_next = _align_up(_heap_base(), 8);
            \\  _router_sync_path();
            \\  _router_install_listeners();
            \\  if (instance.exports.sax_app_init) {
            \\    instance.exports.sax_app_init();
            \\  }
            \\}
            \\
            \\let _sax_boot_started = false;
            \\function _sax_boot() {
            \\  if (_sax_boot_started) return;
            \\  _sax_boot_started = true;
            \\  sax_init("./app.wasm").catch((err) => console.error(err));
            \\}
            \\
            \\if (typeof window !== "undefined" && typeof document !== "undefined") {
            \\  window.sax_debug_get_node = sax_debug_get_node;
            \\  if (document.readyState === "loading") {
            \\    window.addEventListener("DOMContentLoaded", _sax_boot, { once: true });
            \\  } else {
            \\    _sax_boot();
            \\  }
            \\}
        ;

        try output.appendSlice(airlock_template);
        return output;
    }

    /// 生成 index.html 入口文件
    pub fn generateIndexHTML(self: *AirlockGenerator, title: []const u8, wasm_file_name: []const u8) !std.ArrayList(u8) {
        var output = std.ArrayList(u8).init(self.allocator);
        errdefer output.deinit();

        try output.writer().print(
            \\<!DOCTYPE html>
            \\<html lang="en">
            \\<head>
            \\  <meta charset="UTF-8">
            \\  <meta name="viewport" content="width=device-width, initial-scale=1.0">
            \\  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; img-src 'self' data:; style-src 'self'; object-src 'none'; base-uri 'none'">
            \\  <link rel="preload" href="./{s}" as="fetch" crossorigin>
            \\  <title>{s}</title>
            \\</head>
            \\<body>
            \\  <div id="app"></div>
            \\  <script type="module" src="./airlock.js"></script>
            \\</body>
            \\</html>
        ,
            .{ wasm_file_name, title },
        );

        return output;
    }
};

test "airlock generator emits the documented bridge surface" {
    var generator = AirlockGenerator.init(std.testing.allocator);
    const js = try generator.generateAirlockJS();
    defer js.deinit();

    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "const SAX_AIRLOCK_VERSION = \"1.0\";"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "export const sax_airlock = {"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "malloc(size)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "return _malloc(size);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "free(_ptr)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "write(_fd, _ptr, len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "exit(code)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_dom_query(sel_ptr, sel_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "const SAX_WGPU_REQUIRED = false;"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "const SAX_SA3D_REQUIRED = false;"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "const SAX_ALLOWED_ATTRS = new Set([\"class\", \"style\", \"value\", \"placeholder\", \"disabled\", \"id\", \"width\", \"height\", \"renderer\"]);"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "SaxInvalidAttribute"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_dom_bind_event(node_h, evt_ptr, evt_len, handler_ptr, handler_len, ctx)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_router_get_path(buf_ptr, buf_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_router_push(path_ptr, path_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_router_replace(path_ptr, path_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_router_init(path_ptr, path_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_http_get(url_ptr, url_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_http_post(url_ptr, url_len, body_ptr, body_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_ftoa_bits(value_bits, decimals, buf_ptr, buf_len)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "export function sax_debug_get_node(h)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "export async function sax_init(wasm_url)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "DOMContentLoaded"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_init(\"./app.wasm\")"));
}

test "airlock generator can require the WGPU sidecar" {
    var generator = AirlockGenerator.init(std.testing.allocator);
    const js = try generator.generateAirlockJSWithOptions(.{ .wgpu = true });
    defer js.deinit();

    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "const SAX_WGPU_REQUIRED = true;"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "await import(\"./wgpu_airlock.js\")"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "Object.assign(imports, wgpu_module.sax_wgpu_airlock)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_wgpu_bind_wasm(instance, _mem)"));
}

test "airlock generator can require the SA3D sidecar" {
    var generator = AirlockGenerator.init(std.testing.allocator);
    const js = try generator.generateAirlockJSWithOptions(.{ .sa3d = true });
    defer js.deinit();

    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "const SAX_SA3D_REQUIRED = true;"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "await import(\"./sa3d_airlock.js\")"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "Object.assign(imports, sa3d_module.sax_sa3d_airlock)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, js.items, 1, "sax_sa3d_bind_wasm(instance, _mem)"));
}
