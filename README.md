# SAX Plugin

SAX is the SA UI dialect plugin. It turns a `.sax` source file into a browser-ready bundle with real artifacts, not a stub.

## What `sa sax build` produces

For an input such as `demos/counter.sax`, the build command generates:

- `app.wasm`
- `airlock.js`
- `index.html`
- `app.sa`

`app.wasm` contains the component logic, `airlock.js` is the DOM bridge, and `index.html` loads both.

When a source uses a browser sidecar renderer, SAX also copies the sidecar broker into the output directory:

- `renderer="wgpu"`, `sa_wgpu_`, or `WGPU_CUBE_` copies `wgpu_airlock.js`.
- `renderer="sa3d"`, `sa3d_`, or `SA3D_` copies `sa3d_airlock.js`.

The sidecar share directory is discovered from explicit env vars, `SA_PLUGINS_PATH`, an installed plugin home, or the local development checkout. The current 3D engine development fallback is `/home/vscode/projects/sa_plugins/sa_plugin_3dengines/sa_plugin_3d/zig-out/share`.

## Example

```bash
SA_PLUGINS_PATH=$PWD/zig-out/lib/libsax.so /home/vscode/projects/sci/zig-out/bin/sa sax build demos/counter.sax --out-dir /tmp/sax-counter
```

## Verification

The plugin ships with runtime checks for:

- `sa sax check` parser and trap validation
- `sa sax build` output generation
- Node runtime mounting of the generated `app.wasm + airlock.js`
- Counter and TodoList demos
- Airlock rejection for `<script>`, `innerHTML`, and inline `eval`

For a quick browser smoke test on Chromium:

```bash
node tools/verify_sax_browser.mjs /tmp/sax-counter chromium
```

## Notes

- The plugin is intended to be built and tested from its own directory.
- The generated HTML uses a CSP that allows WebAssembly startup and keeps the DOM bridge under the Airlock boundary.
