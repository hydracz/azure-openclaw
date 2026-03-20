#!/usr/bin/env bash
set -Eeuo pipefail

# One-click Azure Cloud Shell script for provisioning an OpenClaw VM on Azure.
#
# Run from Azure Cloud Shell:
#   bash azure-openclaw-oneclick.sh
#
# Override any variable below with an environment variable before running, for example:
#   export RG_NAME=rg-openclaw-alice
#   export MODEL_DEPLOYMENT_GPT54=gpt-5.4
#   bash azure-openclaw-oneclick.sh

#######################################
# User-tunable defaults
#######################################

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"

RG_NAME="${RG_NAME:-}"
RG_NAME_DEFAULT="${RG_NAME_DEFAULT:-}"
RG_LOCATION="${RG_LOCATION:-southeastasia}"

VM_NAME="${VM_NAME:-}"
VM_LOCATION="${VM_LOCATION:-southeastasia}"
VM_SIZE="${VM_SIZE:-Standard_D2as_v6}"
VM_IMAGE="${VM_IMAGE:-Canonical:ubuntu-24_04-lts:server:latest}"
OS_DISK_GB="${OS_DISK_GB:-128}"
ADMIN_USERNAME="openclaw"
SSH_PORT="${SSH_PORT:-5566}"
SSH_PUBLIC_KEY_PATH="${SSH_PUBLIC_KEY_PATH:-$HOME/.ssh/id_ed25519.pub}"

AI_ACCOUNT_NAME="${AI_ACCOUNT_NAME:-}"
AI_LOCATION="${AI_LOCATION:-eastus2}"
AI_KIND="${AI_KIND:-AIServices}"
AI_SKU="${AI_SKU:-S0}"
AI_API_VERSION="${AI_API_VERSION:-2025-01-01-preview}"
AI_OPENAI_USER_ROLE_NAME="${AI_OPENAI_USER_ROLE_NAME:-Cognitive Services OpenAI User}"
AI_DEVELOPER_ROLE_NAME="${AI_DEVELOPER_ROLE_NAME:-Azure AI Developer}"

MODEL_DEPLOYMENT_GPT54="${MODEL_DEPLOYMENT_GPT54:-gpt-5.4}"
MODEL_API_VERSION_GPT54="${MODEL_API_VERSION_GPT54:-2025-04-01-preview}"

MODEL_DEPLOYMENT_GPT53_CODEX="${MODEL_DEPLOYMENT_GPT53_CODEX:-gpt-5.3-codex}"
MODEL_API_VERSION_GPT53_CODEX="${MODEL_API_VERSION_GPT53_CODEX:-preview}"

OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:main-stable}"
LITELLM_PORT="${LITELLM_PORT:-4000}"

VNET_NAME="${VNET_NAME:-}"
SUBNET_NAME="${SUBNET_NAME:-subnet-openclaw}"
NSG_NAME="${NSG_NAME:-}"
NIC_NAME="${NIC_NAME:-}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-}"
VNET_ADDRESS_PREFIX="${VNET_ADDRESS_PREFIX:-10.42.0.0/16}"
SUBNET_ADDRESS_PREFIX="${SUBNET_ADDRESS_PREFIX:-10.42.1.0/24}"

CLOUD_INIT_WAIT_SECONDS="${CLOUD_INIT_WAIT_SECONDS:-1800}"
CLOUD_INIT_POLL_INTERVAL="${CLOUD_INIT_POLL_INTERVAL:-20}"

#######################################
# Helpers
#######################################

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

cleanup() {
  if [[ -n "${CLOUD_INIT_FILE:-}" && -f "$CLOUD_INIT_FILE" ]]; then
    rm -f "$CLOUD_INIT_FILE"
  fi
  if [[ -n "${BOOTSTRAP_FILE:-}" && -f "$BOOTSTRAP_FILE" ]]; then
    rm -f "$BOOTSTRAP_FILE"
  fi
}

on_error() {
  local exit_code=$?
  log "Script failed at line ${BASH_LINENO[0]} with exit code ${exit_code}."
  exit "$exit_code"
}

trap cleanup EXIT
trap on_error ERR

random_suffix() {
  openssl rand -hex 3
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

sanitize_compact_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'
}

