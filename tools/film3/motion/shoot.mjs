// film3-motion's capture driver: headless Chrome over the DevTools protocol with Node's own WebSocket (no packages), after film2/stage2/shoot.mjs.
//   node shoot.mjs stills --work <dir> --out <dir> --times 1.5,3,9.2       PNG per time (+ report json); --blur 1 renders them as the film does
//   node shoot.mjs probe  --work <dir> --out <probe.json>                  per film frame: the page's report + how far the objects move (no pictures)
//   node shoot.mjs film   --work <dir> --probe <probe.json> [--from s --to s]   the frames to stdout for blend.py: per frame u32 n, then n x (u32 len, PNG)
// The page draws a pure function of time (film.html, __film.seek); a frame whose objects move more than 3 px is made of sub-frames spread over the
// shutter (180 degrees, 360 in the two whips) that blend.py averages: motion blur from the motion itself. Chrome gets its own profile under the
// work dir, and only the pid it was started with (written to <work>/chrome.<mode>.pid) is ever signalled.
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const [mode, ...rest] = process.argv.slice(2);
const opt = { work: "/tmp/film3/motion/work", times: "", from: "0", to: "1e9", blur: "0" };
for (let i = 0; i < rest.length; i += 2) opt[rest[i].replace(/^--/, "")] = rest[i + 1];
if (!["stills", "probe", "film"].includes(mode)) {
  console.error("usage: node shoot.mjs stills|probe|film --work <dir> [...]");
  process.exit(2);
}
const WORK = resolve(opt.work);
const log = (s) => process.stderr.write("shoot: " + s + "\n");
const profile = join(WORK, "chrome-" + mode + "-" + process.pid);
rmSync(profile, { recursive: true, force: true });
mkdirSync(profile, { recursive: true });
const chrome = spawn(CHROME, [
  "--headless=new", "--remote-debugging-port=0", "--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check",
  "--hide-scrollbars", "--mute-audio", "--window-size=1920,1080", "--force-device-scale-factor=1", "--allow-file-access-from-files",
  "--enable-gpu-rasterization", "--ignore-gpu-blocklist", "--force-color-profile=srgb", "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });
writeFileSync(join(WORK, "chrome." + mode + ".pid"), String(chrome.pid));
let chromeErr = "";
chrome.stderr.on("data", (d) => { chromeErr += d; });
const done = (code) => {
  chrome.once("exit", () => { try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(code); });
  try { process.kill(chrome.pid); } catch { process.exit(code); }
};
process.on("uncaughtException", (e) => { log(e && e.stack || e); done(1); });
process.on("unhandledRejection", (e) => { log(e && e.stack || e); done(1); });

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
const consoleLog = [];
listeners.push((m) => {
  if (m.method === "Runtime.consoleAPICalled") consoleLog.push(m.params.type + ": " + m.params.args.map((a) => a.value ?? a.description).join(" "));
  if (m.method === "Runtime.exceptionThrown") consoleLog.push("exception: " + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
});
const { targetId } = await send("Target.createTarget", { url: "about:blank" });
const { sessionId: S } = await send("Target.attachToTarget", { targetId, flatten: true });
const page = (method, params) => send(method, params, S);
await page("Runtime.enable");
await page("Page.enable");
await page("Emulation.setDeviceMetricsOverride", { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
async function evaluate(expr) {
  const r = await page("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error("page: " + (r.exceptionDetails.exception?.description || r.exceptionDetails.text) + "\n" + consoleLog.join("\n"));
  return r.result.value;
}
const loaded = new Promise((r) => listeners.push((m) => { if (m.method === "Page.loadEventFired") r(); }));
await page("Page.navigate", { url: pathToFileURL(join(HERE, "film.html")).href + "?data=" + encodeURIComponent(pathToFileURL(join(WORK, "data.js")).href) });
await loaded;
await evaluate("window.__film.ready");
const fps = await evaluate("window.__film.fps"), duration = await evaluate("window.__film.duration");
const shot = async () => Buffer.from((await page("Page.captureScreenshot", { format: "png", fromSurface: true, optimizeForSpeed: true })).data, "base64");
const seek = (t) => evaluate(`window.__film.seek(${t.toFixed(5)}).then(() => true)`);

function subTimes(t, n, shutter) {
  if (n <= 1) return [t];
  return Array.from({ length: n }, (_, k) => t + ((k + 0.5) / n - 0.5) * shutter / fps);
}

if (mode === "stills") {
  const out = resolve(opt.out);
  mkdirSync(out, { recursive: true });
  const probe = +opt.blur && existsSync(join(WORK, "probe.json")) ? JSON.parse(readFileSync(join(WORK, "probe.json"), "utf8")) : null;
  const reps = [];
  for (const ts of opt.times.split(",").filter(Boolean)) {
    const t = +ts, f = Math.round(t * fps);
    const plan = probe ? probe.frames[f] : null;
    if (plan && plan.n > 1) {
      // sub-frames, each saved; blend.py --stills averages them
      const subs = [];
      for (const [k, st] of subTimes(f / fps, plan.n, plan.shutter).entries()) { await seek(st); const p = join(out, `s${ts}_${k}.png`); writeFileSync(p, await shot()); subs.push(p); }
      reps.push({ t, subs });
    } else {
      await seek(t);
      writeFileSync(join(out, `s${ts}.png`), await shot());
      reps.push(Object.assign(await evaluate("window.__film.report()"), { t }));
    }
  }
  writeFileSync(join(out, "stills.json"), JSON.stringify({ reps, times: await evaluate("window.__film.times()"), overlaps: await evaluate("window.__film.chipOverlaps()"), console: consoleLog }, null, 1));
  log(`${reps.length} stills in ${out}`);
} else if (mode === "probe") {
  // per frame: the report at t, and the largest move of any tracked point over one frame (t - 1/2 frame -> t + 1/2 frame)
  const n = Math.round(duration * fps), frames = [];
  for (let f = 0; f < n; f++) {
    const t = f / fps;
    const a = await evaluate(`window.__film.seek(${(t - 0.5 / fps).toFixed(5)}).then((r) => r.points)`);
    const b = await evaluate(`window.__film.seek(${(t + 0.5 / fps).toFixed(5)}).then((r) => r.points)`);
    await seek(t);
    const rep = await evaluate("window.__film.report()");
    let disp = 0;
    if (a.length === b.length) for (let i = 0; i < a.length; i++) disp = Math.max(disp, Math.hypot(b[i][0] - a[i][0], b[i][1] - a[i][1]));
    const shutter = await evaluate(`window.__film.shutter(${t})`);
    const sub = disp < 3 ? 1 : Math.max(4, Math.min(shutter >= 1 ? 48 : 16, Math.ceil(disp * shutter / 2.5)));   // the whips: up to 48, so no ghost steps
    delete rep.points;
    frames.push(Object.assign(rep, { f, disp: Math.round(disp * 10) / 10, n: sub, shutter }));
    if (f % 300 === 0) log(`probe ${f}/${n}`);
  }
  writeFileSync(resolve(opt.out), JSON.stringify({ fps, duration, times: await evaluate("window.__film.times()"), overlaps: await evaluate("window.__film.chipOverlaps()"), frames, console: consoleLog }));
  log(`probe: ${n} frames, ${frames.filter((r) => r.n > 1).length} blurred (${frames.reduce((s, r) => s + r.n, 0)} captures)`);
} else {
  const probe = JSON.parse(readFileSync(resolve(opt.probe), "utf8"));
  const f0 = Math.round(+opt.from * fps), f1 = Math.min(probe.frames.length, Math.round(+opt.to * fps));
  const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32LE(v); return b; };
  const write = (buf) => new Promise((r) => (process.stdout.write(buf) ? r() : process.stdout.once("drain", r)));
  const t0 = Date.now();
  for (let f = f0; f < f1; f++) {
    const plan = probe.frames[f];
    const ts = subTimes(f / fps, plan.n, plan.shutter);
    await write(u32(ts.length));
    for (const t of ts) { await seek(t); const png = await shot(); await write(u32(png.length)); await write(png); }
    if ((f - f0) % 120 === 0) log(`film ${f}/${f1} (${((Date.now() - t0) / 1000).toFixed(0)} s)`);
  }
  log(`film: frames ${f0}-${f1} in ${((Date.now() - t0) / 1000).toFixed(0)} s`);
}
if (consoleLog.length) writeFileSync(join(WORK, mode + ".console.txt"), consoleLog.join("\n") + "\n");
done(0);
