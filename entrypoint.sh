#!/usr/bin/env bash
set -euo pipefail

# --example flag: load a bundled example config
EXAMPLE="${EXAMPLE:-}"
if [ -n "$EXAMPLE" ]; then
    EXAMPLE_DIR="/home/autolab/app/examples/$EXAMPLE"
    if [ ! -d "$EXAMPLE_DIR" ]; then
        echo "ERROR: Example '$EXAMPLE' not found. Available examples:"
        ls /home/autolab/app/examples/
        exit 1
    fi
    echo "Loading example: $EXAMPLE"
    # shellcheck disable=SC1090
    source "$EXAMPLE_DIR/config.env"
fi

# Copy SSH keys from mounted read-only paths into writable .ssh dir
for key in /home/autolab/.ssh-mount/*; do
    [ -f "$key" ] && cp "$key" /home/autolab/.ssh/ && chmod 600 /home/autolab/.ssh/"$(basename "$key")"
done 2>/dev/null || true

# Required env vars
: "${ANTHROPIC_API_KEY:?Set ANTHROPIC_API_KEY}"
: "${WANDB_API_KEY:?Set WANDB_API_KEY}"

export ANTHROPIC_API_KEY WANDB_API_KEY

# Load config (skip if an example was loaded)
if [ -z "$EXAMPLE" ] && [ -f /home/autolab/app/config.env ]; then
    # shellcheck disable=SC1091
    source /home/autolab/app/config.env
fi

RESEARCH_REPO="${RESEARCH_REPO:?Set RESEARCH_REPO in config.env or environment}"
RESEARCH_DIR="${RESEARCH_DIR:-$(basename "$RESEARCH_REPO" .git)}"
MAX_CLUSTERS="${MAX_CLUSTERS:-4}"
BRANCH="${BRANCH:-}"

echo "=== autolab container setup ==="
echo ""
echo "  Research repo : $RESEARCH_REPO"
echo "  Local dir     : $RESEARCH_DIR"
echo ""

# 1. Verify kubeconfig
if [ -z "${KUBECONFIG:-}" ]; then
    CW_CONFIG=$(ls ~/.kube/config-cw* 2>/dev/null | head -1 || true)
    if [ -n "$CW_CONFIG" ]; then
        export KUBECONFIG="$CW_CONFIG"
        echo "[1/6] Auto-detected kubeconfig: $KUBECONFIG"
    else
        echo "ERROR: No kubeconfig found. Mount your kubeconfig: -v ~/.kube:/home/autolab/.kube:ro"
        exit 1
    fi
else
    echo "[1/6] Using KUBECONFIG=$KUBECONFIG"
fi
echo "      Verifying cluster connectivity..."
kubectl get nodes --no-headers | head -3 || { echo "ERROR: Cannot reach Kubernetes cluster."; exit 1; }

# 2. Clone research repo
echo "[2/6] Cloning $RESEARCH_REPO..."
if [ -d "/home/autolab/app/$RESEARCH_DIR" ]; then
    echo "      Directory '$RESEARCH_DIR' already exists, skipping clone."
else
    git clone "$RESEARCH_REPO" "/home/autolab/app/$RESEARCH_DIR"
fi
if [ -n "$BRANCH" ]; then
    cd "/home/autolab/app/$RESEARCH_DIR"
    git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
    echo "      Branch: $BRANCH"
    cd -
fi

# 3. Set up experiment template and copy instructions
echo "[3/6] Setting up experiment template and instructions..."
if [ -n "${SKYPILOT_TEMPLATE:-}" ]; then
    if [[ "$SKYPILOT_TEMPLATE" == http* ]]; then
        curl -fsSL "$SKYPILOT_TEMPLATE" -o "/home/autolab/app/$RESEARCH_DIR/experiment.yaml"
        echo "      Downloaded experiment.yaml from $SKYPILOT_TEMPLATE"
    else
        cp "$SKYPILOT_TEMPLATE" "/home/autolab/app/$RESEARCH_DIR/experiment.yaml"
        echo "      Copied experiment.yaml from $SKYPILOT_TEMPLATE"
    fi
elif [ ! -f "/home/autolab/app/$RESEARCH_DIR/experiment.yaml" ]; then
    echo "      No SKYPILOT_TEMPLATE set and no experiment.yaml found in $RESEARCH_DIR."
    echo "      You'll need to create $RESEARCH_DIR/experiment.yaml before running experiments."
fi
sed "s/MAX_CLUSTERS_PLACEHOLDER/$MAX_CLUSTERS/" /home/autolab/app/instructions.md > "/home/autolab/app/$RESEARCH_DIR/instructions.md"

# 4. Configure W&B
echo "[4/6] Configuring W&B..."
WANDB_PROJECT="${WANDB_PROJECT:?Set WANDB_PROJECT in config.env or environment}"
export WANDB_PROJECT
echo "      W&B project: $WANDB_PROJECT"

if [ -f "/home/autolab/app/$RESEARCH_DIR/pyproject.toml" ] && ! grep -q 'wandb' "/home/autolab/app/$RESEARCH_DIR/pyproject.toml"; then
    sed -i '/"torch==/a\    "wandb>=0.19.0",' "/home/autolab/app/$RESEARCH_DIR/pyproject.toml"
    echo "      Added wandb dependency to pyproject.toml"
fi

WANDB_ENTITY="${WANDB_ENTITY:-}"
YAML="/home/autolab/app/$RESEARCH_DIR/experiment.yaml"
if [ -f "$YAML" ] && ! grep -q 'WANDB_API_KEY' "$YAML"; then
    # Append W&B env vars to the envs: block (after the first EXPERIMENT_DESC only)
    sed -i "0,/EXPERIMENT_DESC:/{ /EXPERIMENT_DESC:/a\\
  WANDB_API_KEY: \"$WANDB_API_KEY\"\\
  WANDB_PROJECT: \"$WANDB_PROJECT\"${WANDB_ENTITY:+\\
  WANDB_ENTITY: \"$WANDB_ENTITY\"}
}" "$YAML"
    echo "      Added W&B env vars to experiment.yaml"
fi

# 5. Configure Weave plugin
echo "[5/6] Configuring Weave plugin..."
WEAVE_PROJECT="${WEAVE_PROJECT:-}"
if [ -n "$WEAVE_PROJECT" ]; then
    echo "$WEAVE_PROJECT" | weave-claude-plugin install
    weave-claude-plugin config set wandb_api_key "$WANDB_API_KEY" > /dev/null
    weave-claude-plugin config set weave_project "$WEAVE_PROJECT" > /dev/null
    echo "      Weave project: $WEAVE_PROJECT"
    echo "      W&B API key:   ${WANDB_API_KEY:0:10}..."
else
    echo "      WEAVE_PROJECT not set, skipping Weave config"
fi

# 6. Verify SkyPilot can reach Kubernetes
echo "[6/6] Verifying SkyPilot..."
SKY_CHECK=$(sky check kubernetes 2>&1 || true)
if echo "$SKY_CHECK" | grep -q "Kubernetes: enabled"; then
    echo "      SkyPilot Kubernetes access OK."
else
    echo "$SKY_CHECK"
    echo "      WARNING: SkyPilot could not enable Kubernetes."
fi

cd "/home/autolab/app/$RESEARCH_DIR"

echo ""
echo "=== Starting Claude Code agent ==="
echo ""

exec claude \
    --dangerously-skip-permissions \
    -p "Read instructions.md and start running parallel experiments."
