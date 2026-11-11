# Lessons Learned Sandboxing Agents with kagent

Resources for the KubeCon + CloudNativeCon North America 2026 session.

**November 10, 5:30-6:00 PM**  
Hyatt Regency, Level 4, Regency Ballroom B

**Speakers:**  Peter Jausovec and Eitan Yarmush, Solo.io.

Agent sessions are long-lived, stateful, bursty, and mostly idle, yet can act with a user's authority. This session explores the sandbox boundary around files, tools, credentials, networking, identity, persistence, and cleanup, drawing on lessons from OpenShell, Kubernetes agent-sandbox, and Substrate.

- [Slides](slides/kagent-sandboxing-talk.html): open the HTML file in a browser. Use arrow keys to advance and `O` for the slide overview.
- [Hands-on demo](demo.md): run Anthropic Managed Agents with kagent and Substrate, then explore isolation, egress, and suspension.

## Before You Start

The demo requires macOS, Homebrew, a running Docker-compatible engine, Ruby, and internet access to GitHub, GHCR, and Anthropic. Allow ample disk space and start with at least 8 GB of Docker VM memory as a rehearsal baseline. KVM is not required.

You also need a Claude Platform account with **Managed Agents and self-hosted environments enabled**, an available Managed Agents model, and API credits. Agent calls are billable; a Claude chat subscription alone is not sufficient. See [Anthropic's self-hosted sandbox guide](https://platform.claude.com/docs/en/managed-agents/self-hosted-sandboxes).

This is an experimental, disposable local setup, not a production deployment. It pins kagent CLI `v1.0.0-rc3`, chart `0.0.0-alpha.g4de694355985`, Kubernetes `v1.35.0`, and a guest image digest. The setup installs the latest released `kubectl ate` plugin separately; its compatibility with the pinned server is not guaranteed. Do not mix other versions without testing.

## Install

Run all commands from this repository's directory.

1. Install tools and sign in to Anthropic:

   ```bash
   bash setup.sh --tools-only
   ant auth login
   ```

   Existing Kind, kubectl, Helm, jq, and Anthropic CLI installations are reused. The kagent CLI and `kubectl ate` plugin are installed under `.demo/bin`. If Docker Desktop was just installed, open it and complete its first-run setup before continuing.

2. In [Claude Platform](https://platform.claude.com/environments), create a **self-hosted** environment and generate an environment key. Keep the environment ID and key available. Do not paste the key into a file, terminal history, or chat.

3. Enter the ID and key, then create the local cluster. This hidden prompt is for macOS's default zsh:

   ```bash
   export ANTHROPIC_ENVIRONMENT_ID=env_your_environment_id
   read -rs 'ANTHROPIC_ENVIRONMENT_KEY?Environment key: '; printf '\n'
   export ANTHROPIC_ENVIRONMENT_KEY
   bash setup.sh
   unset ANTHROPIC_ENVIRONMENT_KEY
   ```

   In Bash, use `read -rs -p 'Environment key: ' ANTHROPIC_ENVIRONMENT_KEY` for the prompt instead.

Setup creates or reuses the dedicated Kind cluster `kagent-substrate-demo` with its own kubeconfig, installs kagent and its bundled Substrate infrastructure, and waits for the template and its egress policies to be ready. Successful setup ends with `Setup ready`. Rerunning setup restores the restricted egress policy; it does not create an agent or session.

The environment key is sent to the controller as a Kubernetes Secret, not written to the Helm values. Kubernetes Secrets, bundled storage credentials, and the local controller's insecure authentication make this setup unsuitable for production. Do not enable shell tracing or print secrets.

Snapshots are stored in the cluster's bundled RustFS object store. The `gs://` location does **not** require a GCP account or GCS bucket here; data is lost when the cluster is deleted. Changing `SNAPSHOT_LOCATION` alone does not configure an external store.

## Next Steps

Follow the [hands-on demo](demo.md), including its readiness checks and cleanup instructions. The scripts use `.demo/` for the private kubeconfig, generated configuration, installed tools, and saved IDs.

For offline configuration and mocked helper checks, run `bash tests/check.sh`. These tests do not create a cluster or exercise the live integration.
