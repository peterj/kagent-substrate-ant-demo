#!/usr/bin/env bash
set -euo pipefail
COMMAND_NAME=$(basename "$0")
case "$COMMAND_NAME" in
  kubectl|ant|kagent|kind)
    if [[ "$COMMAND_NAME $*" == 'kubectl config current-context' ]]; then
      printf '%s\n' "${TEST_CONTEXT:-kind-kagent-substrate-demo}"
      exit 0
    fi
    printf '%s %s\n' "$COMMAND_NAME" "$*" >> "$TEST_LOG"
    case "$COMMAND_NAME $*" in
      ant*beta:agents\ create*) printf '%s\n' '{"id":"agent_test"}' ;;
      ant*beta:environments:work\ stats*) printf '%s\n' '{"workers_polling":1,"queued_sessions":0}' ;;
      ant*beta:sessions\ create*)
        if [[ $(grep -c 'beta:sessions create' "$TEST_LOG") == 1 ]]; then
          printf '%s\n' '{"id":"session_test"}'
        else
          printf '%s\n' '{"id":"session_secondary_test"}'
        fi ;;
      ant*beta:sessions\ connect*) printf 'Connected\n' ;;
      'kagent -o json sandbox list'*)
        printf '%s\n' '{"sandboxes":[{"id":"sandbox_primary","name":"anthropic-session_test","state":"RUNTIME_STATE_READY"},{"id":"sandbox_secondary","name":"anthropic-session_secondary_test","state":"RUNTIME_STATE_SUSPENDED"}]}' ;;
      'kagent --timeout 15s sandbox exec'*) printf 'ENVIRONMENT_KEY_ABSENT\n' ;;
    esac
    exit 0 ;;
esac
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export DEMO_DIR
DEMO_DIR=$(mktemp -d)
trap 'rm -rf "$DEMO_DIR"' EXIT
export ANTHROPIC_ENVIRONMENT_ID=env_test
export ANTHROPIC_ENVIRONMENT_KEY=secret_test_sentinel
export TEST_LOG="$DEMO_DIR/calls.log"

bash -n "$ROOT/setup.sh" "$ROOT/demo.sh"
bash "$ROOT/setup.sh" --render
if grep -Rq secret_test_sentinel "$DEMO_DIR"; then
  printf 'Secret was written to rendered files\n' >&2
  exit 1
fi
if ANTHROPIC_ENVIRONMENT_ID=invalid bash "$ROOT/setup.sh" --render >/dev/null 2>&1; then
  printf 'Invalid environment ID was accepted\n' >&2
  exit 1
