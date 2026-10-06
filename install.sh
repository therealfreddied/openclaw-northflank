#!/usr/bin/env bash
#
# OpenClaw • Northflank installer
# ---------------------------------------------------------------------------
# Fully automated deployment of OpenClaw (optionally + 9router) to Northflank
# with a self-healing supervisor, so the service runs 24/7 and recovers from
# crashes automatically.
#
#   bash install.sh
#
# Asks for: Northflank API key, project name, region, and what to install.
# Requirements: curl, python3.
# ---------------------------------------------------------------------------
set -euo pipefail

if [ -t 1 ]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; CYN=""; NC=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s\n' "${GRN}OK${NC}  $*"; }
warn() { printf '%s\n' "${YLW}!!${NC}  $*"; }
die()  { printf '%s\n' "${RED}XX${NC}  $*" >&2; exit 1; }

API="https://api.northflank.com/v1"
REPO_URL="${REPO_URL:-https://github.com/therealfreddied/openclaw-northflank}"
POLL_SECONDS="${POLL_SECONDS:-6}"
POLL_TRIES="${POLL_TRIES:-100}"

command -v curl    >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# ---------------------------------------------------------------------------
# Collect configuration
# ---------------------------------------------------------------------------
say ""
say "${CYN}OpenClaw - Northflank installer${NC}"
say "----------------------------------------------------------------"

printf 'Northflank API key: '
read -rs NF_TOKEN; echo
[ -n "${NF_TOKEN}" ] || die "API key is required."

CURL=(curl -sS -H "Authorization: Bearer ${NF_TOKEN}" -H "Content-Type: application/json")

printf 'Project name [openclaw]: '
read -r PROJECT; PROJECT="${PROJECT:-openclaw}"

printf 'Region [europe-west-frankfurt]: '
read -r REGION; REGION="${REGION:-europe-west-frankfurt}"

say ""
say "What do you want to install?"
say "  1) OpenClaw only          (512 MB / 0.2 vCPU free tier - recommended)"
say "  2) OpenClaw + 9router     (needs >= 1 GB RAM; two Node runtimes)"
printf 'Choice [1]: '
read -r MODE; MODE="${MODE:-1}"

case "${MODE}" in
  1)
    DOCKERFILE="Dockerfile";           SERVICE_NAME="openclaw"
    PLAN="nf-compute-20";              LABEL="OpenClaw only"
    ;;
  2)
    DOCKERFILE="Dockerfile.combined";  SERVICE_NAME="openclaw-stack"
    PLAN="nf-compute-50";              LABEL="OpenClaw + 9router"
    warn "Mode 2 runs BOTH runtimes in one container; 512 MB is not enough."
    warn "Selected plan ${PLAN} (0.5 vCPU / 1 GB). Use mode 1 on the strict free tier."
    printf 'Continue with %s? [y/N]: ' "${PLAN}"
    read -r CONT
    case "${CONT}" in y|Y) ;; *) die "Aborted." ;; esac
    ;;
  *) die "Invalid choice: ${MODE}" ;;
esac

printf 'Public base URL for allowedOrigins (optional, e.g. https://claw--openclaw--xxxx.code.run): '
read -r PUBLIC_ORIGIN
say ""
say "Deploying: ${LABEL}"
say "  project=${PROJECT}  region=${REGION}  plan=${PLAN}  dockerfile=${DOCKERFILE}"
say ""

# ---------------------------------------------------------------------------
# Verify API key
# ---------------------------------------------------------------------------
say "Verifying API key..."
if ! "${CURL[@]}" "${API}/projects" -o "${WORKDIR}/projects.json"; then
  die "Could not reach the Northflank API."
fi
if grep -qi '"error"' "${WORKDIR}/projects.json" 2>/dev/null; then
  say "$(cat "${WORKDIR}/projects.json")"
  die "API key rejected."
fi
ok "API key accepted."

# ---------------------------------------------------------------------------
# Create or reuse the project
# ---------------------------------------------------------------------------
python3 - "${WORKDIR}/projects.json" "${PROJECT}" > "${WORKDIR}/exists.txt" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
target = sys.argv[2]
items = data.get("projects", data if isinstance(data, list) else [])
found = any(p.get("id") == target for p in items)
print("yes" if found else "no")
PY

if [ "$(cat "${WORKDIR}/exists.txt")" = "yes" ]; then
  warn "Project '${PROJECT}' already exists - reusing."
else
  say "Creating project '${PROJECT}' in ${REGION}..."
  python3 - "${PROJECT}" "${REGION}" > "${WORKDIR}/project.json" <<'PY'
