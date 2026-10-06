#!/usr/bin/env node
/**
 * OpenClaw gateway launcher — FREE TIER variant (512 MB / 0.2 vCPU).
 *
 * Design (proven by measurement in-container):
 *   - Runtime: Bun (RSS ~209 MB vs Node ~275 MB minimal / ~685 MB full config)
 *   - State dir: /dev/shm (719 MB tmpfs) -> instant fsync, avoids the Kata
 *     Containers overlay write stall that made SQLite startup checkpoints
 *     loop for 19s+ and prevented the port from ever binding.
 *   - tmpfs is volatile, so state is periodically tarballed to disk and
 *     restored on boot.
 *   - Minimal config: no MCP servers, no heartbeat by default (keeps RSS low).
 *
 * Self-healing:
 *   - crash  -> restart with exponential backoff (5s..60s, reset after 90s up)
 *   - hang   -> HTTP watchdog kills an unresponsive gateway
 *   - boot   -> this file is the container CMD, so it runs on every boot
 *
 * Required env: GATEWAY_TOKEN
 * Optional env: PUBLIC_HOST, TRUSTED_PROXIES, ROUTER_BASE_URL, ROUTER_API_KEY,
 *   MAX_OLD_SPACE_MB, PORT, WATCHDOG_INTERVAL_SECONDS, WATCHDOG_FAILURES,
 *   BACKUP_PATH, BACKUP_INTERVAL_SECONDS, HEARTBEAT_EVERY, ENABLE_MCP.
 */
import { spawn } from "node:child_process";
import { mkdir, writeFile, copyFile, access } from "node:fs/promises";
import { createReadStream, createWriteStream } from "node:fs";
import { createGzip, createGunzip } from "node:zlib";
import { pipeline } from "node:stream/promises";
import path from "node:path";
import crypto from "node:crypto";
import http from "node:http";

const stateDir = process.env.OPENCLAW_STATE_DIR ?? "/dev/shm/openclaw";
const configPath = process.env.OPENCLAW_CONFIG_PATH ?? path.join(stateDir, "openclaw.json");
const port = Number(process.env.PORT ?? 18789);
const backupPath = process.env.BACKUP_PATH ?? "/root/.openclaw-backup.tar.gz";
const backupIntervalSec = Number(process.env.BACKUP_INTERVAL_SECONDS ?? 300);
const watchdogIntervalSec = Number(process.env.WATCHDOG_INTERVAL_SECONDS ?? 60);
const watchdogFailures = Number(process.env.WATCHDOG_FAILURES ?? 4);
const enableMcp = process.env.ENABLE_MCP === "1";

const log = (m) => process.stdout.write(`[launcher] ${new Date().toISOString()} ${m}\n`);
const csv = (v) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);

function token() {
  const t = process.env.GATEWAY_TOKEN;
  if (t) return t;
  const gen = crypto.randomBytes(16).toString("hex");
  log("GATEWAY_TOKEN unset; generated ephemeral token: " + gen);
  return gen;
}

