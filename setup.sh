#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")" && pwd)
source "$ROOT/scripts/present.sh"
DEMO_DIR=${DEMO_DIR:-"$ROOT/.demo"}
COMMIT=4de694355985e9d06dc92ad1adfa64d96d32f19e
CLI_VERSION=v1.0.0-rc3
SNAPSHOT_LOCATION=${SNAPSHOT_LOCATION:-gs://ate-snapshots/anthropic-managed-agents/}
MODE=${1:-setup}

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
trap 'printf "Setup stopped at line %s. Fix the error and rerun; existing resources are preserved.\n" "$LINENO" >&2' ERR

case "$MODE" in
  setup|--tools-only|--ate-only|--render) ;;
  --help)
    printf '%s\n' 'Usage: bash setup.sh [--tools-only|--ate-only|--render]' \
      'Default: install tools and prepare a dedicated Kind cluster.' \
      'Required for setup: ANTHROPIC_ENVIRONMENT_ID, ANTHROPIC_ENVIRONMENT_KEY.' \
      '--ate-only installs the latest released kubectl ate plugin without changing the cluster (requires curl and jq).' \
      '--render only generates non-secret configuration (requires jq, Ruby, and environment ID).'
    exit 0 ;;
  *) fail "Unknown option: $MODE" ;;
