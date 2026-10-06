#!/usr/bin/env node
/**
 * Northflank launcher for the OpenClaw gateway (single-container).
 *
 * Self-healing guarantees:
 *   - crash restart  : child exit -> restart with exponential backoff (5s..60s)
 *   - hang recovery  : HTTP watchdog kills a gateway that stops answering
 *   - boot recovery  : this process IS the container CMD, so Northflank
 *                      (re)starts it on every instance boot and after any
 *                      container-level failure
 *   - state survival : optional gzip snapshot to Turso/S3 (ephemeral disk)
 *
 * Optimized for 1 GB / 0.5 vCPU:
 *   - V8 old-space/semi-space caps sized from env
 *   - NODE_COMPILE_CACHE so restarts skip cold V8 compilation
 *   - UV_THREADPOOL_SIZE small, NODE_ENV=production
 *
 * Required env: GATEWAY_TOKEN
 * Optional env: PUBLIC_HOST, TRUSTED_PROXIES, ROUTER_BASE_URL, ROUTER_API_KEY,
 *   NULLROUTE_KEY, MAX_OLD_SPACE_MB, MAX_SEMI_SPACE_MB, PORT,
 *   WATCHDOG_INTERVAL_SECONDS, WATCHDOG_FAILURES, STATE_REMOTE,
 *   TURSO_DATABASE_URL, TURSO_AUTH_TOKEN, S3_*, STATE_SYNC_INTERVAL_SECONDS,
 *   TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOW_FROM, HEARTBEAT_EVERY.
 */
import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import http from "node:http";

const stateDir = process.env.OPENCLAW_STATE_DIR ?? "/root/.openclaw";
const configPath = process.env.OPENCLAW_CONFIG_PATH ?? path.join(stateDir, "openclaw.json");
const compileCacheDir = path.join(stateDir, ".node-compile-cache");
const port = Number(process.env.PORT ?? 18789);
const syncIntervalSec = Number(process.env.STATE_SYNC_INTERVAL_SECONDS ?? 900);
const stateRemote = process.env.STATE_REMOTE ?? "";
const watchdogIntervalSec = Number(process.env.WATCHDOG_INTERVAL_SECONDS ?? 60);
const watchdogFailures = Number(process.env.WATCHDOG_FAILURES ?? 4);

const log = (m) => process.stdout.write(`[launcher] ${new Date().toISOString()} ${m}\n`);
const csv = (v) => (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);

function token() {
  const t = process.env.GATEWAY_TOKEN;
  if (t) return t;
  const gen = crypto.randomBytes(16).toString("hex");
  log(`GATEWAY_TOKEN not set; generated ephemeral token: ${gen}`);
  return gen;
}