function buildConfig(authToken) {
  const publicHost = process.env.PUBLIC_HOST ?? "";
  const routerBase = process.env.ROUTER_BASE_URL ?? "";
  const routerKey = process.env.ROUTER_API_KEY ?? "";
  const nullrouteKey = process.env.NULLROUTE_KEY ?? "";

  const config = {
    gateway: {
      mode: "local",
      bind: "lan",
      port,
      trustedProxies: csv(process.env.TRUSTED_PROXIES || "10.0.0.0/8"),
      auth: { mode: "token", token: authToken },
    },
    agents: {
      defaults: { workspace: path.join(stateDir, "workspace") },
    },
  };
  if (publicHost) config.gateway.controlUi = { allowedOrigins: [`https://${publicHost}`] };

  // Model provider (only when configured) — keeps config tiny by default.
  if (routerBase) {
    config.models = {
      providers: {
        router: {
          baseUrl: routerBase,
          api: "openai-completions",
          apiKey: routerKey,
          models: [
            { id: "nullroute/smart", name: "NullRoute Smart", contextWindow: 1048576, maxTokens: 32768, input: ["text", "image"] },
          ],
        },
      },
    };
    config.agents.defaults.model = "router/nullroute/smart";
  }

  if (process.env.HEARTBEAT_EVERY) {
    config.agents.defaults.heartbeat = { every: process.env.HEARTBEAT_EVERY };
  }

  // MCP servers are the largest idle-memory cost — opt-in only on free tier.
  if (enableMcp && nullrouteKey) {
    const bearer = `Bearer ${nullrouteKey}`;
    config.mcp = {
      servers: {
        search: { url: "https://api.nullroute.lol/search/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
        memory: { url: "https://api.nullroute.lol/memory/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
        crawl: { url: "https://api.nullroute.lol/crawl/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
        context: { url: "https://api.nullroute.lol/docs/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
      },
    };
  }

  if (process.env.TELEGRAM_BOT_TOKEN) {
    const allowFrom = csv(process.env.TELEGRAM_ALLOW_FROM).map(Number);
    config.channels = { telegram: { botToken: process.env.TELEGRAM_BOT_TOKEN, enabled: true } };
    if (allowFrom.length > 0) config.channels.telegram.allowFrom = allowFrom;
  }
  return config;
}

async function writeConfig(authToken) {
  await mkdir(stateDir, { recursive: true });
  await mkdir(path.join(stateDir, "workspace"), { recursive: true });
  await writeFile(configPath, JSON.stringify(buildConfig(authToken), null, 2));
  log(`config written to ${configPath}`);
}

// --- state backup/restore (tmpfs <-> disk) ----------------------------------
async function tarDir(srcDir, outFile) {
  const { execFile } = await import("node:child_process");
  await new Promise((resolve, reject) => {
    execFile("tar", ["-czf", outFile, "-C", srcDir, "."], (err) => (err ? reject(err) : resolve()));
  });
}

async function restoreBackup() {
  try {
    await access(backupPath);
  } catch {
    return; // no backup yet
  }
  const { execFile } = await import("node:child_process");
  await mkdir(stateDir, { recursive: true });
  await new Promise((resolve, reject) => {
    execFile("tar", ["-xzf", backupPath, "-C", stateDir], (err) => (err ? reject(err) : resolve()));
  });
  log("state restored from disk backup");
}

async function doBackup(reason) {
  try {
    await tarDir(stateDir, backupPath);
    log(`state backed up (${reason}) -> ${backupPath}`);
  } catch (e) {
    log(`backup failed (${reason}): ${e?.message ?? e}`);
  }
}

// --- child env ---------------------------------------------------------------
function childEnv() {
  const env = { ...process.env };
  const oldSpace = process.env.MAX_OLD_SPACE_MB ?? "256";
  env.NODE_OPTIONS = `--max-old-space-size=${oldSpace} --max-semi-space-size=8 --dns-result-order=ipv4first`;
  env.OPENCLAW_STATE_DIR = stateDir;
  env.OPENCLAW_CONFIG_PATH = configPath;
  env.NODE_ENV = "production";
  env.UV_THREADPOOL_SIZE = env.UV_THREADPOOL_SIZE ?? "2";
  env.PATH = `/root/.bun/bin:${env.PATH ?? ""}`;
  return env;
}

function startGateway() {
  // Prefer Bun (lighter RSS) when present; fall back to the openclaw CLI.
  const entry = "/usr/local/lib/node_modules/openclaw/dist/index.js";
  const useBun = process.env.USE_BUN !== "0";
  const child = useBun
    ? spawn("bun", [entry, "gateway", "run", "--port", String(port), "--bind", "lan"], { env: childEnv(), stdio: "inherit" })
    : spawn("openclaw", ["gateway", "run", "--port", String(port), "--bind", "lan"], { env: childEnv(), stdio: "inherit" });
  log(`gateway spawned (pid ${child.pid}, ${useBun ? "bun" : "node"}, port ${port})`);
  return child;
}

let shuttingDown = false;
let child = null;
let restartDelayMs = 5000;
let startedAt = 0;
let probing = false;

function restart(reason) {
  if (shuttingDown) return;
  const delay = restartDelayMs;
  log(`${reason}; restarting in ${Math.round(delay / 1000)}s`);
  restartDelayMs = Math.min(restartDelayMs * 2, 60000);
  setTimeout(() => {
    if (shuttingDown) return;
    startedAt = Date.now();
    child = startGateway();
    child.on("exit", onChildExit);
  }, delay);
}

function onChildExit(code, signal) {
  if (shuttingDown) return;
  const uptime = startedAt ? Math.round((Date.now() - startedAt) / 1000) : 0;
  if (uptime > 90) restartDelayMs = 5000;
  child = null;
  restart(`gateway exited (code=${code}, signal=${signal}, uptime=${uptime}s)`);
}

function probeOnce() {
  return new Promise((resolve) => {
    const req = http.get({ host: "127.0.0.1", port, path: "/", timeout: 10000 }, (res) => { res.resume(); resolve(true); });
    req.on("timeout", () => { req.destroy(); resolve(false); });
    req.on("error", () => resolve(false));
  });
}

let failures = 0;
const watchdog = setInterval(async () => {
  if (shuttingDown || probing || !child) return;
  if (Date.now() - startedAt < 300000) return; // generous cold-start grace
  probing = true;
  const healthy = await probeOnce();
  probing = false;
  if (healthy) { failures = 0; return; }
  failures += 1;
  log(`watchdog: probe failed (${failures}/${watchdogFailures})`);
  if (failures >= watchdogFailures && child) {
    failures = 0;
    log("watchdog: unresponsive - killing child to force restart");
    try { child.kill("SIGKILL"); } catch {}
    setTimeout(() => { if (!shuttingDown && child === null) return; onChildExit(null, "SIGKILL"); }, 5000);
  }
}, Math.max(15, watchdogIntervalSec) * 1000);
watchdog.unref();

async function shutdown(reason, code) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`shutting down (${reason})`);
  clearInterval(watchdog);
  if (child && child.exitCode === null && !child.killed) {
    child.kill("SIGTERM");
    await new Promise((r) => { const t = setTimeout(r, 8000); child.once("exit", () => { clearTimeout(t); r(); }); });
  }
  await doBackup(reason);
  process.exit(code);
}

process.on("SIGTERM", () => void shutdown("SIGTERM", 0));
process.on("SIGINT", () => void shutdown("SIGINT", 0));
process.on("unhandledRejection", (e) => log(`unhandledRejection: ${e?.message ?? e}`));
process.on("uncaughtException", (e) => log(`uncaughtException: ${e?.message ?? e}`));

// --- boot -------------------------------------------------------------------
const AUTH_TOKEN = token();
await restoreBackup();
await writeConfig(AUTH_TOKEN);

const backupTimer = setInterval(() => void doBackup("interval"), Math.max(60, backupIntervalSec) * 1000);
backupTimer.unref();

startedAt = Date.now();
child = startGateway();
child.on("exit", onChildExit);
log(`supervisor ready (port ${port}, bun=${process.env.USE_BUN !== "0"})`);