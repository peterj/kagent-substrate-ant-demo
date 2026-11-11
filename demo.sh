#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")" && pwd)
source "$ROOT/scripts/present.sh"
DEMO_DIR=${DEMO_DIR:-"$ROOT/.demo"}
ACTION=${1:-help}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ "$ACTION" == help || "$ACTION" == --help ]]; then
  printf '%s\n' 'Usage: bash demo.sh COMMAND [SANDBOX_ID]' \
    'Commands: manifests, tunnel, queue, session [SLOT], connect [SESSION_ID], status [SESSION_ID], check-key SANDBOX_ID, inspect, allow, restrict, suspend, delete-cluster' \
    'Commands are printed before execution; applied manifests are shown as YAML. Credentials are not traced.' \
    'session reuses saved agent/session IDs; suspend requires an explicit sandbox ID.' \
    'delete-cluster requires --yes and deletes the dedicated local cluster only.'
  exit 0
fi
[[ -f "$DEMO_DIR/demo.env" && -f "$DEMO_DIR/kubeconfig" ]] || fail 'Run bash setup.sh first.'
source "$DEMO_DIR/demo.env"
[[ $(kubectl config current-context) == kind-kagent-substrate-demo ]] || fail 'Unexpected Kubernetes context.'

case "$ACTION" in
  manifests)
    printf 'Preview only; no resources are applied.\n' >&2
    show_manifest "$ROOT/manifests/agent-config.json"
    show_manifest "$ROOT/manifests/kind-config.yaml"
    show_manifest "$ROOT/manifests/namespace.yaml"
    show_manifest "$ROOT/manifests/kagent-values.yaml"
    show_manifest "$DEMO_DIR/kagent-install-config.yaml"
    show_manifest "$DEMO_DIR/kagent-values.yaml"
    show_manifest "$DEMO_DIR/sandbox-template.yaml"
    show_manifest "$ROOT/manifests/egress-restricted.yaml"
    show_manifest "$ROOT/manifests/egress-allowed.yaml" ;;
  tunnel)
    exec_command kubectl port-forward --address 127.0.0.1 -n kagent service/kagent-controller 8083:8083 ;;
  queue)
    command -v ant >/dev/null || fail 'Install the Anthropic CLI with bash setup.sh --tools-only.'
    run_command ant beta:environments:work stats --environment-id "$ANTHROPIC_ENVIRONMENT_ID" ;;
  status)
    if [[ $# == 1 ]]; then
      exec_command kagent sandbox list --user-id "$USER_ID"
    fi
    [[ $# == 2 && -n "$2" ]] || fail 'Usage: bash demo.sh status [SESSION_ID].'
    SANDBOX_STATUS=$(run_command kagent -o json sandbox list --user-id "$USER_ID" |
      jq -r --arg name "anthropic-$2" '.sandboxes[]? | select(.name == $name) | [.id, .name, .state] | @tsv')
    [[ -n "$SANDBOX_STATUS" ]] || fail "No sandbox found for session $2."
    printf 'ID\tNAME\tSTATE\n%s\n' "$SANDBOX_STATUS" ;;
  check-key)
    [[ $# == 2 && -n "$2" ]] || fail 'Usage: bash demo.sh check-key SANDBOX_ID.'
    exec_command kagent --timeout 15s sandbox exec "$2" --user-id "$USER_ID" -- sh -c \
      'if [ "${ANTHROPIC_ENVIRONMENT_KEY+x}" = x ]; then echo ENVIRONMENT_KEY_PRESENT; exit 1; else echo ENVIRONMENT_KEY_ABSENT; fi' ;;
  inspect)
    run_command kubectl get -n kagent sandboxtemplate/anthropic-self-hosted-sandbox -o yaml
    run_command kubectl get -n kagent workerpool/kagent-default -o yaml
    run_command kubectl get -n kagent egresspolicy/anthropic-managed-agents -o yaml ;;
  allow|restrict)
    POLICY=egress-allowed.yaml
    if [[ "$ACTION" == restrict ]]; then POLICY=egress-restricted.yaml; fi
    apply_manifest "$ROOT/manifests/$POLICY"
    printf 'Policy submitted. Allow a few seconds to reconcile, then retry the exact request in the same "session".\n' ;;
  session)
    command -v ant >/dev/null || fail 'Install the Anthropic CLI with bash setup.sh --tools-only.'
    [[ $# -le 2 ]] || fail 'Usage: bash demo.sh session [SLOT].'
    SESSION_SLOT=${2:-primary}
    [[ "$SESSION_SLOT" =~ ^[a-z][a-z0-9_-]*$ ]] || fail 'Session slot must start with a lowercase letter and contain only lowercase letters, digits, _ or -.'
    SESSION_FILE="$DEMO_DIR/session.json"
    if [[ "$SESSION_SLOT" != primary ]]; then SESSION_FILE="$DEMO_DIR/session-$SESSION_SLOT.json"; fi
    AGENT_CONFIG="$ROOT/manifests/agent-config.json"
    AGENT_NAME=$(jq -er '.name | select(type == "string" and length > 0)' "$AGENT_CONFIG")
    AGENT_MODEL=${ANTHROPIC_MODEL:-$(jq -er '.model | select(type == "string" and length > 0)' "$AGENT_CONFIG")}
    AGENT_SYSTEM=$(jq -er '.system | select(type == "string" and length > 0)' "$AGENT_CONFIG")
    AGENT_TOOL=$(jq -cer '.tool | select(type == "object")' "$AGENT_CONFIG")
    if [[ ! -f "$DEMO_DIR/agent.json" ]]; then
      if ! RESPONSE=$(run_command ant --format json --format-error json beta:agents create --name "$AGENT_NAME" \
        --model "$AGENT_MODEL" --system "$AGENT_SYSTEM" --tool "$AGENT_TOOL"); then
        printf '%s\n' "$RESPONSE" >&2
        exit 1
      fi
      printf '%s' "$RESPONSE" | jq -e '{id: (.id | select(type == "string" and length > 0))}' > "$DEMO_DIR/agent.json.tmp"
      mv "$DEMO_DIR/agent.json.tmp" "$DEMO_DIR/agent.json"
    else
      printf 'Reusing saved agent; no agent-create API request.\n' >&2
    fi
    AGENT_ID=$(jq -er '.id | select(type == "string" and length > 0)' "$DEMO_DIR/agent.json")
    if [[ ! -f "$SESSION_FILE" ]]; then
      if ! RESPONSE=$(run_command ant --format json --format-error json beta:sessions create --agent "$AGENT_ID" --environment-id "$ANTHROPIC_ENVIRONMENT_ID"); then
        printf '%s\n' "$RESPONSE" >&2
        exit 1
      fi
      printf '%s' "$RESPONSE" | jq -e --arg environment "$ANTHROPIC_ENVIRONMENT_ID" \
        '{id: (.id | select(type == "string" and length > 0)), environment: $environment}' > "$SESSION_FILE.tmp"
      mv "$SESSION_FILE.tmp" "$SESSION_FILE"
    else
      printf 'Reusing saved session (%s); no session-create API request.\n' "$SESSION_SLOT" >&2
    fi
    [[ $(jq -er '.environment' "$SESSION_FILE") == "$ANTHROPIC_ENVIRONMENT_ID" ]] || fail 'Saved session belongs to another environment. See README.md.'
    printf 'Agent: %s\nSession (%s): %s\nConnect with: bash demo.sh connect %s\n' \
      "$AGENT_ID" "$SESSION_SLOT" "$(jq -er '.id' "$SESSION_FILE")" "$(jq -er '.id' "$SESSION_FILE")" ;;
  connect)
    [[ $# -le 2 ]] || fail 'Usage: bash demo.sh connect [SESSION_ID].'
    if [[ $# == 2 ]]; then
      SESSION_ID=$2
    else
      [[ -f "$DEMO_DIR/session.json" ]] || fail 'Run bash demo.sh session first or provide a session ID.'
      SESSION_ID=$(jq -er '.id | select(type == "string" and length > 0)' "$DEMO_DIR/session.json")
    fi
    exec_command ant beta:sessions connect "$SESSION_ID" ;;
  suspend)
    [[ $# == 2 && -n "$2" ]] || fail 'Usage: bash demo.sh suspend SANDBOX_ID (interrupts work).'
    exec_command kagent sandbox suspend "$2" --user-id "$USER_ID" ;;
  delete-cluster)
    [[ ${2:-} == --yes ]] || fail 'Usage: bash demo.sh delete-cluster --yes. All local sandbox data will be lost.'
    run_command kind delete cluster --name kagent-substrate-demo
    printf 'Local cluster deleted. Delete the agent/session/environment separately in Claude Platform. Saved IDs remain in .demo.\n' ;;
  *) fail "Unknown command: $ACTION" ;;
esac
