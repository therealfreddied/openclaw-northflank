#!/usr/bin/env node
/**
 * Northflank launcher for the OpenClaw gateway (single-container, no 9router).
 *
 * Boot order:
 *   1. Generate ~/.openclaw/openclaw.json from env (disk is ephemeral).
 *   2. Optional: restore state snapshot from remote storage.
 *   3. Spawn `openclaw gateway` with tuned V8 heap flags, forward signals.
 *   4. On child exit: restart after 5s (self-healing). On SIGTERM: final push.
 *
 * Required env: GATEWAY_TOKEN
 * Optional env: PUBLIC_HOST, ROUTER_BASE_URL, ROUTER_API_KEY, NULLROUTE_KEY,
 *   MAX_OLD_SPACE_MB, MAX_SEMI_SPACE_MB, MAX_SEMI_SPACE_MB, PORT,
 *   STATE_REMOTE, TURSO_DATABASE_URL, TURSO_AUTH_TOKEN, S3_*, STATE_SYNC_INTERVAL_SECONDS,
 *   TELEGRAM_BOT_TOKEN, TELEGRAM_ALLOW_FROM, HEARTBEAT_EVERY.
 */
import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const stateDir = process.env.OPENCLAW_STATE_DIR ?? "/root/.openclaw";
const configPath = process.env.OPENCLAW_CONFIG_PATH ?? path.join(stateDir, "openclaw.json");
const port = Number(process.env.PORT ?? 18789);
const syncIntervalSec = Number(process.env.STATE_SYNC_INTERVAL_SECONDS ?? 900);
const stateRemote = process.env.STATE_REMOTE ?? "";

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
  const oldSpace = process.env.MAX_OLD_SPACE_MB ?? "320";
  const semiSpace = process.env.MAX_SEMI_SPACE_MB ?? "8";
  const flags = `--max-old-space-size=${oldSpace} --max-semi-space-size=${semiSpace} --dns-result-order=ipv4first`;
  env.NODE_OPTIONS = env.NODE_OPTIONS ? `${env.NODE_OPTIONS} ${flags}` : flags;
  env.OPENCLAW_STATE_DIR = stateDir;
  env.OPENCLAW_CONFIG_PATH = configPath;
  env.NODE_ENV = "production";
  env.UV_THREADPOOL_SIZE = env.UV_THREADPOOL_SIZE ?? "2";
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
let child;

async function shutdown(reason, code) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`shutting down (${reason})`);
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
process.on("uncaughtException", (e) => { log(`uncaughtException: ${e?.message ?? e}`); void shutdown("uncaughtException", 1); });

const AUTH_TOKEN = token();
await writeConfig(AUTH_TOKEN);
await restoreState();

const syncTimer = setInterval(() => void pushState("interval"), Math.max(60, syncIntervalSec) * 1000);
syncTimer.unref();

function onChildExit(code, signal) {
  if (shuttingDown) return;
  log(`gateway exited (code=${code}, signal=${signal}); restarting in 5s`);
  setTimeout(() => { child = startGateway(); child.on("exit", onChildExit); }, 5000);
}

child = startGateway();
child.on("exit", onChildExit);
