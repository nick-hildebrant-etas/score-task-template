# score-task-template

ARM build platform for Apple Silicon — K3s · Nexus · Buildbarn · GitHub Actions

## Quick start

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/nick-hildebrant-etas/score-task-template/main/install.sh)"
```

This installs `go-task` and `yq` if missing, clones the repo to `~/.score-task`, and symlinks `~/Taskfile.yml` so you can run `task` from anywhere.

## After bootstrap

**1. Set up secrets**

Generate an age key (or restore one from backup):

```sh
cd ~/.score-task
task secrets:keygen          # prints the public key
```

Add the printed public key to `.sops.yaml` (replace `age1REPLACEME`), then create and encrypt your vault:

```sh
cp vault.sops.yaml.example vault.sops.yaml
task secrets:edit            # opens vault in $EDITOR; encrypts on save
```

Vault fields to fill in (`vault.sops.yaml.example` has the full template):

| field | description |
|---|---|
| `postgres_password` | PostgreSQL admin password |
| `nexus_admin_password` | Nexus OSS admin password |
| `nexus_docker_port` | Host port for Nexus Docker registry (e.g. `5000`) |
| `github_org` | GitHub org for the Actions runner |
| `runner_token` | GitHub Actions runner registration token |

Check everything is in order:

```sh
task secrets:doctor
```

**2. Install dependencies and finish setup**

```sh
task install    # brew bundle + secrets check + link + hooks
```

**3. Bring up the platform**

```sh
task up
```

This runs the full sequence: K3s → namespaces → PostgreSQL → Nexus → dep warming → worker image → Buildbarn → Actions runner.

## Key tasks

| task | what it does |
|---|---|
| `task up` | Bring up the full platform |
| `task down` | Tear down the full platform |
| `task status` | Show cluster and pod status |
| `task k3s:install` | Install K3s via Lima |
| `task k3s:test` | Acceptance test — 1 Ready arm64 node |
| `task nexus:configure` | Configure Nexus proxy repos |
| `task deps:seed` | Warm Nexus caches from lockfiles |
| `task buildbarn:test-rbe` | Submit a test Bazel build via RBE |
| `task test:smoke` | Full end-to-end smoke suite |
| `task secrets:edit` | Edit encrypted vault |
| `task secrets:doctor` | Diagnose secrets setup |
| `task dev:status` | Live pod/node status |

## Architecture

```
Apple Silicon Mac Mini (macOS)
  └── Lima VM (ARM64 Linux, Virtualization.framework)
        └── K3s (single-node)
              ├── postgres      (Bitnami chart)
              ├── nexus         (nxrm-ha chart — Maven/pip/Cargo/npm/Docker proxy)
              ├── buildbarn     (REAPI scheduler + storage + Firecracker workers)
              └── actions-runner (actions-runner-controller)
```

Bazel submits build actions to Buildbarn over gRPC. Each action runs in a Firecracker µVM pulling its rootfs from the Nexus Docker registry. Dependencies are resolved from Nexus proxy repos warmed ahead of time.

## Secrets

Secrets are stored encrypted in `vault.sops.yaml` using [SOPS](https://github.com/getsops/sops) + [age](https://age-encryption.org). The private key lives at `~/.config/sops/age/keys.txt` — back it up to a password manager. Never commit the plaintext vault (the pre-commit hook blocks it).
