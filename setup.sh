#!/usr/bin/env bash
set -euo pipefail

AUTORESEARCH_DIR="autoresearch"
EXAMPLES_BASE="https://raw.githubusercontent.com/skypilot-org/skypilot/master/examples/autoresearch"

echo "=== Autoresearch + SkyPilot + W&B setup ==="
echo ""

# 1. Install uv if missing
if ! command -v uv &>/dev/null; then
    echo "[1/9] Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}:$HOME/.cargo/bin:$PATH"
else
    echo "[1/9] uv already installed ($(uv --version))"
fi

# 2. Install SkyPilot if missing
if ! command -v sky &>/dev/null; then
    echo "[2/9] Installing SkyPilot via uv..."
    uv tool install skypilot
    export PATH="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}:$HOME/.cargo/bin:$PATH"
else
    echo "[2/9] SkyPilot already installed ($(sky --version 2>/dev/null || echo 'unknown version'))"
fi

# 3. Install socat and GNU netcat (required for SkyPilot Kubernetes portforward mode)
if ! command -v socat &>/dev/null || ! command -v netcat &>/dev/null; then
    echo "[3/9] Installing socat and netcat..."
    if command -v brew &>/dev/null; then
        brew install socat netcat
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y socat netcat
    else
        echo "ERROR: socat and netcat are required but could not be installed automatically."
        echo "Please install them manually and re-run this script."
        exit 1
    fi
else
    echo "[3/9] socat and netcat already installed"
fi

# 4. Configure CoreWeave kubeconfig
echo "[4/9] Configuring CoreWeave Kubernetes..."
if [ -z "${KUBECONFIG:-}" ]; then
    CW_CONFIG=$(ls ~/.kube/config-cw* 2>/dev/null | head -1)
    if [ -n "$CW_CONFIG" ]; then
        export KUBECONFIG="$CW_CONFIG"
        echo "      Auto-detected kubeconfig: $KUBECONFIG"
    else
        echo "ERROR: No CoreWeave kubeconfig found."
        echo "Expected a file matching ~/.kube/config-cw* (e.g. ~/.kube/config-cwb607-ray)."
        echo "Download your kubeconfig from the CoreWeave dashboard and save it to ~/.kube/."
        exit 1
    fi
else
    echo "      Using KUBECONFIG=$KUBECONFIG"
fi
echo "      Verifying cluster connectivity..."
kubectl get nodes --no-headers | head -3 || { echo "ERROR: Cannot reach Kubernetes cluster."; exit 1; }

# 5. Clone autoresearch
echo "[5/9] Cloning karpathy/autoresearch..."
if [ -d "$AUTORESEARCH_DIR" ]; then
    echo "      Directory '$AUTORESEARCH_DIR' already exists, skipping clone."
else
    git clone https://github.com/karpathy/autoresearch.git "$AUTORESEARCH_DIR"
fi

# 6. Download SkyPilot experiment template and copy local instructions
echo "[6/9] Downloading experiment.yaml and copying instructions.md..."
curl -fsSL "$EXAMPLES_BASE/experiment.yaml" -o "$AUTORESEARCH_DIR/experiment.yaml"
cp instructions.md "$AUTORESEARCH_DIR/instructions.md"

# 7. Configure W&B experiment tracking
echo "[7/9] Configuring W&B experiment tracking..."
if [ -z "${WANDB_API_KEY:-}" ]; then
    echo "      Enter your W&B API key (https://wandb.ai/authorize):"
    read -r WANDB_API_KEY
    export WANDB_API_KEY
fi
if [ -z "${WANDB_PROJECT:-}" ]; then
    echo "      Enter your W&B project name for experiment tracking [kwt/autoresearch]:"
    read -r WANDB_PROJECT
    WANDB_PROJECT="${WANDB_PROJECT:-kwt/autoresearch}"
fi
echo "      W&B project: $WANDB_PROJECT"

# Add wandb dependency to pyproject.toml
if ! grep -q 'wandb' "$AUTORESEARCH_DIR/pyproject.toml"; then
    sed -i.bak '/"torch==/a\
    "wandb>=0.19.0",