function buildConfig(authToken) {
  const publicHost = process.env.PUBLIC_HOST ?? "claw--openclaw--q2728nnx75yc.code.run";
  const routerBase = process.env.ROUTER_BASE_URL ?? "https://api.nullroute.lol/v1";
  const routerKey = process.env.ROUTER_API_KEY ?? "local-router";
  const nullrouteKey = process.env.NULLROUTE_KEY ?? "";
  const bearer = nullrouteKey ? `Bearer ${nullrouteKey}` : "Bearer unset";

  const config = {
    gateway: {
      mode: "local",
      bind: "lan",
      port,
      // Northflank terminates TLS at its ingress and forwards X-Forwarded-For.
      // The gateway must trust that proxy range or it rejects proxied requests
      // with 403 proxy_attribution_required. Override with TRUSTED_PROXIES.
      trustedProxies: csv(process.env.TRUSTED_PROXIES || "10.0.0.0/8"),
      controlUi: { allowedOrigins: [`https://${publicHost}`] },
      auth: { mode: "token", token: authToken },
    },
    agents: {
      defaults: {
        model: "router/nullroute-smart",
        workspace: path.join(stateDir, "workspace"),
        heartbeat: { every: process.env.HEARTBEAT_EVERY ?? "30m" },
      },
    },
    models: {
      providers: {
        router: {
          baseUrl: routerBase,
          api: "openai-completions",
          apiKey: routerKey,
          models: [
            { id: "nullroute/smart", name: "NullRoute Smart", contextWindow: 1048576, maxTokens: 32768, input: ["text", "image"] },
            { id: "nullroute/coder", name: "NullRoute Coder", contextWindow: 1048576, maxTokens: 32768, input: ["text", "image"] },
          ],
        },
      },
    },
    mcp: {
      servers: {
        search: { url: "https://api.nullroute.lol/search/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
        memory: { url: "https://api.nullroute.lol/memory/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
        crawl: { url: "https://api.nullroute.lol/crawl/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
        context: { url: "https://api.nullroute.lol/docs/mcp", transport: "streamable-http", headers: { Authorization: bearer } },
      },
    },
  };

  // Optional Telegram channel (only configured when a bot token is supplied).
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
  await mkdir(compileCacheDir, { recursive: true });
  await writeFile(configPath, JSON.stringify(buildConfig(authToken), null, 2));
  log(`config written to ${configPath}`);
}

async function restoreState() {
  if (!stateRemote) return;
  try {
    const { restoreSnapshot } = await import("./state-sync.mjs");
    await restoreSnapshot({ stateDir, remote: stateRemote });
    log("state snapshot restored");
  } catch (e) {
    log(`state restore failed (continuing empty): ${e?.message ?? e}`);
  }
}

async function pushState(reason) {
  if (!stateRemote) return;
  try {
    const { pushSnapshot } = await import("./state-sync.mjs");
    await pushSnapshot({ stateDir, remote: stateRemote });
    log(`state snapshot pushed (${reason})`);
  } catch (e) {
    log(`state push failed (${reason}): ${e?.message ?? e}`);
  }
}

function childEnv() {
  const env = { ...process.env };
  const oldSpace = process.env.MAX_OLD_SPACE_MB ?? "768";
  const semiSpace = process.env.MAX_SEMI_SPACE_MB ?? "16";
  const flags = `--max-old-space-size=${oldSpace} --max-semi-space-size=${semiSpace} --dns-result-order=ipv4first`;
  env.NODE_OPTIONS = env.NODE_OPTIONS ? `${env.NODE_OPTIONS} ${flags}` : flags;
  env.OPENCLAW_STATE_DIR = stateDir;
  env.OPENCLAW_CONFIG_PATH = configPath;
  env.NODE_ENV = "production";
  env.UV_THREADPOOL_SIZE = env.UV_THREADPOOL_SIZE ?? "2";
  // Skip cold V8 compilation on restart (big win on 0.5 vCPU).
  env.NODE_COMPILE_CACHE = compileCacheDir;
  return env;
}

function startGateway() {
  const child = spawn("openclaw", ["gateway", "run", "--port", String(port), "--bind", "lan"], {
    env: childEnv(),
    stdio: "inherit",
  });
  log(`gateway spawned (pid ${child.pid}, port ${port}, bind lan)`);
  return child;
}

let shuttingDown = false;
let child = null;
let restartDelayMs = 5000;
let startedAt = 0;
let probing = false;

// --- crash restart with exponential backoff ---------------------------------
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
  // Healthy lifetime resets the backoff so a later one-off crash restarts fast.
  if (uptime > 90) restartDelayMs = 5000;
  child = null;
  restart(`gateway exited (code=${code}, signal=${signal}, uptime=${uptime}s)`);
}

// --- hang recovery: HTTP watchdog -------------------------------------------
function probeOnce() {
  return new Promise((resolve) => {
    const req = http.get(
      { host: "127.0.0.1", port, path: "/", timeout: 10000 },
      (res) => { res.resume(); resolve(true); },
    );
    req.on("timeout", () => { req.destroy(); resolve(false); });
    req.on("error", () => resolve(false));
  });
}

let failures = 0;
const watchdog = setInterval(async () => {
  if (shuttingDown || probing || !child) return;
  // Don't police during startup: cold start takes minutes on this hardware.
  if (Date.now() - startedAt < 240000) return;
  probing = true;
  const healthy = await probeOnce();
  probing = false;
  if (healthy) { failures = 0; return; }
  failures += 1;
  log(`watchdog: probe failed (${failures}/${watchdogFailures})`);
  if (failures >= watchdogFailures && child) {
    failures = 0;
    log("watchdog: gateway unresponsive - killing child to force restart");
    try { child.kill("SIGKILL"); } catch {}
    // If the child somehow ignores the kill, restart directly.
    setTimeout(() => { if (!shuttingDown && !child) return; onChildExit(null, "SIGKILL"); }, 5000);
  }
}, Math.max(15, watchdogIntervalSec) * 1000);
watchdog.unref();

// --- graceful shutdown ------------------------------------------------------
async function shutdown(reason, code) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`shutting down (${reason})`);
  clearInterval(watchdog);
  if (child && child.exitCode === null && !child.killed) {
    child.kill("SIGTERM");
    await new Promise((r) => {
      const t = setTimeout(r, 8000);
      child.once("exit", () => { clearTimeout(t); r(); });
    });
  }
  await pushState(reason);
  process.exit(code);
}

process.on("SIGTERM", () => void shutdown("SIGTERM", 0));
process.on("SIGINT", () => void shutdown("SIGINT", 0));
process.on("unhandledRejection", (e) => log(`unhandledRejection: ${e?.message ?? e}`));
process.on("uncaughtException", (e) => {
  // Never let the supervisor die: log and keep supervising.
  log(`uncaughtException: ${e?.message ?? e}`);
});

// --- boot -------------------------------------------------------------------
const AUTH_TOKEN = token();
await writeConfig(AUTH_TOKEN);
await restoreState();

const syncTimer = setInterval(() => void pushState("interval"), Math.max(60, syncIntervalSec) * 1000);
syncTimer.unref();

startedAt = Date.now();
child = startGateway();
child.on("exit", onChildExit);

log(`supervisor ready (port ${port}, watchdog every ${watchdogIntervalSec}s)`);