ensure_ssh_key() {
  local private_key_path candidate_private_key candidate_public_key
  private_key_path="${SSH_PUBLIC_KEY_PATH%.pub}"

  if [[ -f "$private_key_path" && -f "$SSH_PUBLIC_KEY_PATH" ]]; then
    log "Reusing SSH key pair: ${private_key_path}"
    return 0
  fi

  if [[ -f "$private_key_path" && ! -f "$SSH_PUBLIC_KEY_PATH" ]]; then
    log "SSH private key found without public key. Rebuilding ${SSH_PUBLIC_KEY_PATH}."
    ssh-keygen -y -f "$private_key_path" >"$SSH_PUBLIC_KEY_PATH"
    chmod 644 "$SSH_PUBLIC_KEY_PATH"
    return 0
  fi

  for candidate_private_key in \
    "$HOME/.ssh/id_ed25519" \
    "$HOME/.ssh/id_ecdsa" \
    "$HOME/.ssh/id_rsa"
  do
    candidate_public_key="${candidate_private_key}.pub"

    if [[ "$candidate_private_key" == "$private_key_path" ]]; then
      continue
    fi

    if [[ -f "$candidate_private_key" && -f "$candidate_public_key" ]]; then
      SSH_PUBLIC_KEY_PATH="$candidate_public_key"
      log "Reusing SSH key pair: ${candidate_private_key}"
      return 0
    fi

    if [[ -f "$candidate_private_key" && ! -f "$candidate_public_key" ]]; then
      ssh-keygen -y -f "$candidate_private_key" >"$candidate_public_key"
      chmod 644 "$candidate_public_key"
      SSH_PUBLIC_KEY_PATH="$candidate_public_key"
      log "Reusing SSH private key and rebuilt public key: ${candidate_private_key}"
      return 0
    fi
  done

  mkdir -p "$(dirname "$private_key_path")"
  log "No reusable SSH key pair found. Generating ${private_key_path}."
  ssh-keygen -t ed25519 -N '' -f "$private_key_path" >/dev/null
}

ensure_subscription() {
  local subscription_list current_id current_index selected_index subscription_count
  subscription_list=()

  if [[ -n "$SUBSCRIPTION_ID" ]]; then
    az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
  else
    current_id="$(az account show --query id -o tsv)"
    while IFS= read -r subscription_line; do
      subscription_list+=("$subscription_line")
    done < <(az account list --all -o json | jq -r '.[] | [.id, .name, .isDefault] | @tsv')
    subscription_count="${#subscription_list[@]}"
    (( subscription_count > 0 )) || fail "No Azure subscriptions found for the current account."

    current_index=1
    for i in "${!subscription_list[@]}"; do
      IFS=$'\t' read -r listed_id listed_name listed_default <<<"${subscription_list[$i]}"
      if [[ "$listed_id" == "$current_id" || "$listed_default" == "true" ]]; then
        current_index=$((i + 1))
        break
      fi
    done

    if [[ -t 0 ]]; then
      log "Available subscriptions:"
      for i in "${!subscription_list[@]}"; do
        IFS=$'\t' read -r listed_id listed_name listed_default <<<"${subscription_list[$i]}"
        marker=""
        if (( i + 1 == current_index )); then
          marker=" [default]"
        fi
        printf '  %2d) %s (%s)%s\n' "$((i + 1))" "$listed_name" "$listed_id" "$marker"
      done

      while true; do
        read -r -p "Select subscription [${current_index}]: " selected_index
        selected_index="${selected_index:-$current_index}"
        if [[ "$selected_index" =~ ^[0-9]+$ ]] && (( selected_index >= 1 && selected_index <= subscription_count )); then
          break
        fi
        log "Please enter a number between 1 and ${subscription_count}."
      done

      IFS=$'\t' read -r SUBSCRIPTION_ID _ _ <<<"${subscription_list[$((selected_index - 1))]}"
      az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
    else
      SUBSCRIPTION_ID="$current_id"
      az account set --subscription "$SUBSCRIPTION_ID" >/dev/null
    fi
  fi

  CURRENT_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
  CURRENT_SUBSCRIPTION_NAME="$(az account show --query name -o tsv)"
  CURRENT_TENANT_ID="$(az account show --query tenantId -o tsv)"
  log "Using subscription: ${CURRENT_SUBSCRIPTION_NAME} (${CURRENT_SUBSCRIPTION_ID})"
}

choose_resource_group_name() {
  local user_input

  if [[ -n "$RG_NAME" ]]; then
    return 0
  fi

  if [[ -z "$RG_NAME_DEFAULT" ]]; then
    RG_NAME_DEFAULT="rg_openclaw_$(random_suffix)"
  fi

  if [[ -t 0 ]]; then
    read -r -p "Resource group name [${RG_NAME_DEFAULT}]: " user_input
    RG_NAME="${user_input:-$RG_NAME_DEFAULT}"
  else
    RG_NAME="$RG_NAME_DEFAULT"
  fi
}

ensure_resource_group() {
  az group create --name "$RG_NAME" --location "$RG_LOCATION" --output none
}

