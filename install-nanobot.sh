#!/usr/bin/env bash
#
# Nanobot • Northflank Automated 1-Click Installer
# ---------------------------------------------------------------------------
# Deploys HKUDS/nanobot (AI Agent Gateway + WebUI) on Northflank's Always-Free
# compute tier (512 MB RAM / 0.2 vCPU) with self-healing, crash-proof
# background restart supervision, boot auto-start, and user-specified
# OpenAI-compatible upstream endpoints.
#
# Usage:
#   bash install-nanobot.sh
#
# ---------------------------------------------------------------------------
set -euo pipefail

if [ -t 1 ]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; CYN=""; NC=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "${GRN}✓${NC}  $*"; }
warn() { printf '%s\n' "${YLW}!${NC}  $*"; }
die()  { printf '%s\n' "${RED}✗${NC}  $*" >&2; exit 1; }

API="https://api.northflank.com/v1"
REPO_URL="${REPO_URL:-https://github.com/therealfreddied/openclaw-northflank}"
POLL_SECONDS=5
POLL_TRIES=60

command -v curl    >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

say ""
say "${CYN}╔══════════════════════════════════════════════════════════════╗${NC}"
say "${CYN}║             Nanobot Northflank Free-Tier Installer           ║${NC}"
say "${CYN}╚══════════════════════════════════════════════════════════════╝${NC}"
say ""

# ---------------------------------------------------------------------------
# 1. Collect Northflank Credentials & Project
# ---------------------------------------------------------------------------
printf 'Enter Northflank API Access Token: '
read -rs NF_TOKEN; echo
[ -n "${NF_TOKEN}" ] || die "Northflank API Token is required."

CURL=(curl -sS -H "Authorization: Bearer ${NF_TOKEN}" -H "Content-Type: application/json")

printf 'Project Name [openclaw]: '
read -r PROJECT; PROJECT="${PROJECT:-openclaw}"

printf 'Region [europe-west-frankfurt]: '
read -r REGION; REGION="${REGION:-europe-west-frankfurt}"

# ---------------------------------------------------------------------------
# 2. Collect Model & Password Configuration
# ---------------------------------------------------------------------------
say ""
say "${CYN}--- Upstream AI Model / Gateway Setup ---${NC}"

printf 'OpenAI-Compatible Base URL (e.g. https://api.openai.com/v1): '
read -r OPENAI_BASE_URL
[ -n "${OPENAI_BASE_URL}" ] || die "Base URL is required."

printf 'API Key: '
read -rs OPENAI_API_KEY; echo
[ -n "${OPENAI_API_KEY}" ] || die "API Key is required."

printf 'Model Name (e.g. gpt-4o, claude-3-7-sonnet, gemini-2.5-flash): '
read -r MODEL_NAME
[ -n "${MODEL_NAME}" ] || die "Model Name is required."

printf 'Custom WebUI Password (leave blank to auto-generate): '
read -rs WEB_TOKEN_INPUT; echo

if [ -z "${WEB_TOKEN_INPUT}" ]; then
  FINAL_PASSWORD=$(python3 -c "import secrets; print(secrets.token_hex(16))")
else
  FINAL_PASSWORD="${WEB_TOKEN_INPUT}"
fi

say ""
say "Deploying Nanobot on Free Tier (512 MB / 0.2 vCPU)..."
say "  Project   : ${PROJECT}"
say "  Region    : ${REGION}"
say "  Model     : ${MODEL_NAME}"
say "  Endpoint  : ${OPENAI_BASE_URL}"
say ""

# ---------------------------------------------------------------------------
# 3. Verify Northflank Auth
# ---------------------------------------------------------------------------
say "Verifying Northflank API Token..."
if ! "${CURL[@]}" "${API}/projects" -o "${WORKDIR}/projects.json"; then
  die "Failed to connect to Northflank API."
fi

if grep -qi '"error"' "${WORKDIR}/projects.json" 2>/dev/null; then
  say "$(cat "${WORKDIR}/projects.json")"
  die "Northflank token was rejected. Please check permissions."
fi
ok "Authentication verified."

# ---------------------------------------------------------------------------
# 4. Create or Reuse Project
# ---------------------------------------------------------------------------
python3 - "${WORKDIR}/projects.json" "${PROJECT}" > "${WORKDIR}/exists.txt" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
target = sys.argv[2]
items = data.get("data", {}).get("projects", []) if isinstance(data, dict) else []
found = any(p.get("id") == target for p in items)
print("yes" if found else "no")
PY

if [ "$(cat "${WORKDIR}/exists.txt")" = "yes" ]; then
  ok "Project '${PROJECT}' exists — reusing."
else
  say "Creating project '${PROJECT}' in ${REGION}..."
  python3 - "${PROJECT}" "${REGION}" > "${WORKDIR}/project.json" <<'PY'
import json, sys
print(json.dumps({"name": sys.argv[1], "region": sys.argv[2], "description": "Nanobot Autonomous Agent"}))
PY
  if ! "${CURL[@]}" -X POST "${API}/projects" -d @"${WORKDIR}/project.json" -o "${WORKDIR}/project-created.json"; then
    die "Project creation failed."
  fi
  ok "Project '${PROJECT}' created."
fi

# ---------------------------------------------------------------------------
# 5. Purge Any Existing Service to Ensure Clean Deployment
# ---------------------------------------------------------------------------
say "Ensuring service slot is ready..."
"${CURL[@]}" -X DELETE "${API}/projects/${PROJECT}/services/nanobot" >/dev/null 2>&1 || true

