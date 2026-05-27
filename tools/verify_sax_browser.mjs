import { access, readFile } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { chromium, firefox, webkit } from "playwright";

const browserMap = { chromium, firefox, webkit };
const playwrightCacheDir = path.join(process.env.HOME ?? "", ".cache", "ms-playwright");

function browserExecutablePath(browserName) {
  if (browserName === "chromium") {
    return path.join(playwrightCacheDir, "chromium-1179", "chrome-linux", "chrome");
  }
  if (browserName === "firefox") {
    return path.join(playwrightCacheDir, "firefox-1488", "firefox", "firefox");
  }
  if (browserName === "webkit") {
    return path.join(playwrightCacheDir, "webkit-2182", "pw_run.sh");
  }
  return null;
}

function contentType(file) {
  if (file.endsWith(".html")) return "text/html; charset=utf-8";
  if (file.endsWith(".js")) return "text/javascript; charset=utf-8";
  if (file.endsWith(".wasm")) return "application/wasm";
  if (file.endsWith(".sa")) return "text/plain; charset=utf-8";
  return "application/octet-stream";
}

function startStaticServer(rootDir) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      try {
        const url = new URL(req.url ?? "/", "http://127.0.0.1");
        const fileName = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
        const safePath = path.normalize(fileName).replace(/^(\.\.(\/|\\|$))+/, "");
        const filePath = path.join(rootDir, safePath);
        const body = await readFile(filePath);
        res.writeHead(200, { "Content-Type": contentType(filePath), "Cache-Control": "no-store" });
        res.end(body);
      } catch (err) {
        res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
        res.end(err instanceof Error ? err.message : String(err));
      }
    });
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("failed to bind test server"));
        return;
      }
      resolve({
        server,
        url: `http://127.0.0.1:${address.port}/`,
      });
    });
  });
}

async function expectCounter(page) {
  await page.waitForSelector("section.counter");
  const heading = page.locator("section.counter h1");
  await heading.waitFor();
  const headingText = async () => (await heading.textContent())?.trim();

  if ((await headingText()) !== "0") throw new Error(`expected initial count 0, got ${await headingText()}`);

  await page.getByRole("button", { name: "+1" }).click();
  if ((await headingText()) !== "1") throw new Error(`expected count 1 after +1, got ${await headingText()}`);

  await page.getByRole("button", { name: "-1" }).click();
  if ((await headingText()) !== "0") throw new Error(`expected count 0 after -1, got ${await headingText()}`);

  await page.getByRole("button", { name: "-1" }).click();
  if ((await headingText()) !== "-1") throw new Error(`expected count -1 after second -1, got ${await headingText()}`);

  await page.getByRole("button", { name: "Reset" }).click();
  if ((await headingText()) !== "0") throw new Error(`expected count 0 after reset, got ${await headingText()}`);
}

async function runBrowser(browserName, outDir) {
  const browserType = browserMap[browserName];
  if (!browserType) throw new Error(`unsupported browser '${browserName}'`);

  const { server, url } = await startStaticServer(outDir);
  const launchOptions = { headless: true };
  const executablePath = browserExecutablePath(browserName);
  if (executablePath) {
    try {
      await access(executablePath);
      launchOptions.executablePath = executablePath;
    } catch {}
  }
  if (browserName === "webkit") {
    launchOptions.env = {
      ...process.env,
      LD_LIBRARY_PATH: [
        path.join(playwrightCacheDir, "webkit-2182", "minibrowser-gtk", "lib"),
        path.join(playwrightCacheDir, "webkit-2182", "minibrowser-gtk", "sys", "lib"),
        process.env.LD_LIBRARY_PATH ?? "",
      ]
        .filter(Boolean)
        .join(":"),
    };
  }
  const browser = await browserType.launch(launchOptions);
  try {
    const page = await browser.newPage();
    const pageErrors = [];
    const failedRequests = [];
    page.on("pageerror", (err) => pageErrors.push(err.stack || err.message));
    page.on("console", (msg) => {
      if (msg.type() === "error" && !msg.text().includes("Failed to load resource: the server responded with a status of 404 (Not Found)")) {
        pageErrors.push(msg.text());
      }
    });
    page.on("requestfailed", (req) => {
      failedRequests.push(`${req.url()} :: ${req.failure()?.errorText ?? "request failed"}`);
    });
    await page.goto(url, { waitUntil: "networkidle" });
    await expectCounter(page);
    if (pageErrors.length !== 0) {
      throw new Error(`browser console/page errors:\n${pageErrors.join("\n")}`);
    }
    const fatalRequests = failedRequests.filter((line) => !line.includes("/favicon.ico"));
    if (fatalRequests.length !== 0) {
      throw new Error(`browser request failures:\n${fatalRequests.join("\n")}`);
    }
  } finally {
    await browser.close();
    await new Promise((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  }
}

const [, , outDir, ...requestedBrowsers] = process.argv;
if (!outDir) {
  console.error("usage: node tools/verify_sax_browser.mjs <sax-output-dir> [chromium firefox webkit]");
  process.exit(2);
}

await access(path.join(outDir, "index.html"));
await access(path.join(outDir, "airlock.js"));
await access(path.join(outDir, "app.wasm"));

const browsers = requestedBrowsers.length === 0 ? ["chromium", "firefox", "webkit"] : requestedBrowsers;
for (const browserName of browsers) {
  await runBrowser(browserName, outDir);
  console.log(`[PASS] sax browser ${browserName}`);
}