ensure_network() {
  if ! az network vnet show --resource-group "$RG_NAME" --name "$VNET_NAME" >/dev/null 2>&1; then
    az network vnet create \
      --resource-group "$RG_NAME" \
      --name "$VNET_NAME" \
      --location "$VM_LOCATION" \
      --address-prefixes "$VNET_ADDRESS_PREFIX" \
      --subnet-name "$SUBNET_NAME" \
      --subnet-prefixes "$SUBNET_ADDRESS_PREFIX" \
      --output none
  fi

  if ! az network nsg show --resource-group "$RG_NAME" --name "$NSG_NAME" >/dev/null 2>&1; then
    az network nsg create \
      --resource-group "$RG_NAME" \
      --name "$NSG_NAME" \
      --location "$VM_LOCATION" \
      --output none
  fi

  if ! az network nsg rule show --resource-group "$RG_NAME" --nsg-name "$NSG_NAME" --name allow-ssh-${SSH_PORT} >/dev/null 2>&1; then
    az network nsg rule create \
      --resource-group "$RG_NAME" \
      --nsg-name "$NSG_NAME" \
      --name "allow-ssh-${SSH_PORT}" \
      --priority 100 \
      --direction Inbound \
      --access Allow \
      --protocol Tcp \
      --source-address-prefixes Internet \
      --source-port-ranges '*' \
      --destination-address-prefixes '*' \
      --destination-port-ranges "$SSH_PORT" \
      --output none
  fi

  if ! az network public-ip show --resource-group "$RG_NAME" --name "$PUBLIC_IP_NAME" >/dev/null 2>&1; then
    az network public-ip create \
      --resource-group "$RG_NAME" \
      --name "$PUBLIC_IP_NAME" \
      --location "$VM_LOCATION" \
      --sku Standard \
      --allocation-method Static \
      --output none
  fi

  if ! az network nic show --resource-group "$RG_NAME" --name "$NIC_NAME" >/dev/null 2>&1; then
    az network nic create \
      --resource-group "$RG_NAME" \
      --name "$NIC_NAME" \
      --location "$VM_LOCATION" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_NAME" \
      --network-security-group "$NSG_NAME" \
      --public-ip-address "$PUBLIC_IP_NAME" \
      --output none
  fi
}

ensure_ai_account() {
  if ! az cognitiveservices account show --resource-group "$RG_NAME" --name "$AI_ACCOUNT_NAME" >/dev/null 2>&1; then
    az cognitiveservices account create \
      --resource-group "$RG_NAME" \
      --name "$AI_ACCOUNT_NAME" \
      --kind "$AI_KIND" \
      --sku "$AI_SKU" \
      --location "$AI_LOCATION" \
      --yes \
      --output none
  fi

  AI_ENDPOINT="$(az cognitiveservices account show \
    --resource-group "$RG_NAME" \
    --name "$AI_ACCOUNT_NAME" \
    -o json | jq -r '.properties.endpoint // .endpoint // empty')"

  [[ -n "$AI_ENDPOINT" ]] || fail "Unable to resolve endpoint for Azure AI resource ${AI_ACCOUNT_NAME}."
}