for _ in $(seq 1 15); do
  s=$("${CURL[@]}" -o /dev/null -w "%{http_code}" "${API}/projects/${PROJECT}/services/nanobot" 2>/dev/null || echo "404")
  if [ "$s" = "404" ]; then
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 6. Create Nanobot Service on Free Plan
# ---------------------------------------------------------------------------
say "Creating Nanobot Combined Service on Free Tier Plan (nf-compute-20)..."

python3 - "${REPO_URL}" > "${WORKDIR}/service.json" <<'PY'
import json, sys
repo = sys.argv[1]
print(json.dumps({
    "name": "nanobot",
    "description": "Nanobot Autonomous AI Agent Gateway",
    "billing": {"deploymentPlan": "nf-compute-20"},
    "deployment": {"instances": 1},
    "vcsData": {
        "projectUrl": repo,
        "projectType": "github",
        "projectBranch": "main"
    },
    "buildSettings": {
        "dockerfile": {
            "buildEngine": "kaniko",
            "dockerFilePath": "/Dockerfile",
            "dockerWorkDir": "/"
        }
    },
    "ports": [
        {"name": "webui", "internalPort": 8765, "protocol": "HTTP", "public": True},
        {"name": "gateway", "internalPort": 18790, "protocol": "HTTP", "public": True}
    ]
}))
PY

if ! "${CURL[@]}" -X POST "${API}/projects/${PROJECT}/services/combined" \
      -d @"${WORKDIR}/service.json" -o "${WORKDIR}/service-created.json"; then
  die "Service creation request failed."
fi

if grep -qi '"error"' "${WORKDIR}/service-created.json" 2>/dev/null; then
  say "$(cat "${WORKDIR}/service-created.json")"
  die "Service creation failed."
fi
ok "Service registered. Kaniko Docker build triggered."

# ---------------------------------------------------------------------------
# 7. Inject Environment Variables for AI Provider, WebUI Password & Auto-Start
# ---------------------------------------------------------------------------
say "Configuring Upstream Model Gateway & WebUI Password..."

python3 - "${OPENAI_BASE_URL}" "${OPENAI_API_KEY}" "${MODEL_NAME}" "${FINAL_PASSWORD}" > "${WORKDIR}/env.json" <<'PY'
import json, sys
api_base, api_key, model, web_token = sys.argv[1:5]

print(json.dumps({
    "deployment": {
        "runtimeEnvironment": {
            "environment": {
                "OPENAI_BASE_URL": api_base,
                "OPENAI_API_KEY": api_key,
                "MODEL_NAME": model,
                "PROVIDER_NAME": "custom",
                "NANOBOT_WEB_TOKEN": web_token,
                "PYTHONUNBUFFERED": "1",
                "MALLOC_ARENA_MAX": "2"
            }
        }
    }
}))
PY

"${CURL[@]}" -X PATCH "${API}/projects/${PROJECT}/services/nanobot" \
  -d @"${WORKDIR}/env.json" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 8. Poll Build & Deployment
# ---------------------------------------------------------------------------
say "Waiting for Docker build and deployment (approx. 2-4 minutes)..."
WEBUI_HOST=""
GATEWAY_HOST=""

for _ in $(seq 1 "${POLL_TRIES}"); do
  if ! "${CURL[@]}" "${API}/projects/${PROJECT}/services/nanobot" -o "${WORKDIR}/svc.json"; then
    printf '.'; sleep "${POLL_SECONDS}"; continue
  fi
  
  FINAL="$(python3 - "${WORKDIR}/svc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
st = d.get("data", {}).get("status", {})
b = (st.get("build") or {}).get("status", "?")
p = (st.get("deployment") or {}).get("status", "")
print(f"{b} {p}".strip())
PY
)"

  if [[ "${FINAL}" == *"SUCCESS COMPLETED"* ]]; then
    ok "Build and deployment finished successfully!"
    break
  elif [[ "${FINAL}" == *"FAILURE"* ]] || [[ "${FINAL}" == *"ERROR"* ]]; then
    die "Build or deployment failed with status: ${FINAL}"
  fi
  printf '.'
  sleep "${POLL_SECONDS}"
done
say ""

# ---------------------------------------------------------------------------
# 9. Extract Domains
# ---------------------------------------------------------------------------
DOMAINS="$(python3 - "${WORKDIR}/svc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ports = d.get("data", {}).get("ports", [])
webui = ""
gw = ""
for p in ports:
    if p.get("name") == "webui":
        webui = p.get("dns", "")
    elif p.get("name") == "gateway":
        gw = p.get("dns", "")
print(f"{webui}|{gw}")
PY
)"

WEBUI_HOST="$(echo "${DOMAINS}" | cut -d'|' -f1)"
GATEWAY_HOST="$(echo "${DOMAINS}" | cut -d'|' -f2)"

say ""
say "${GRN}══════════════════════════════════════════════════════════════${NC}"
say "${GRN}  🎉 NANOBOT IS LIVE ON NORTHFLANK ALWAYS-FREE TIER !        ${NC}"
say "${GRN}══════════════════════════════════════════════════════════════${NC}"
say "  🌐 WebUI Dashboard : https://${WEBUI_HOST}/"
say "  🔌 Gateway Health   : https://${GATEWAY_HOST}/health"
say ""
say "  🔑 WEBUI PASSWORD  : ${FINAL_PASSWORD}"
say ""
say "  ⚙️  Specs           : 512 MB RAM / 0.2 vCPU (Always-Free)"
say "  🤖 Model Provider  : ${OPENAI_BASE_URL}"
say "  🧠 Default Model   : ${MODEL_NAME}"
say ""
say "  🛡️  Self-Healing    : 24/7 in-container supervisor auto-restarts"
say "                       nanobot instantly on any crash or reboot."
say "${GRN}══════════════════════════════════════════════════════════════${NC}"
say ""