esac
[[ $# -le 1 ]] || fail 'Expected at most one option.'
[[ "$DEMO_DIR" == /* ]] || fail 'DEMO_DIR must be an absolute path.'
mkdir -p "$DEMO_DIR/bin"
chmod 700 "$DEMO_DIR" "$DEMO_DIR/bin"
export PATH="$DEMO_DIR/bin:$PATH"
export KUBECONFIG="$DEMO_DIR/kubeconfig"

install_ate() {
  local architecture release asset download_dir expected actual
  [[ $(uname -s) == Darwin ]] || fail 'The kubectl ate installer targets macOS.'
  command -v curl >/dev/null || fail 'curl is required to install kubectl ate.'
  command -v jq >/dev/null || fail 'jq is required to install kubectl ate.'
  case $(uname -m) in
    arm64|aarch64) architecture=arm64 ;;
    x86_64) architecture=amd64 ;;
    *) fail 'Unsupported architecture for kubectl ate.' ;;
  esac
  download_dir=$(mktemp -d "$DEMO_DIR/ate-install.XXXXXX")
  curl -fsSL https://api.github.com/repos/agent-substrate/substrate/releases/latest \
    -o "$download_dir/release.json"
  release=$(jq -er '.tag_name' "$download_dir/release.json")
  [[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Unexpected latest Substrate release tag.'
  asset="kubectl-ate-darwin-$architecture"
  printf 'Installing kubectl ate %s (%s)\n' "$release" "$architecture"
  curl -fsSL "https://github.com/agent-substrate/substrate/releases/download/$release/$asset" \
    -o "$download_dir/$asset"
  curl -fsSL "https://github.com/agent-substrate/substrate/releases/download/$release/$asset.sha256" \
    -o "$download_dir/$asset.sha256"
  expected=$(awk '{print $1}' "$download_dir/$asset.sha256")
  [[ "$expected" =~ ^[a-f0-9]{64}$ ]] || fail 'Invalid kubectl ate checksum file.'
  actual=$(shasum -a 256 "$download_dir/$asset" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || fail 'kubectl ate checksum mismatch; existing plugin preserved.'
  install -m 0755 "$download_dir/$asset" "$DEMO_DIR/bin/kubectl-ate"
  "$DEMO_DIR/bin/kubectl-ate" --version
  rm -rf "$download_dir"
}

if [[ "$MODE" == --ate-only ]]; then
  install_ate
  exit 0
fi

if [[ "$MODE" != --render ]]; then
  [[ $(uname -s) == Darwin ]] || fail 'This tool installer targets macOS. See README.md for Linux prerequisites.'
  command -v brew >/dev/null || fail 'Install Homebrew first: https://brew.sh'
  for dependency in kind kubectl helm jq; do
    if ! command -v "$dependency" >/dev/null; then brew install "$dependency"; fi
  done
  if ! command -v ant >/dev/null; then brew install anthropics/tap/ant; fi
  if ! command -v docker >/dev/null; then
    brew install --cask docker
    fail 'Open Docker Desktop, finish its first-run setup, then rerun this script.'
  fi
  install_ate
  curl -fsSL "https://raw.githubusercontent.com/kagent-dev/kagent/$COMMIT/scripts/get-kagent" \
    -o "$DEMO_DIR/get-kagent.sh"
  USE_SUDO=false DEBUG=false KAGENT_INSTALL_DIR="$DEMO_DIR/bin" \
    bash "$DEMO_DIR/get-kagent.sh" --version "$CLI_VERSION"
  kagent version
  ant --version
  if [[ "$MODE" == --tools-only ]]; then
    printf '\nTools ready. Run ant auth login and create a self-hosted environment before setup.\n'
    exit 0
  fi
fi

command -v jq >/dev/null || fail 'jq is required; run bash setup.sh --tools-only first.'
command -v ruby >/dev/null || fail 'Ruby is required to render YAML configuration.'
[[ ${ANTHROPIC_ENVIRONMENT_ID:-} =~ ^env_[A-Za-z0-9_-]+$ ]] || fail 'Set ANTHROPIC_ENVIRONMENT_ID to your self-hosted environment ID.'
[[ "$SNAPSHOT_LOCATION" =~ ^gs://[^[:space:]]+/$ ]] || fail 'SNAPSHOT_LOCATION must be a gs:// URI ending in / for this pinned release.'

ruby -ryaml -e '
  values = YAML.load_file(ARGV.fetch(0))
  entry = values.fetch("controller").fetch("env").find { |item| item.fetch("name") == "EXPERIMENTAL_ANTHROPIC_SELF_HOSTED_SANDBOXES_ENVIRONMENT_ID" }
  abort "Missing environment ID configuration" unless entry
  entry["value"] = ARGV.fetch(1)
  puts YAML.dump(values)
' "$ROOT/manifests/kagent-values.yaml" "$ANTHROPIC_ENVIRONMENT_ID" > "$DEMO_DIR/kagent-values.yaml"
ruby -ryaml -e '
  config = YAML.load_file(ARGV.fetch(0))
  config.fetch("install").fetch("kagent")["valuesFiles"] = [ARGV.fetch(1)]
  puts YAML.dump(config)
' "$ROOT/manifests/kagent-install-config.yaml" "$DEMO_DIR/kagent-values.yaml" > "$DEMO_DIR/kagent-install-config.yaml"
ruby -ryaml -e '
  template = YAML.load_file(ARGV.fetch(0))
  template.fetch("spec").fetch("substrate").fetch("snapshotPolicy")["location"] = ARGV.fetch(1)
  puts YAML.dump(template)
' "$ROOT/manifests/sandbox-template.yaml" "$SNAPSHOT_LOCATION" > "$DEMO_DIR/sandbox-template.yaml"

USER_ID=$(printf '%s' 'kagent:anthropic-self-hosted-sandboxes' | base64 | tr '+/' '-_' | tr -d '=\n')
ENVIRONMENT_SUFFIX=$(printf '%s' "$ANTHROPIC_ENVIRONMENT_ID" | base64 | tr '+/' '-_' | tr -d '=\n')
USER_ID="$USER_ID.$ENVIRONMENT_SUFFIX"
printf 'export KUBECONFIG=%q\nexport PATH=%q:"$PATH"\nexport ANTHROPIC_ENVIRONMENT_ID=%q\nexport USER_ID=%q\n' \
  "$KUBECONFIG" "$DEMO_DIR/bin" "$ANTHROPIC_ENVIRONMENT_ID" "$USER_ID" > "$DEMO_DIR/demo.env"

if [[ "$MODE" == --render ]]; then
  printf 'Non-secret configuration rendered in %s\n' "$DEMO_DIR"
  exit 0
fi

[[ -n ${ANTHROPIC_ENVIRONMENT_KEY:-} ]] || fail 'Set ANTHROPIC_ENVIRONMENT_KEY; do not put it in a tracked file.'
docker info >/dev/null 2>&1 || fail 'Start your Docker-compatible engine, then rerun setup.'
if kind get clusters | grep -Fxq kagent-substrate-demo; then
  kind export kubeconfig --name kagent-substrate-demo --kubeconfig "$KUBECONFIG"
else
  kind create cluster --name kagent-substrate-demo --image kindest/node:v1.35.0 \
    --config "$ROOT/manifests/kind-config.yaml" --kubeconfig "$KUBECONFIG"
fi
[[ $(kubectl config current-context) == kind-kagent-substrate-demo ]] || fail 'Unexpected Kubernetes context.'
apply_manifest "$ROOT/manifests/namespace.yaml"
export ANTHROPIC_ENVIRONMENT_KEY
printf '\nCreating Secret kagent/anthropic-environment; environment-key contents are redacted.\n' >&2
show_command kubectl apply --server-side --field-manager=substrate-demo -f -
jq -n '{apiVersion: "v1", kind: "Secret", metadata: {name: "anthropic-environment", namespace: "kagent"},
  type: "Opaque", data: {"environment-key": (env.ANTHROPIC_ENVIRONMENT_KEY | @base64)}}' |
  kubectl apply --server-side --field-manager=substrate-demo -f -
unset ANTHROPIC_ENVIRONMENT_KEY

printf '\nInstalling the blog alpha and its bundled infrastructure. This can take several minutes.\n'
show_manifest "$DEMO_DIR/kagent-values.yaml"
run_command env OPENAI_API_KEY="unset" kagent --config "$DEMO_DIR/kagent-install-config.yaml" install
run_command kubectl rollout status -n kagent deployment/kagent-controller --timeout=15m
GLOBAL_POLICY=$(run_command kubectl ate get access-policy --global -o json 2>&1 || true)
if [[ "$GLOBAL_POLICY" == *'global has no access policy'* ]]; then
  show_manifest "$ROOT/manifests/substrate-readonly-access-policy.yaml"
  run_command kubectl ate create access-policy --global -f "$ROOT/manifests/substrate-readonly-access-policy.yaml"
else
  printf 'Global Substrate AccessPolicy already exists; leaving it unchanged.\n' >&2
fi
apply_manifest "$ROOT/manifests/egress-restricted.yaml"
apply_manifest "$DEMO_DIR/sandbox-template.yaml"
run_command kubectl wait -n kagent --for=condition=Ready sandboxtemplate/anthropic-self-hosted-sandbox --timeout=15m
run_command kubectl wait -n kagent --for=condition=EgressPoliciesApplied sandboxtemplate/anthropic-self-hosted-sandbox --timeout=2m
printf '\nSetup ready. Follow README.md. Start the API tunnel with: bash demo.sh tunnel\n'