import json, sys
print(json.dumps({"name": sys.argv[1], "region": sys.argv[2], "description": "OpenClaw gateway"}))
PY
  if ! "${CURL[@]}" -X POST "${API}/projects" -d @"${WORKDIR}/project.json" -o "${WORKDIR}/project-created.json"; then
    die "Project creation request failed."
  fi
  if grep -qi '"error"' "${WORKDIR}/project-created.json" 2>/dev/null; then
    say "$(cat "${WORKDIR}/project-created.json")"
    die "Project creation failed."
  fi
  ok "Project '${PROJECT}' created."
fi

# ---------------------------------------------------------------------------
# Create the service
# ---------------------------------------------------------------------------
say "Creating service '${SERVICE_NAME}'..."

python3 - "${SERVICE_NAME}" "${REPO_URL}" "${DOCKERFILE}" "${PLAN}" > "${WORKDIR}/service.json" <<'PY'
import json, sys
name, repo, dockerfile, plan = sys.argv[1:5]
print(json.dumps({
    "name": name,
    "description": "OpenClaw gateway (self-healing)",
    "billing": {"deploymentPlan": plan},
    "deployment": {"instances": 1},
    "vcsData": {"projectUrl": repo, "projectType": "github", "projectBranch": "main"},
    "buildSettings": {"dockerfile": {
        "buildEngine": "kaniko",
        "dockerFilePath": "/" + dockerfile,
        "dockerWorkDir": "/"
    }},
    "ports": [{"name": "claw", "internalPort": 18789, "protocol": "HTTP", "public": True}]
}))
PY

if ! "${CURL[@]}" -X POST "${API}/projects/${PROJECT}/services/combined" \
      -d @"${WORKDIR}/service.json" -o "${WORKDIR}/service-created.json"; then
  die "Service creation request failed."
fi
if grep -qi '"error"' "${WORKDIR}/service-created.json" 2>/dev/null; then
  say "$(cat "${WORKDIR}/service-created.json")"
  die "Service creation failed (delete any existing '${SERVICE_NAME}' service and re-run)."
fi
ok "Service created - build started."

HOST=""
if [ -z "${PUBLIC_ORIGIN}" ]; then
  HOST="$(python3 - "${WORKDIR}/service-created.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for p in d.get("ports", []):
    if p.get("dns"):
        print(p["dns"]); break
PY
)"
fi

# ---------------------------------------------------------------------------
# Wait for build + deploy
# ---------------------------------------------------------------------------
say "Waiting for build and deployment (typically 3-8 minutes)..."
FINAL="unknown"
for _ in $(seq 1 "${POLL_TRIES}"); do
  if ! "${CURL[@]}" "${API}/projects/${PROJECT}/services/${SERVICE_NAME}" -o "${WORKDIR}/svc.json"; then
    printf '.'; sleep "${POLL_SECONDS}"; continue
  fi
  FINAL="$(python3 - "${WORKDIR}/svc.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
st = d.get("status", {})
b = (st.get("build") or {}).get("status", "?")
p = (st.get("deployment") or {}).get("status", "")
print(f"{b} {p}".strip())
PY
)"
  case "${FINAL}" in
    *"SUCCESS COMPLETED"*) ok "Build and deployment complete."; break ;;
    *FAILED*|*ERROR*)       say "$(cat "${WORKDIR}/svc.json")"; die "Build/deploy failed: ${FINAL}" ;;
  esac
  printf '.'
  sleep "${POLL_SECONDS}"
done
say ""

case "${FINAL}" in
  *"SUCCESS COMPLETED"*) ;;
  *) warn "Timed out waiting; check the Northflank dashboard." ;;
esac

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
say ""
say "${GRN}============================================================${NC}"
say "${GRN}  DEPLOYED: ${LABEL}${NC}"
say "${GRN}============================================================${NC}"
if [ -n "${HOST}" ]; then
  say "  OpenClaw URL : https://${HOST}"
fi
say "  Region       : ${REGION}"
say "  Plan         : ${PLAN}"
say ""
say "  Set these service env vars in the Northflank UI (optional):"
say "    GATEWAY_TOKEN   pin the auth token (else one is generated per boot)"
say "    ROUTER_BASE_URL + ROUTER_API_KEY   your model endpoint"
say "    NULLROUTE_KEY   bearer token for the NullRoute MCP suites"
if [ "${MODE}" = "2" ]; then
  say "    GEMINI_KEYS     comma-separated keys for the 9router pool"
fi
say ""
say "  The in-container supervisor restarts the gateway after any crash,"
say "  and Northflank restarts the container on failure - 24/7 operation."
say "${GRN}============================================================${NC}"
say ""
