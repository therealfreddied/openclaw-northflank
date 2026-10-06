# OpenClaw + 9router Gateway (Northflank Free Tier)

An ultra-optimized, combined deployment of **OpenClaw Gateway** and **9router** designed to run comfortably within Northflank's Always-Free `Micro` tier (512 MB RAM / 0.2 vCPU) without exceeding limits or crashing.

---

## 🚀 Key Features

- **Multi-Key Gemini Pool via 9router**: Automatically cycles through 3–5 Gemini API keys in `round-robin` mode with automated 429 retry fallback.
- **NullRoute 4-Suite Pre-Wired**: Search (Tavily v1.2), Zero-Plaintext Memory, Crawl (Firecrawl v1.0), and Context Docs (Context7 v1.0).
- **RAM Guardrails**: Caps V8 heaps (`9router` = 96MB, `OpenClaw` = 256MB) keeping total container memory at **~180–230 MB RAM** (well below the 512MB limit).
- **Automated Public HTTPS & WSS**: Exposes OpenClaw on port `18789` with WebSocket upgrades enabled.

---

## 📦 1-Click Deploy on Northflank

1. In Northflank, create a **Combined Service** (or **Deployment Service**).
2. Connect this repository: `https://github.com/therealfreddied/openclaw-northflank`.
3. Select **Compute Plan**: `Micro` (0.2 vCPU, 512 MB RAM - Free).
4. Add Port: `18789` (HTTP, Public = Enabled).
5. Add Environment Variables:
   - `GEMINI_KEYS`: `AIzaSyKey1,AIzaSyKey2,AIzaSyKey3` (Comma-separated list of your Gemini keys).
   - `GATEWAY_TOKEN`: `your-secure-password` (Password to login to WebChat).