build_bootstrap_script() {
  BOOTSTRAP_FILE="$(mktemp)"

  cat >"$BOOTSTRAP_FILE" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -Eeuo pipefail

exec > >(tee -a /var/log/openclaw-bootstrap.log) 2>&1

TARGET_USER="__ADMIN_USERNAME__"
SSH_PORT="__SSH_PORT__"
OPENCLAW_GATEWAY_PORT="__OPENCLAW_GATEWAY_PORT__"
LITELLM_PORT="__LITELLM_PORT__"
LITELLM_IMAGE="__LITELLM_IMAGE__"
AI_API_VERSION="__AI_API_VERSION__"
AI_ENDPOINT="__AI_ENDPOINT__"
AI_ACCOUNT_NAME="__AI_ACCOUNT_NAME__"
AZURE_SUBSCRIPTION_ID="__AZURE_SUBSCRIPTION_ID__"
AZURE_TENANT_ID="__AZURE_TENANT_ID__"
MODEL_ROUTE_GPT54="__MODEL_ROUTE_GPT54__"
MODEL_API_VERSION_GPT54="__MODEL_API_VERSION_GPT54__"
MODEL_ROUTE_GPT53_CODEX="__MODEL_ROUTE_GPT53_CODEX__"
MODEL_API_VERSION_GPT53_CODEX="__MODEL_API_VERSION_GPT53_CODEX__"

log() {
  printf '[bootstrap %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

run_as_user_shell() {
  local command="$*"
  runuser -u "$TARGET_USER" -- bash -lc "cd \"$TARGET_HOME\" && $command"
}

ensure_source_snippet() {
  local file="$1"
  local snippet="$2"
  touch "$file"
  if ! grep -Fq "$snippet" "$file"; then
    printf '\n%s\n' "$snippet" >>"$file"
  fi
}

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" ]] || fail "Cannot resolve home directory for $TARGET_USER"

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"

STATE_DIR="$TARGET_HOME/.openclaw"
WORKSPACE_DIR="$STATE_DIR/workspace"
ENV_FILE="$STATE_DIR/gateway.env"
SUMMARY_FILE="$TARGET_HOME/openclaw-ready.txt"
LITELLM_CONFIG_FILE="$STATE_DIR/litellm-config.yaml"

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"
chown -R "$TARGET_UID:$TARGET_GID" "$STATE_DIR"
chmod 700 "$STATE_DIR" "$WORKSPACE_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  jq \
  openssl \
  python3 \
  python3-pip \
  build-essential \
  procps \
  file \
  uidmap \
  gpg \
  iptables \
  lsb-release

apt-get remove -y \
  docker.io \
  docker-compose \
  docker-compose-v2 \
  docker-doc \
  podman-docker \
  containerd \
  runc || true

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<EOF_DOCKER_SOURCE
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER_SOURCE

apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker
usermod -aG docker "$TARGET_USER"

cat >/usr/local/sbin/openclaw-ssh-port-redirect.sh <<EOF_REDIRECT
#!/usr/bin/env bash
set -Eeuo pipefail
iptables -t nat -C PREROUTING -p tcp --dport $SSH_PORT -j REDIRECT --to-ports 22 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport $SSH_PORT -j REDIRECT --to-ports 22
EOF_REDIRECT
chmod 755 /usr/local/sbin/openclaw-ssh-port-redirect.sh

cat >/etc/systemd/system/openclaw-ssh-port-redirect.service <<EOF_REDIRECT_UNIT
[Unit]
Description=Redirect TCP $SSH_PORT to SSH 22 for OpenClaw VM access
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openclaw-ssh-port-redirect.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_REDIRECT_UNIT

systemctl daemon-reload
systemctl enable --now openclaw-ssh-port-redirect.service


cat >/usr/local/sbin/openclaw-litellm-start.sh <<'EOF_LITELLM_START'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/home/__ADMIN_USERNAME__/.openclaw/gateway.env"
CONFIG_FILE="/home/__ADMIN_USERNAME__/.openclaw/litellm-config.yaml"
CONTAINER_NAME="litellm"
IMAGE="__LITELLM_IMAGE__"
PORT="__LITELLM_PORT__"

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker start "$CONTAINER_NAME"
  exit 0
fi

docker pull "$IMAGE" || true
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p 127.0.0.1:${PORT}:4000 \
  --env-file "$ENV_FILE" \
  -v "$CONFIG_FILE:/app/config.yaml:ro" \
  "$IMAGE" \
  --config /app/config.yaml --port 4000
EOF_LITELLM_START
chmod 755 /usr/local/sbin/openclaw-litellm-start.sh

cat >/etc/systemd/system/litellm.service <<EOF_LITELLM_UNIT
[Unit]
Description=LiteLLM Docker container
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/openclaw-litellm-start.sh
ExecStop=/usr/bin/docker stop litellm

[Install]
WantedBy=multi-user.target
EOF_LITELLM_UNIT

sed -i "s|__ADMIN_USERNAME__|$TARGET_USER|g" /usr/local/sbin/openclaw-litellm-start.sh
sed -i "s|__LITELLM_IMAGE__|$LITELLM_IMAGE|g" /usr/local/sbin/openclaw-litellm-start.sh
sed -i "s|__LITELLM_PORT__|$LITELLM_PORT|g" /usr/local/sbin/openclaw-litellm-start.sh

systemctl daemon-reload

LITELLM_API_KEY="$(openssl rand -hex 32)"
OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
BREW_PREFIX="/home/linuxbrew/.linuxbrew"

AZURE_CLIENT_ID=""
AZURE_PRINCIPAL_ID=""
for _ in $(seq 1 30); do
  if IDENTITY_INFO="$(curl -fsS -H Metadata:true 'http://169.254.169.254/metadata/identity/info?api-version=2019-11-01' 2>/dev/null)"; then
    AZURE_CLIENT_ID="$(printf '%s' "$IDENTITY_INFO" | jq -r '.client_id // empty')"
    AZURE_PRINCIPAL_ID="$(printf '%s' "$IDENTITY_INFO" | jq -r '.object_id // empty')"
    if [[ -n "$AZURE_CLIENT_ID" && -n "$AZURE_PRINCIPAL_ID" ]]; then
      break
    fi
  fi
  sleep 2
done

cat >"$ENV_FILE" <<EOF_ENV
OPENCLAW_STATE_DIR=$STATE_DIR
OPENCLAW_CONFIG_PATH=$STATE_DIR/openclaw.json
OPENCLAW_GATEWAY_PORT=$OPENCLAW_GATEWAY_PORT
OPENCLAW_GATEWAY_BIND=loopback
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN
OPENCLAW_WORKSPACE_DIR=$WORKSPACE_DIR
LITELLM_API_KEY=$LITELLM_API_KEY
LITELLM_MASTER_KEY=$LITELLM_API_KEY
LITELLM_PROXY_URL=http://127.0.0.1:$LITELLM_PORT
AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID
AZURE_TENANT_ID=$AZURE_TENANT_ID
AZURE_CLIENT_ID=$AZURE_CLIENT_ID
AZURE_PRINCIPAL_ID=$AZURE_PRINCIPAL_ID
AZURE_OPENAI_ACCOUNT_NAME=$AI_ACCOUNT_NAME
AZURE_OPENAI_ENDPOINT=$AI_ENDPOINT
AZURE_OPENAI_API_VERSION=$AI_API_VERSION
AZURE_OPENAI_DEPLOYMENT_GPT54=$MODEL_ROUTE_GPT54
AZURE_OPENAI_DEPLOYMENT_GPT53_CODEX=$MODEL_ROUTE_GPT53_CODEX
AZURE_API_BASE=$AI_ENDPOINT
AZURE_API_VERSION=$AI_API_VERSION
PATH=$TARGET_HOME/.npm-global/bin:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
EOF_ENV

chown "$TARGET_UID:$TARGET_GID" "$ENV_FILE"
chmod 600 "$ENV_FILE"

SOURCE_SNIPPET='if [ -f "$HOME/.openclaw/gateway.env" ]; then set -a; . "$HOME/.openclaw/gateway.env"; set +a; fi'
ensure_source_snippet "$TARGET_HOME/.bashrc" "$SOURCE_SNIPPET"
ensure_source_snippet "$TARGET_HOME/.profile" "$SOURCE_SNIPPET"
chown "$TARGET_UID:$TARGET_GID" "$TARGET_HOME/.bashrc" "$TARGET_HOME/.profile"

if [[ ! -x "$BREW_PREFIX/bin/brew" ]]; then
  run_as_user_shell 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
fi

run_as_user_shell 'set -a; . "$HOME/.openclaw/gateway.env"; set +a; eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"; brew install gcc'

run_as_user_shell 'set -a; . "$HOME/.openclaw/gateway.env"; set +a; curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-prompt --no-onboard --verify'

OPENCLAW_BIN="$(runuser -u "$TARGET_USER" -- bash -lc 'set -a; . "$HOME/.openclaw/gateway.env"; set +a; command -v openclaw')"
[[ -n "$OPENCLAW_BIN" ]] || fail "openclaw binary not found after installation"

cat >"$LITELLM_CONFIG_FILE" <<EOF_LITELLM
general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  drop_params: true
  enable_preview_features: true
  enable_azure_ad_token_refresh: true

model_list:
  - model_name: $MODEL_ROUTE_GPT54
    litellm_params:
      model: azure/$MODEL_ROUTE_GPT54
      api_base: os.environ/AZURE_API_BASE
      api_version: "$MODEL_API_VERSION_GPT54"
  - model_name: $MODEL_ROUTE_GPT53_CODEX
    litellm_params:
      model: azure/$MODEL_ROUTE_GPT53_CODEX
      api_base: os.environ/AZURE_API_BASE
      api_version: "$MODEL_API_VERSION_GPT53_CODEX"
EOF_LITELLM

chown "$TARGET_UID:$TARGET_GID" "$LITELLM_CONFIG_FILE"
chmod 600 "$LITELLM_CONFIG_FILE"

export OPENCLAW_CONFIG_PATH="$STATE_DIR/openclaw.json"
export OPENCLAW_GATEWAY_PORT
export MODEL_ROUTE_GPT54
export MODEL_ROUTE_GPT53_CODEX

python3 <<'EOF_PATCH'
import json
import os
from pathlib import Path

config_path = Path(os.environ["OPENCLAW_CONFIG_PATH"])
config_path.parent.mkdir(parents=True, exist_ok=True)

if config_path.exists():
    try:
        config = json.loads(config_path.read_text())
    except json.JSONDecodeError:
        config = {}
else:
    config = {}

config.setdefault("secrets", {})
config["secrets"].setdefault("providers", {})
config["secrets"]["providers"].setdefault("default", {"source": "env"})
config["secrets"].setdefault("defaults", {})
config["secrets"]["defaults"]["env"] = "default"

config.setdefault("gateway", {})
config["gateway"]["mode"] = "local"
config["gateway"]["port"] = int(os.environ["OPENCLAW_GATEWAY_PORT"])
config["gateway"]["bind"] = "loopback"
config["gateway"]["auth"] = {
    "mode": "token",
    "token": {"source": "env", "provider": "default", "id": "OPENCLAW_GATEWAY_TOKEN"},
}

config.setdefault("models", {})
config["models"].setdefault("providers", {})

litellm_provider = config["models"]["providers"].get("litellm", {})
litellm_provider["baseUrl"] = "http://127.0.0.1:4000"
litellm_provider["api"] = "openai-completions"
litellm_provider["apiKey"] = "${LITELLM_API_KEY}"
litellm_provider["models"] = [
    {
        "id": os.environ["MODEL_ROUTE_GPT54"],
        "name": "GPT-5.4",
        "reasoning": True,
        "input": ["text", "image"],
        "contextWindow": 400000,
        "maxTokens": 32768,
    },
    {
        "id": os.environ["MODEL_ROUTE_GPT53_CODEX"],
        "name": "GPT-5.3 Codex",
        "reasoning": True,
        "input": ["text"],
        "contextWindow": 400000,
        "maxTokens": 32768,
    },
]
config["models"]["providers"]["litellm"] = litellm_provider

config.setdefault("agents", {})
config["agents"].setdefault("defaults", {})
config["agents"]["defaults"]["model"] = {"primary": f"litellm/{os.environ['MODEL_ROUTE_GPT54']}"}

config_path.write_text(json.dumps(config, indent=2) + "\n")
os.chmod(config_path, 0o600)
EOF_PATCH

docker rm -f litellm >/dev/null 2>&1 || true
systemctl enable --now litellm.service

for _ in $(seq 1 30); do
  if curl -fsS -H "Authorization: Bearer $LITELLM_API_KEY" "http://127.0.0.1:$LITELLM_PORT/v1/models" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

cat >"$SUMMARY_FILE" <<EOF_SUMMARY
OpenClaw bootstrap complete.

User: $TARGET_USER
Env file: $ENV_FILE
OpenClaw config: $STATE_DIR/openclaw.json
LiteLLM config: $LITELLM_CONFIG_FILE
LiteLLM endpoint: http://127.0.0.1:$LITELLM_PORT
LiteLLM API key env var: LITELLM_API_KEY
OpenClaw service deployment: manual
Configured gateway port: $OPENCLAW_GATEWAY_PORT
SSH port: $SSH_PORT -> 22
Create these Azure AI Foundry deployments manually: $MODEL_ROUTE_GPT54, $MODEL_ROUTE_GPT53_CODEX
Azure OpenAI endpoint used by LiteLLM: $AI_ENDPOINT
Managed identity client ID: $AZURE_CLIENT_ID
Managed identity principal ID: $AZURE_PRINCIPAL_ID
Tenant ID: $AZURE_TENANT_ID

Run after login:
  source ~/.openclaw/gateway.env
  systemctl status litellm --no-pager
  docker ps --filter name=litellm

安装成功
EOF_SUMMARY

chown "$TARGET_UID:$TARGET_GID" "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

log "Bootstrap finished."
BOOTSTRAP

  python3 - "$BOOTSTRAP_FILE" \
    "$ADMIN_USERNAME" \
    "$SSH_PORT" \
    "$OPENCLAW_GATEWAY_PORT" \
    "$LITELLM_PORT" \
    "$LITELLM_IMAGE" \
    "$AI_API_VERSION" \
    "$AI_ENDPOINT" \
    "$AI_ACCOUNT_NAME" \
    "$CURRENT_SUBSCRIPTION_ID" \
    "$CURRENT_TENANT_ID" \
    "$MODEL_DEPLOYMENT_GPT54" \
    "$MODEL_API_VERSION_GPT54" \
    "$MODEL_DEPLOYMENT_GPT53_CODEX" \
    "$MODEL_API_VERSION_GPT53_CODEX" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

replacements = {
    '__ADMIN_USERNAME__': sys.argv[2],
    '__SSH_PORT__': sys.argv[3],
    '__OPENCLAW_GATEWAY_PORT__': sys.argv[4],
    '__LITELLM_PORT__': sys.argv[5],
    '__LITELLM_IMAGE__': sys.argv[6],
    '__AI_API_VERSION__': sys.argv[7],
    '__AI_ENDPOINT__': sys.argv[8],
    '__AI_ACCOUNT_NAME__': sys.argv[9],
    '__AZURE_SUBSCRIPTION_ID__': sys.argv[10],
    '__AZURE_TENANT_ID__': sys.argv[11],
    '__MODEL_ROUTE_GPT54__': sys.argv[12],
    '__MODEL_API_VERSION_GPT54__': sys.argv[13],
    '__MODEL_ROUTE_GPT53_CODEX__': sys.argv[14],
    '__MODEL_API_VERSION_GPT53_CODEX__': sys.argv[15],
}

for key, value in replacements.items():
    text = text.replace(key, value)

path.write_text(text)
PY
}

build_cloud_init() {
  local bootstrap_b64
  bootstrap_b64="$(base64 < "$BOOTSTRAP_FILE" | tr -d '\n')"
  CLOUD_INIT_FILE="$(mktemp)"

  cat >"$CLOUD_INIT_FILE" <<CLOUDINIT
#cloud-config
package_update: false
package_upgrade: false
write_files:
  - path: /usr/local/sbin/openclaw-bootstrap.sh
    permissions: '0755'
    owner: root:root
    encoding: b64
    content: ${bootstrap_b64}
runcmd:
  - [ bash, -lc, /usr/local/sbin/openclaw-bootstrap.sh ]
final_message: "OpenClaw cloud-init finished."
CLOUDINIT
}

ensure_vm() {
  if ! az vm show --resource-group "$RG_NAME" --name "$VM_NAME" >/dev/null 2>&1; then
    az vm create \
      --resource-group "$RG_NAME" \
      --name "$VM_NAME" \
      --location "$VM_LOCATION" \
      --nics "$NIC_NAME" \
      --image "$VM_IMAGE" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USERNAME" \
        --assign-identity \
      --ssh-key-values "$SSH_PUBLIC_KEY_PATH" \
      --os-disk-size-gb "$OS_DISK_GB" \
      --custom-data "$CLOUD_INIT_FILE" \
      --output none
  fi
}

ensure_vm_identity_and_role() {
  az vm identity assign --resource-group "$RG_NAME" --name "$VM_NAME" --output none

  local ai_resource_id assignment_count role_name
  VM_IDENTITY_PRINCIPAL_ID="$(az vm show --resource-group "$RG_NAME" --name "$VM_NAME" --query identity.principalId -o tsv)"
  ai_resource_id="$(az cognitiveservices account show --resource-group "$RG_NAME" --name "$AI_ACCOUNT_NAME" --query id -o tsv)"

  for role_name in "$AI_OPENAI_USER_ROLE_NAME" "$AI_DEVELOPER_ROLE_NAME"; do
    assignment_count="$(az role assignment list \
      --assignee-object-id "$VM_IDENTITY_PRINCIPAL_ID" \
      --scope "$ai_resource_id" \
      --query "[?roleDefinitionName=='${role_name}'] | length(@)" \
      -o tsv)"

    if [[ "$assignment_count" == "0" ]]; then
      az role assignment create \
        --assignee-object-id "$VM_IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "$role_name" \
        --scope "$ai_resource_id" \
        --output none
    fi
  done
}

sync_vm_identity_metadata() {
  local vm_identity_client_id vm_identity_principal_id

  vm_identity_principal_id="$(az vm show \
    --resource-group "$RG_NAME" \
    --name "$VM_NAME" \
    --query identity.principalId -o tsv)"

  vm_identity_client_id="$(az ad sp show \
    --id "$vm_identity_principal_id" \
    --query appId -o tsv 2>/dev/null || true)"

  az vm run-command invoke \
    --resource-group "$RG_NAME" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts \
      "ENV_FILE=/home/${ADMIN_USERNAME}/.openclaw/gateway.env" \
      "SUMMARY_FILE=/home/${ADMIN_USERNAME}/openclaw-ready.txt" \
      "grep -q '^AZURE_CLIENT_ID=' \"\$ENV_FILE\" && sed -i 's/^AZURE_CLIENT_ID=.*/AZURE_CLIENT_ID=${vm_identity_client_id}/' \"\$ENV_FILE\" || printf 'AZURE_CLIENT_ID=${vm_identity_client_id}\\n' >>\"\$ENV_FILE\"" \
      "grep -q '^AZURE_PRINCIPAL_ID=' \"\$ENV_FILE\" && sed -i 's/^AZURE_PRINCIPAL_ID=.*/AZURE_PRINCIPAL_ID=${vm_identity_principal_id}/' \"\$ENV_FILE\" || printf 'AZURE_PRINCIPAL_ID=${vm_identity_principal_id}\\n' >>\"\$ENV_FILE\"" \
      "if [ -f \"\$SUMMARY_FILE\" ]; then sed -i 's/^Managed identity client ID: .*/Managed identity client ID: ${vm_identity_client_id}/' \"\$SUMMARY_FILE\"; sed -i 's/^Managed identity principal ID: .*/Managed identity principal ID: ${vm_identity_principal_id}/' \"\$SUMMARY_FILE\"; fi" \
      --output none
}

wait_for_cloud_init() {
  local deadline now rc output
  deadline=$(( $(date +%s) + CLOUD_INIT_WAIT_SECONDS ))

  while true; do
    now=$(date +%s)
    if (( now > deadline )); then
      fail "Timed out waiting for cloud-init to finish. Check /var/log/openclaw-bootstrap.log on the VM."
    fi

    set +e
    output="$(az vm run-command invoke \
      --resource-group "$RG_NAME" \
      --name "$VM_NAME" \
      --command-id RunShellScript \
      --scripts 'if [ -f /var/lib/cloud/instance/boot-finished ]; then echo ready; else exit 1; fi' \
      --query 'value[0].message' -o tsv 2>/dev/null)"
    rc=$?
    set -e

    if [[ $rc -eq 0 && "$output" == *ready* ]]; then
      return 0
    fi

    sleep "$CLOUD_INIT_POLL_INTERVAL"
  done
}

print_summary() {
  local public_ip summary
  public_ip="$(az network public-ip show --resource-group "$RG_NAME" --name "$PUBLIC_IP_NAME" --query ipAddress -o tsv)"
  summary="$(az vm run-command invoke \
    --resource-group "$RG_NAME" \
    --name "$VM_NAME" \
    --command-id RunShellScript \
    --scripts "cat /home/${ADMIN_USERNAME}/openclaw-ready.txt" \
    --query 'value[0].message' -o tsv 2>/dev/null || true)"

  cat <<EOF

Provisioning complete.

Resource group: ${RG_NAME}
VM name: ${VM_NAME}
VM region: ${VM_LOCATION}
Azure AI account: ${AI_ACCOUNT_NAME}
Azure AI region: ${AI_LOCATION}
Public IP: ${public_ip}
SSH command: ssh -p ${SSH_PORT} ${ADMIN_USERNAME}@${public_ip}

VM summary:
${summary}
EOF
}

#######################################
# Main
#######################################

require_cmd az
require_cmd jq
require_cmd openssl
require_cmd ssh-keygen
require_cmd base64

az account show >/dev/null 2>&1 || fail "Azure CLI is not logged in. Run az login first."

ensure_subscription
ensure_ssh_key
choose_resource_group_name

RG_NAME="$(sanitize_name "$RG_NAME")"
[[ -n "$RG_NAME" ]] || fail "RG_NAME is empty after sanitization"

COMPACT_RG_NAME="$(sanitize_compact_name "$RG_NAME")"
RESOURCE_NAME_SUFFIX="${RG_NAME//_/-}"
SHORT_BASE="${COMPACT_RG_NAME:0:14}"
[[ -n "$SHORT_BASE" ]] || SHORT_BASE="openclaw"

VM_NAME="${VM_NAME:-vm-${RESOURCE_NAME_SUFFIX}}"
VNET_NAME="${VNET_NAME:-vnet-${RESOURCE_NAME_SUFFIX}}"
NSG_NAME="${NSG_NAME:-nsg-${RESOURCE_NAME_SUFFIX}}"
NIC_NAME="${NIC_NAME:-nic-${RESOURCE_NAME_SUFFIX}}"
PUBLIC_IP_NAME="${PUBLIC_IP_NAME:-pip-${RESOURCE_NAME_SUFFIX}}"
AI_ACCOUNT_NAME="${AI_ACCOUNT_NAME:-ai${SHORT_BASE}$(random_suffix)}"
AI_ACCOUNT_NAME="${AI_ACCOUNT_NAME:0:24}"

ensure_resource_group
ensure_network
ensure_ai_account

log "Resource group: ${RG_NAME}"
log "VM: ${VM_NAME} (${VM_LOCATION})"
log "Azure AI resource: ${AI_ACCOUNT_NAME} (${AI_LOCATION}, kind=${AI_KIND})"
log "Azure AI endpoint: ${AI_ENDPOINT}"
log "Model deployments are not created by this script. Create them later in Azure AI Foundry Portal: ${MODEL_DEPLOYMENT_GPT54}, ${MODEL_DEPLOYMENT_GPT53_CODEX}"

build_bootstrap_script
build_cloud_init

ensure_vm
ensure_vm_identity_and_role

log "Waiting for cloud-init bootstrap to finish. This can take several minutes."
wait_for_cloud_init
sync_vm_identity_metadata
print_summary
