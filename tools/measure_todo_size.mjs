import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { gzipSync } from "node:zlib";
import { build as esbuild } from "esbuild";

const pluginRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const outDir = path.join(pluginRoot, ".tmp", "react-todo");
const entryFile = path.join(pluginRoot, "tools", "react_todo_entry.jsx");
const htmlFile = path.join(outDir, "index.html");
const bundleFile = path.join(outDir, "bundle.js");

await rm(outDir, { recursive: true, force: true });
await mkdir(outDir, { recursive: true });

await esbuild({
  entryPoints: [entryFile],
  outfile: bundleFile,
  bundle: true,
  minify: true,
  format: "iife",
  target: ["chrome120", "firefox120", "safari17"],
});

await writeFile(
  htmlFile,
  [
    "<!doctype html>",
    "<html>",
    "<head>",
    '  <meta charset="utf-8" />',
    '  <meta name="viewport" content="width=device-width, initial-scale=1" />',
    "  <title>React TodoList</title>",
    "</head>",
    "<body>",
    '  <div id="app"></div>',
    '  <script src="./bundle.js"></script>',
    "</body>",
    "</html>",
    "",
  ].join("\n"),
  "utf8",
);

async function fileSize(file) {
  return (await stat(file)).size;
}

async function gzipSize(file) {
  return gzipSync(await readFile(file)).length;
}

const bundleBytes = await fileSize(bundleFile);
const bundleGzipBytes = await gzipSize(bundleFile);
const htmlBytes = await fileSize(htmlFile);

console.log(
  JSON.stringify(
    {
      html_bytes: htmlBytes,
      js_bundle_bytes: bundleBytes,
      js_bundle_gzip_bytes: bundleGzipBytes,
      total_static_bytes: htmlBytes + bundleBytes,
      out_dir: outDir,
      bundle_file: bundleFile,
    },
    null,
    2,
  ),
);
