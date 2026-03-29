# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A [go-task](https://taskfile.dev) automation layer for an ARM build platform running on a single Apple Silicon Mac Mini. All workloads run inside a Lima VM (K3s single-node cluster). The repo lives at `~/.score-task` and `~/Taskfile.yml` is a symlink into it.

## Key commands

```sh
task brew               # Install Brewfile dependencies (lima, kubectl, helm, age, sops, yq, jq)
task install            # Full setup: brew + secrets check + symlink + git hooks
task up                 # Bring up the full platform in order
task down               # Tear down in reverse order
task status             # Alias for dev:status — pod/node overview

# Secrets (SOPS + age)
task secrets:keygen     # Generate age key, prints public key to paste into .sops.yaml
task secrets:edit       # Open vault.sops.yaml in $EDITOR (SOPS encrypts on save)
task secrets:envgen     # Decrypt vault → write ~/.score-task/.env
task secrets:doctor     # Diagnose secrets setup

# Per-feature acceptance tests
task tools:test-claude
task k3s:test
task storage:test
task proxy:test
task registry:test
task deps:test-collect
task deps:test-seed
task images:test
task buildbarn:test-scheduler
task buildbarn:test-rbe
task actions:test
task test:smoke         # Runs all completed milestone tests in sequence
```

## Architecture

```
macOS host (Apple Silicon)
  └── Lima VM "k3s" (ARM64 Ubuntu, Virtualization.framework, port 6443 forwarded)
        └── K3s single-node cluster
              ├── namespace: proxy         — nginx reverse-proxy cache (PyPI, Cargo, Bazel BCR)
              ├── namespace: registry      — registry:2 OCI image registry
              ├── namespace: buildbarn     — REAPI scheduler + CAS storage + Firecracker workers
              └── namespace: actions-runner — actions-runner-controller + self-hosted runner
```

Build flow: GitHub Actions → self-hosted runner → `bazel test --remote_executor=grpc://bb-scheduler:8980` → Buildbarn fans actions to Firecracker µVMs → workers pull rootfs from registry:2 → deps resolved from warmed nginx proxy caches.

## Taskfile structure

```
Taskfile.yml          # root — dotenv: ~/.score-task/.env, includes all modules
secrets.yml           # SOPS/age secrets management (included as `secrets:` namespace)
tasks/
  tools.yml           # Node/npm/Claude Code install
  k3s.yml             # Lima VM + K3s install/kubeconfig/test
  storage.yml         # Namespace creation + PVC binding tests
  proxy.yml           # nginx reverse-proxy cache (PyPI, Cargo sparse, Bazel BCR)
  registry.yml        # registry:2 OCI image registry
  deps.yml            # Lockfile scraping (deps:collect) + proxy cache warming (deps:seed)
  images.yml          # Alpine ARM64 worker image build + push to registry:2
  buildbarn.yml       # bb-storage, bb-scheduler, bb-worker Helm install
  actions.yml         # actions-runner-controller + runner registration
  test.yml            # Smoke suite (test:smoke) + result reporting
  dev.yml             # Port-forwards, logs, cluster status
deps/
  repos.txt           # One git URL per line — scanned by deps:collect (gitignored)
  repos.txt.example   # Template showing the format
  pip.txt             # Pinned pip packages (package==version), written by deps:collect
  cargo.txt           # Pinned crates (name@version), written by deps:collect
  bazel-modules.txt   # Bzlmod modules (module@version), written by deps:collect
```

Every task file is included with `optional: true` — missing files are silently skipped.

## Secrets contract

Secrets flow: `vault.sops.yaml` (SOPS-encrypted with age) → `task secrets:envgen` → `~/.score-task/.env` → sourced by every Taskfile via `dotenv: [~/.score-task/.env]`.

Required `.env` variables:
- `REGISTRY_PORT` — port for registry:2 OCI registry (default: 5000, bound via hostPort on K3s node)
- `GITHUB_ORG`, `RUNNER_TOKEN`
- `SOPS_AGE_KEY_FILE` — path to age private key (`~/.config/sops/age/keys.txt`)

The vault key `registry_port` maps to `REGISTRY_PORT`; the task falls back to `nexus_docker_port` for existing encrypted vaults. The pre-commit hook blocks committing a plaintext vault. Never hardcode any of these values in task files.

## Delivery conventions

- Features in `arm-build-platform-plan.md` are delivered in order; each has a dedicated `task <ns>:test` acceptance test that must exit `0` before the feature is marked done.
- Run `task test:smoke` after each feature to confirm no regressions. Add the new test as a `_run` entry in `tasks/test.yml`.
- `grpc-health-probe` is not available as a Homebrew formula — install via `go install github.com/grpc-ecosystem/grpc-health-probe@latest` when needed for F-09+.
- K3s's `local-path` StorageClass uses `WaitForFirstConsumer` — PVC tests require a pod to trigger binding (use `kubectl wait --for=jsonpath='{.status.phase}'=Succeeded`, not `--for=condition=Succeeded`).
- kubectl runs on the macOS host against the kubeconfig copied from the Lima VM at `~/.kube/config` (server patched to `https://127.0.0.1:6443`).
- `nerdctl` is not available in the Lima VM — use `sudo k3s ctr` for all container operations (pull, push, tag, run).
- `k3s ctr images push` cannot push multi-arch OCI indexes — pull the image by its `linux/arm64` manifest digest first to get a single-platform reference, then tag and push that.
- Port-forward tasks must kill any stale process on the port before starting: `lsof -ti tcp:<port> | xargs kill -9 2>/dev/null || true`.
- `shuf` is not available on macOS — use `sort -R` is also unavailable; iterate over whole files or use awk/python3 for sampling.
- Shell variables inside `kubectl apply -f - <<EOF` heredocs are expanded by the host shell. Escape container-side variables with `\$` (e.g. `\${VAR}`); only host-side variables (like `${JOB_NAME}`) should be unescaped.