fi
ruby -rjson -ryaml -e '
  root, state = ARGV
  values = YAML.load_file(File.join(state, "kagent-values.yaml"))
  source_values = YAML.load_file(File.join(root, "manifests/kagent-values.yaml"))
  abort "feature flag is not a string" unless source_values.fetch("controller").fetch("env").find { |entry| entry["name"].end_with?("SANDBOXES_ENABLED") }.fetch("value") == "true"
  key = values.fetch("controller").fetch("env").find { |entry| entry["name"].end_with?("ENVIRONMENT_KEY") }
  abort "plaintext key" if key.key?("value")
  abort "missing key reference" unless key.fetch("valueFrom").fetch("secretKeyRef").fetch("name") == "anthropic-environment"
  abort "wrong environment ID" unless values.fetch("controller").fetch("env").find { |entry| entry["name"].end_with?("ENVIRONMENT_ID") }.fetch("value") == "env_test"
  template = YAML.load_file(File.join(state, "sandbox-template.yaml"))
  abort "wrong pool" unless template.fetch("spec").fetch("substrate").fetch("workerPoolRef").fetch("name") == "kagent-default"
  abort "wrong snapshot location" unless template.fetch("spec").fetch("substrate").fetch("snapshotPolicy").fetch("location") == "gs://ate-snapshots/anthropic-managed-agents/"
  source_template = YAML.load_file(File.join(root, "manifests/sandbox-template.yaml"))
  abort "wrong YAML template kind" unless source_template.fetch("kind") == "SandboxTemplate"
  abort "wrong source snapshot location" unless source_template.fetch("spec").fetch("substrate").fetch("snapshotPolicy").fetch("location") == "gs://ate-snapshots/anthropic-managed-agents/"
  install = YAML.load_file(File.join(state, "kagent-install-config.yaml"))
  source_install = YAML.load_file(File.join(root, "manifests/kagent-install-config.yaml"))
  abort "wrong chart repository" unless install.fetch("install").fetch("kagent").fetch("repository") == "oci://ghcr.io/kagent-dev/kagent/helm/"
  abort "wrong chart version" unless install.fetch("install").fetch("kagent").fetch("version") == "0.0.0-alpha.g4de694355985"
  abort "source install values changed" unless source_install.fetch("install").fetch("kagent").fetch("valuesFiles") == []
  abort "wrong values path" unless install.fetch("install").fetch("kagent").fetch("valuesFiles") == [File.join(state, "kagent-values.yaml")]
  agent = JSON.parse(File.read(File.join(root, "manifests/agent-config.json")))
  abort "wrong agent configuration" unless agent.fetch("tool").fetch("type") == "agent_toolset_20260401"
  namespace = YAML.load_file(File.join(root, "manifests/namespace.yaml"))
  abort "wrong namespace" unless namespace.fetch("metadata").fetch("name") == "kagent"
  kind = YAML.load_file(File.join(root, "manifests/kind-config.yaml"))
  abort "missing Kind feature gate" unless kind.fetch("featureGates").fetch("PodCertificateRequest")
  restricted = YAML.load_file(File.join(root, "manifests/egress-restricted.yaml"))
  allowed = YAML.load_file(File.join(root, "manifests/egress-allowed.yaml"))
  abort "different policy identities" unless restricted.fetch("metadata") == allowed.fetch("metadata")
  origins = ->(policy) { policy.fetch("spec").fetch("destinations").map { |destination| destination.fetch("origin") } }
  abort "wrong restricted origins" unless origins.call(restricted) == ["https://*.anthropic.com"]
  abort "wrong allowed origins" unless origins.call(allowed) == ["https://*.anthropic.com", "https://kagent.dev"]
' "$ROOT" "$DEMO_DIR"

SNAPSHOT_LOCATION=gs://alternate-bucket/snapshots/ bash "$ROOT/setup.sh" --render >/dev/null
ruby -ryaml -e 'abort "snapshot override was lost" unless YAML.load_file(ARGV.fetch(0)).dig("spec", "substrate", "snapshotPolicy", "location") == "gs://alternate-bucket/snapshots/"' \
  "$DEMO_DIR/sandbox-template.yaml"
bash "$ROOT/setup.sh" --render >/dev/null

if bash "$ROOT/demo.sh" status >/dev/null 2>&1; then
  printf 'Helper accepted a missing kubeconfig\n' >&2
  exit 1
fi
touch "$DEMO_DIR/kubeconfig"

for mock in kubectl ant kagent kind; do
  ln -s "$ROOT/tests/check.sh" "$DEMO_DIR/bin/$mock"
done
export PATH="$DEMO_DIR/bin:$PATH"

if bash "$ROOT/demo.sh" connect > /dev/null 2> "$DEMO_DIR/missing-session.log"; then
  printf 'Helper connected without a saved or supplied session ID\n' >&2
  exit 1
