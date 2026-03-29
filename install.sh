#!/usr/bin/env sh
set -e

REPO="nick-hildebrant-etas/score-task-template"
BRANCH="main"
TASKFILES_DIR="${HOME}/.score-task"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
TASKFILE_URL="${RAW_BASE}/Taskfile.yml"

# Install go-task if not present
if ! command -v task >/dev/null 2>&1; then
  echo "Installing go-task..."
  if command -v brew >/dev/null 2>&1; then
    brew install go-task
  else
    sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b "${HOME}/.local/bin"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
fi

# Install yq if not present
if ! command -v yq >/dev/null 2>&1; then
  echo "Installing yq..."
  if command -v brew >/dev/null 2>&1; then
    brew install yq
  else
    YQ_VERSION="v4.44.1"
    YQ_BIN="${HOME}/.local/bin/yq"
    mkdir -p "${HOME}/.local/bin"
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_darwin_arm64" -o "${YQ_BIN}"
    chmod +x "${YQ_BIN}"
    export PATH="${HOME}/.local/bin:${PATH}"
  fi
fi

echo "Fetching Taskfile from ${TASKFILE_URL}..."
TMPFILE="$(mktemp /tmp/Taskfile.XXXXXX)"
curl -fsSL "${TASKFILE_URL}" -o "${TMPFILE}"

echo "Running bootstrap..."
task --taskfile "${TMPFILE}" default

rm -f "${TMPFILE}"

cat <<EOF

Bootstrap complete. Repo is at ${TASKFILES_DIR}.

Next steps:

  1. Set up your age private key (required for secrets):

     Restore from backup (preferred):
       mkdir -p ~/.config/sops/age
       cp <your-backup>/keys.txt ~/.config/sops/age/keys.txt
       chmod 600 ~/.config/sops/age/keys.txt

     Or generate a new key (only if you have no backup):
       cd ${TASKFILES_DIR} && task secrets:keygen
       # then update .sops.yaml with the printed public key
       # and re-encrypt vault.sops.yaml on a machine with the old key

  2. Run the full installer:
       cd ${TASKFILES_DIR} && task install

  At any time, check your secrets setup with:
       cd ${TASKFILES_DIR} && task secrets:doctor

EOF
