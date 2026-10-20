// Headless Chrome driver for the stage2 game page (game.html), over the DevTools protocol with Node's own WebSocket: no packages.
//   node shoot.mjs still  --out <dir> [--size 1280] [--scale 2] [--lines 2,3,4,10] [--query k=v&...]   L<id>.png per line + still.json
//   node shoot.mjs frames --out <dir> [--size 1280] [--scale 1] [--fps 30] [--seconds 6] [--query play=1&dwell=2]  f00000.png ... + frames.json
//   node shoot.mjs fps    --out <dir> [--size 1280] [--scale 2] [--seconds 5]                                     fps.json (real clock, rAF)
// Stills and frames run the page on its manual clock (clock=manual): the driver sets the time, the page draws that frame, the
// driver captures it, so a 30 fps video is exact whatever the machine's load. Each still and frame records the page's own report
// (__stage.report(): the line on screen, its speaker, how many lines the text needs, the text block's rect, the reveal state).
// Chrome is started with its own profile under the scratch dir, and only the pid it was started with is signalled.
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const [mode, ...rest] = process.argv.slice(2);
const opt = { size: 1280, scale: mode === "frames" ? 1 : 2, fps: 30, seconds: mode === "fps" ? 5 : 6, lines: "", query: "", page: join(HERE, "game.html") };
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, "")] = rest[i + 1];
if (!["still", "frames", "fps"].includes(mode) || !opt.out) {
  console.error("usage: node shoot.mjs still|frames|fps --out <dir> [...]");
  process.exit(2);
}
const OUT = resolve(opt.out);
mkdirSync(OUT, { recursive: true });
const size = +opt.size, scale = +opt.scale;
const profile = join(process.env.SCRATCH || "/tmp/film2/stage2", "chrome-" + mode + "-" + process.pid);
rmSync(profile, { recursive: true, force: true });
mkdirSync(profile, { recursive: true });

const chrome = spawn(CHROME, [
  "--headless=new", "--remote-debugging-port=0", "--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check",
  "--hide-scrollbars", "--mute-audio", "--window-size=" + size + "," + size, "--force-device-scale-factor=" + scale,
  "--enable-gpu-rasterization", "--ignore-gpu-blocklist", "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });
writeFileSync(join(OUT, "chrome." + mode + ".pid"), String(chrome.pid));
let chromeErr = "";
chrome.stderr.on("data", (d) => { chromeErr += d; });
const done = (code) => {   // the profile goes once Chrome has exited (it writes into it while it quits)
  chrome.once("exit", () => { try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(code); });
  try { process.kill(chrome.pid); } catch { process.exit(code); }
};
process.on("uncaughtException", (e) => { console.error("shoot: " + (e && e.message)); done(1); });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function port() {
  const f = join(profile, "DevToolsActivePort");
  for (let i = 0; i < 300; i++) {
    if (existsSync(f)) {
      const [p, path] = readFileSync(f, "utf8").split("\n");
      if (p && path) return "ws://127.0.0.1:" + p + path;
    }
    await sleep(100);
  }
  throw new Error("Chrome did not open its DevTools port: " + chromeErr.slice(-400));
}

const ws = new WebSocket(await port());
await new Promise((r, j) => { ws.onopen = r; ws.onerror = () => j(new Error("DevTools socket error")); });
let seq = 0;
const waiting = new Map(), listeners = [];
ws.onmessage = (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && waiting.has(m.id)) {
    const { ok, no } = waiting.get(m.id);
    waiting.delete(m.id);
    m.error ? no(new Error(m.error.message + " " + (m.error.data || ""))) : ok(m.result);
  } else if (m.method) listeners.forEach((l) => l(m));
};
const send = (method, params = {}, sessionId) => new Promise((ok, no) => {
  const id = ++seq;
  waiting.set(id, { ok, no });
  ws.send(JSON.stringify({ id, method, params, sessionId }));
});
const log = [];
listeners.push((m) => {
  if (m.method === "Runtime.consoleAPICalled") log.push(m.params.type + ": " + m.params.args.map((a) => a.value ?? a.description).join(" "));
  if (m.method === "Runtime.exceptionThrown") log.push("exception: " + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
});

const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId: S } = await send("Target.attachToTarget", { targetId, flatten: true });
const page = (method, params) => send(method, params, S);
await page("Runtime.enable");
await page("Page.enable");
await page("Emulation.setDeviceMetricsOverride", { width: size, height: size, deviceScaleFactor: scale, mobile: false });
async function evaluate(expr) {
  const r = await page("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error("page: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
  return r.result.value;
}
async function open(query) {
  const loaded = new Promise((r) => listeners.push((m) => { if (m.method === "Page.loadEventFired") r(); }));
  await page("Page.navigate", { url: pathToFileURL(resolve(opt.page)).href + "?" + query });
  await loaded;
  await evaluate("window.__stage.ready");
}
async function shot(path) {
  const { data } = await page("Page.captureScreenshot", { format: "png", fromSurface: true });
  writeFileSync(path, Buffer.from(data, "base64"));
}
const extra = opt.query ? "&" + opt.query : "";

if (mode === "still") {
  const ids = opt.lines ? opt.lines.split(",") : Array.from({ length: 36 }, (_, i) => String(i + 1));
  const rows = [];
  for (const id of ids) {
    await open("line=" + id + "&clock=manual" + extra);
    // 1.2 s into the line: the reveal (<= 0.4 s) and the portrait's entrance are over, the scene has moved on its own.
    const rep = await evaluate("window.__stage.advanceTo(1200), window.__stage.report()");
    await shot(join(OUT, "L" + id + ".png"));
    rows.push(rep);
  }
  writeFileSync(join(OUT, "still.json"), JSON.stringify({ size, scale, rows, gl: await evaluate("window.__stage.gl"), log }, null, 1));
  console.log("shoot: " + rows.length + " stills in " + OUT + ", most lines a text needs: " + Math.max(...rows.map((r) => r.lines)) + ", gl " + (await evaluate("window.__stage.gl")));
} else if (mode === "frames") {
  await open("clock=manual" + (opt.query ? extra : "&play=1&dwell=2"));
  const n = Math.round(+opt.seconds * +opt.fps), rows = [];
  for (let i = 0; i < n; i++) {
    const rep = await evaluate("window.__stage.advanceTo(" + (i * 1000 / +opt.fps).toFixed(3) + "), window.__stage.report()");
    await shot(join(OUT, "f" + String(i).padStart(5, "0") + ".png"));
    rows.push(rep);
  }
  writeFileSync(join(OUT, "frames.json"), JSON.stringify({ size, scale, fps: +opt.fps, rows, log }, null, 1));
  console.log("shoot: " + n + " frames in " + OUT);
} else {
  await open("play=1&dwell=2" + extra);
  const r = await evaluate("window.__stage.measure(" + (+opt.seconds * 1000) + ")");
  r.gl = await evaluate("window.__stage.gl");
  writeFileSync(join(OUT, "fps.json"), JSON.stringify({ size, scale, ...r, log }, null, 1));
  console.log("shoot: fps " + r.fps.toFixed(1) + " over " + r.frames + " frames, p95 frame " + r.p95.toFixed(1) + " ms, gpu-bound draw " + r.drawMs.toFixed(2) + " ms (" + size + "x" + size + " @" + scale + "), gl " + r.gl);
}
if (log.length) writeFileSync(join(OUT, mode + ".console.txt"), log.join("\n") + "\n");
done(0);