fi
bash "$ROOT/demo.sh" session 2> "$DEMO_DIR/session-presentation.log"
grep -q '\$ ant --format json --format-error json beta:agents create' "$DEMO_DIR/session-presentation.log"
grep -Fq 'beta:agents create --name kagent-substrate-demo --model claude-haiku-5-5' "$TEST_LOG"
grep -Fq 'Never recreate a missing file when asked to read it.' "$TEST_LOG"
grep -q '\$ ant --format json --format-error json beta:sessions create' "$DEMO_DIR/session-presentation.log"
bash "$ROOT/demo.sh" session 2> "$DEMO_DIR/reuse-presentation.log"
grep -q 'Reusing saved agent' "$DEMO_DIR/reuse-presentation.log"
grep -q 'Reusing saved session' "$DEMO_DIR/reuse-presentation.log"
if grep -q '\$ ant' "$DEMO_DIR/reuse-presentation.log"; then exit 1; fi
[[ $(grep -c 'beta:agents create' "$TEST_LOG") == 1 ]]
[[ $(grep -c 'beta:sessions create' "$TEST_LOG") == 1 ]]
bash "$ROOT/demo.sh" queue > "$DEMO_DIR/queue-output.json" 2> "$DEMO_DIR/queue-presentation.log"
grep -q 'beta:environments:work stats --environment-id env_test' "$TEST_LOG"
grep -q '"workers_polling":1' "$DEMO_DIR/queue-output.json"
bash "$ROOT/demo.sh" session secondary > "$DEMO_DIR/secondary-session.log"
grep -q 'Session (secondary): session_secondary_test' "$DEMO_DIR/secondary-session.log"
[[ $(grep -c 'beta:sessions create' "$TEST_LOG") == 2 ]]
bash "$ROOT/demo.sh" status session_test > "$DEMO_DIR/primary-status.log" 2> "$DEMO_DIR/status-presentation.log"
grep -q 'sandbox_primary.*anthropic-session_test.*RUNTIME_STATE_READY' "$DEMO_DIR/primary-status.log"
bash "$ROOT/demo.sh" status session_secondary_test > "$DEMO_DIR/secondary-status.log" 2>> "$DEMO_DIR/status-presentation.log"
grep -q 'sandbox_secondary.*anthropic-session_secondary_test.*RUNTIME_STATE_SUSPENDED' "$DEMO_DIR/secondary-status.log"
bash "$ROOT/demo.sh" check-key sandbox_primary > "$DEMO_DIR/key-check.log" 2> "$DEMO_DIR/key-presentation.log"
grep -q 'ENVIRONMENT_KEY_ABSENT' "$DEMO_DIR/key-check.log"
grep -Fq 'ANTHROPIC_ENVIRONMENT_KEY+x' "$TEST_LOG"
if grep -q 'secret_test_sentinel' "$DEMO_DIR/key-check.log"; then exit 1; fi
bash "$ROOT/demo.sh" connect 2> "$DEMO_DIR/connect-presentation.log"
grep -q '\$ ant beta:sessions connect session_test' "$DEMO_DIR/connect-presentation.log"
grep -q 'beta:sessions connect session_test' "$TEST_LOG"
bash "$ROOT/demo.sh" connect session_secondary_test 2> "$DEMO_DIR/secondary-connect.log"
grep -q '\$ ant beta:sessions connect session_secondary_test' "$DEMO_DIR/secondary-connect.log"
grep -q 'beta:sessions connect session_secondary_test' "$TEST_LOG"
bash "$ROOT/demo.sh" allow 2> "$DEMO_DIR/policy-presentation.log"
grep -q 'kind: EgressPolicy' "$DEMO_DIR/policy-presentation.log"
grep -q 'origin: https://kagent.dev' "$DEMO_DIR/policy-presentation.log"
grep -q '\$ kubectl apply -f' "$DEMO_DIR/policy-presentation.log"
bash "$ROOT/demo.sh" restrict
grep -q 'egress-allowed.yaml' "$TEST_LOG"
grep -q 'egress-restricted.yaml' "$TEST_LOG"
bash "$ROOT/demo.sh" suspend sandbox_test
grep -q 'sandbox suspend sandbox_test --user-id' "$TEST_LOG"
CALLS_BEFORE=$(wc -l < "$TEST_LOG")
bash "$ROOT/demo.sh" manifests 2> "$DEMO_DIR/manifests-presentation.log"
[[ $(wc -l < "$TEST_LOG") == "$CALLS_BEFORE" ]]
grep -q 'kind: SandboxTemplate' "$DEMO_DIR/manifests-presentation.log"
grep -q 'secretKeyRef:' "$DEMO_DIR/manifests-presentation.log"
if grep -Rq secret_test_sentinel "$DEMO_DIR"; then
  printf 'Secret appeared in presentation output\n' >&2
  exit 1
fi
if bash "$ROOT/demo.sh" suspend >/dev/null 2>&1; then exit 1; fi
if bash "$ROOT/demo.sh" delete-cluster >/dev/null 2>&1; then exit 1; fi
if TEST_CONTEXT=production bash "$ROOT/demo.sh" allow >/dev/null 2>&1; then exit 1; fi
if ANTHROPIC_ENVIRONMENT_ID=env_other bash "$ROOT/setup.sh" --render >/dev/null && \
  bash "$ROOT/demo.sh" session >/dev/null 2>&1; then exit 1; fi
bash "$ROOT/demo.sh" delete-cluster --yes
grep -q 'kind delete cluster --name kagent-substrate-demo' "$TEST_LOG"
printf 'Offline configuration and mocked helper checks passed\n'