' "$AUTORESEARCH_DIR/pyproject.toml"
    rm -f "$AUTORESEARCH_DIR/pyproject.toml.bak"
    echo "      Added wandb dependency to pyproject.toml"
fi

# Add W&B env vars to experiment.yaml
if ! grep -q 'WANDB_PROJECT' "$AUTORESEARCH_DIR/experiment.yaml"; then
    sed -i.bak "/EXPERIMENT_DESC:/a\\
  WANDB_PROJECT: \"$WANDB_PROJECT\"\\
  WANDB_API_KEY: \"$WANDB_API_KEY\"
" "$AUTORESEARCH_DIR/experiment.yaml"
    rm -f "$AUTORESEARCH_DIR/experiment.yaml.bak"
    echo "      Added W&B env vars to experiment.yaml"
fi

# 8. Check for Node.js / npm (required by Weave plugin)
if ! command -v npm &>/dev/null; then
    echo "[8/9] ERROR: npm not found. Install Node.js (https://nodejs.org) and re-run."
    exit 1
else
    echo "[8/9] npm available ($(npm --version))"
fi

# 9. Install Weave Claude Code plugin
if ! command -v weave-claude-plugin &>/dev/null; then
    echo "[9/9] Installing weave-claude-plugin..."
    npm install -g weave-claude-plugin
else
    echo "[9/9] weave-claude-plugin already installed"
fi
if [ -z "${WEAVE_PROJECT:-}" ]; then
    echo "      Enter your Weave project for Claude session tracing (entity/project) [kwt/autolab]:"
    read -r WEAVE_PROJECT
    WEAVE_PROJECT="${WEAVE_PROJECT:-kwt/autolab}"
fi
echo "$WEAVE_PROJECT" | weave-claude-plugin install
weave-claude-plugin config set wandb_api_key "$WANDB_API_KEY"
weave-claude-plugin config set weave_project "$WEAVE_PROJECT"

# TODO: Remove this patch once upstream fix lands (wandb/claude_code_weave_plugin).
# GNU netcat (installed above for SkyPilot) shadows macOS BSD nc in PATH.
# The Weave hook uses `nc -U` (Unix domain sockets) which only BSD nc supports.
HOOK_HANDLER="$HOME/.claude/plugins/cache/weave-claude-plugin/weave/0.1.0/hooks/hook-handler.sh"
if [ -f "$HOOK_HANDLER" ] && grep -q 'nc -U' "$HOOK_HANDLER"; then
    sed -i.bak 's|nc -U|/usr/bin/nc -U|g' "$HOOK_HANDLER"
    rm -f "$HOOK_HANDLER.bak"
    echo "      Patched Weave hook to use /usr/bin/nc (BSD netcat)"
fi

echo ""
echo "=== Kubernetes credential check ==="
SKY_CHECK=$(sky check kubernetes 2>&1 || true)
if echo "$SKY_CHECK" | grep -q "Kubernetes: enabled"; then
    echo "SkyPilot Kubernetes access OK."
else
    echo "$SKY_CHECK"
    echo ""
    echo "WARNING: SkyPilot could not enable Kubernetes. Check the output above."
    echo "Make sure KUBECONFIG is set and socat is installed, then re-run."
fi

echo ""
echo "=== Weave plugin check ==="
WEAVE_STATUS=$(weave-claude-plugin status 2>&1 || true)
echo "$WEAVE_STATUS"

echo ""
echo "================================================================"
echo " Setup complete!"
echo "================================================================"
echo ""
echo " Make sure KUBECONFIG is set in your shell:"
echo ""
echo "   export KUBECONFIG=$KUBECONFIG"
echo ""
echo " Open Claude Code/Codex/any agent in this directory, then paste this prompt:"
echo ""
echo "   Read instructions.md and start running parallel experiments."
echo ""
echo " Experiments will run on CoreWeave Kubernetes automatically."
echo ""
echo " Monitor clusters: sky status"
echo " Stream logs:      sky logs <cluster-name>"
echo " Tear down all:    sky down -a -y"
echo ""
echo " Weave tracing is active. Check status: weave-claude-plugin status"
echo " Configure Weave:    weave-claude-plugin config set weave_project <entity/project>"
echo "================================================================"
