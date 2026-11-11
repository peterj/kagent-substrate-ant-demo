# Hands-On Demo

Complete the [installation](README.md#install-and-configure) first. This walkthrough makes billable Anthropic API calls and creates two sessions. It assumes a fresh demo environment or fresh sessions, so files from an earlier run do not affect the isolation check.

## 1. Start The Tunnel

In a terminal in the repository directory, run:

```bash
bash demo.sh tunnel
```

Leave this terminal open. The command forwards the local kagent API to `127.0.0.1:8083`; it is not exposed to the LAN. If port 8083 is occupied, stop the conflicting service first.

## 2. Check The Environment

Open a second terminal in the repository directory. Load the demo kubeconfig and private tools for direct `kubectl` commands:

```bash
source .demo/demo.env
kubectl config current-context
bash demo.sh manifests
bash demo.sh inspect
bash demo.sh queue
```

The context should be `kind-kagent-substrate-demo`. The manifests preview shows the agent configuration, template, controller Secret reference, and egress policies without displaying the key. `inspect` shows the live template, worker pool, and policy. `queue` queries Anthropic's environment work statistics; check that a worker is polling. If not, check the controller and environment configuration before continuing.

## 3. Create Two Sessions

In the second terminal:

```bash
bash demo.sh session
bash demo.sh session secondary
```

The first command creates an agent and primary session; the second reuses the agent and creates another session. Record the two printed IDs as session A and session B. Reruns reuse the saved IDs and do not create new sessions. Creating a session is not the same as starting its sandbox: the sandbox is provisioned when the session receives work.

The default model is `claude-haiku-5-5`. If it is unavailable, set `ANTHROPIC_MODEL` to a Managed Agents-compatible model before the agent is first created. Changing it later does not change an existing agent.

## 4. Run A Tool In Session A

Replace `SESSION_A_ID` with the printed ID:

```bash
bash demo.sh connect SESSION_A_ID
```

In the connected Anthropic session, send this prompt:

```text
Use your file tool to create /data/workspace/helloworld.txt containing exactly "Hello world!". Then execute a shell command that prints the file and its SHA-256 checksum. Show the actual output.
```

You should see actual tool output containing `Hello world!` and a checksum. Record the checksum for the resume check. Anthropic runs the agent loop; the file and command execute in the self-hosted sandbox.

In a third terminal, find the corresponding sandbox:

```bash
bash demo.sh status SESSION_A_ID
```

Replace the placeholder with session A's ID. Look for `anthropic-SESSION_A_ID`, its sandbox ID, and `RUNTIME_STATE_READY`. Record the sandbox ID as `SANDBOX_A_ID`. The session ID is part of the sandbox name; it is not the sandbox ID itself.

## 5. Compare Session B

Exit the local session client after the turn completes; this does not delete the remote session. Connect to session B:

```bash
bash demo.sh connect SESSION_B_ID
```

Send:

```text
Create /data/workspace/secondary-only.txt containing exactly "Only in the secondary session." Read it back using your file tool and show the actual result.
```

In the operator terminal:

```bash
bash demo.sh status SESSION_B_ID
```

You should see a different `anthropic-SESSION_B_ID` name and a different sandbox ID. Exit the local session B client, reconnect to session A, and send:

```text
Execute: test ! -e /data/workspace/secondary-only.txt && echo SECONDARY_FILE_ABSENT
Show the actual tool output and exit code. Do not create the file.
```

Expected: `SECONDARY_FILE_ABSENT` and exit code 0. Together with the distinct sandbox IDs, this checks that session B's file is not present in session A. If the file exists from an earlier run, start with fresh sessions before repeating the check.

## 6. Inspect The Key Boundary

In the operator terminal, replace the placeholder with session A's sandbox ID:

```bash
bash demo.sh check-key SANDBOX_A_ID
```

Expected: `ENVIRONMENT_KEY_ABSENT`. The values preview references a Kubernetes Secret for the controller; this check only tests whether `ANTHROPIC_ENVIRONMENT_KEY` is set in the sandbox command's environment. It does not prove that every possible credential is absent from every file or process. Never dump environment values or print a key.

## 7. Change Egress

Keep session A connected. Ask it to execute:

```text
Execute: timeout 20 wget -S -O /data/workspace/kagent.html https://kagent.dev
Show stdout/stderr and the exit code. Do not try another URL, protocol, IP address, or download tool if it fails.
```

The fresh request should fail because the restricted policy only allows Anthropic.

In the operator terminal, allow the additional origin:

```bash
bash demo.sh allow
```

After a few seconds for reconciliation, ask session A to execute the **same request again**. Expect a successful HTTPS response and exit code 0. A redirect to a different origin may require an explicit policy change; do not grant unrestricted internet access.

Remove the extra origin:

```bash
bash demo.sh restrict
```

After reconciliation, repeat the same request a third time. It should fail again. A previously downloaded file may still exist; the evidence is the new request and its exit code. The policy changes without replacing the session or sandbox.

## 8. Wait For Idle Suspension

Stop sending work to both sessions for approximately five minutes. In the operator terminal, check each session, replacing the placeholders:

```bash
bash demo.sh status SESSION_A_ID
bash demo.sh status SESSION_B_ID
```

Repeat until both show `RUNTIME_STATE_SUSPENDED`. Timing varies; do not claim automatic suspension if it has not occurred. Do not run sandbox commands while waiting, since they may keep a sandbox active.

Connect to session A again if necessary and send:

```text
Read /data/workspace/helloworld.txt using your file tool, then execute a shell command to print its SHA-256 checksum. Do not create or rewrite the file. Show actual tool output.
```

The tool should resume session A's sandbox. Its file contents and checksum should match step 4, and its original sandbox ID should return to `RUNTIME_STATE_READY`. Session B should remain suspended until used. Shared workers, the control plane, and storage still consume resources while an actor is suspended.

If you explicitly run `bash demo.sh suspend SANDBOX_A_ID` instead of waiting, that demonstrates **manual** suspension, not automatic idle detection. Suspend can interrupt work; use it only after the agent has finished.

## 9. Inspect Actors And Workers

In the operator terminal:

```bash
source .demo/demo.env
kubectl ate get actors -A
kubectl ate get workers
```

Actors can be running or suspended; workers are the shared compute pool, not one Kubernetes Pod per session. A suspended actor need not have an assigned worker. The actor list does not display identity certificates. If these commands report `PermissionDenied`, the existing global Substrate AccessPolicy may not grant the demo's `ate-client` identity viewer access; setup leaves existing policies untouched. Ask the cluster's Substrate administrator to grant access rather than replacing an existing policy.

## 10. Clean Up

Restore the restricted policy and delete the dedicated local Kind cluster:

```bash
bash demo.sh restrict
bash demo.sh delete-cluster --yes
```

Cluster deletion removes all local sandbox data and snapshots. It does not delete Claude-side sessions, the agent or environment, or revoke the environment key. Delete those resources in Claude Platform, revoke the key, and remove `.demo/` when finished. Create fresh sessions after recreating a cluster; old session IDs can refer to deleted sandbox state.

For troubleshooting, run `source .demo/demo.env`, then inspect `kubectl get pods -n kagent`, `kubectl get pods -n ate-system`, `kubectl get sandboxtemplate -n kagent`, and `kubectl get events -n kagent --sort-by=.lastTimestamp`. Avoid displaying Secrets, environment values, or unreviewed logs.
