#!/usr/bin/env bash
set -euo pipefail

# Load config if present
if [ -f "config.env" ]; then
    # shellcheck disable=SC1091
    source config.env
fi

# Derive RESEARCH_DIR from repo URL if not set
RESEARCH_REPO="${RESEARCH_REPO:?Set RESEARCH_REPO in config.env or environment}"
RESEARCH_DIR="${RESEARCH_DIR:-$(basename "$RESEARCH_REPO" .git)}"
MAX_CLUSTERS="${MAX_CLUSTERS:-4}"

echo "=== autolab setup ==="
echo ""
echo "  Research repo : $RESEARCH_REPO"
echo "  Local dir     : $RESEARCH_DIR"
echo ""

# 1. Install uv if missing
if ! command -v uv &>/dev/null; then
    echo "[1/10] Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}:$HOME/.cargo/bin:$PATH"
else
    echo "[1/10] uv already installed ($(uv --version))"
fi

# 2. Install SkyPilot if missing
if ! command -v sky &>/dev/null; then
    echo "[2/10] Installing SkyPilot via uv..."
    uv tool install skypilot
    export PATH="${UV_TOOL_BIN_DIR:-$HOME/.local/bin}:$HOME/.cargo/bin:$PATH"
else
    echo "[2/10] SkyPilot already installed ($(sky --version 2>/dev/null || echo 'unknown version'))"
fi

# 3. Install socat and GNU netcat (required for SkyPilot Kubernetes portforward mode)
if ! command -v socat &>/dev/null || ! command -v netcat &>/dev/null; then
    echo "[3/10] Installing socat and netcat..."
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
    echo "[3/10] socat and netcat already installed"
fi

# 4. Configure CoreWeave kubeconfig
echo "[4/10] Configuring CoreWeave Kubernetes..."
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

# 5. Clone research repo
echo "[5/10] Cloning $RESEARCH_REPO..."
if [ -d "$RESEARCH_DIR" ]; then
    echo "      Directory '$RESEARCH_DIR' already exists, skipping clone."
else
    git clone "$RESEARCH_REPO" "$RESEARCH_DIR"
fi

# 6. Set up SkyPilot experiment template and copy instructions
echo "[6/10] Setting up experiment template and instructions..."
if [ -n "${SKYPILOT_TEMPLATE:-}" ]; then
    if [[ "$SKYPILOT_TEMPLATE" == http* ]]; then
        curl -fsSL "$SKYPILOT_TEMPLATE" -o "$RESEARCH_DIR/experiment.yaml"
        echo "      Downloaded experiment.yaml from $SKYPILOT_TEMPLATE"
    else
        cp "$SKYPILOT_TEMPLATE" "$RESEARCH_DIR/experiment.yaml"
        echo "      Copied experiment.yaml from $SKYPILOT_TEMPLATE"
    fi
elif [ ! -f "$RESEARCH_DIR/experiment.yaml" ]; then
    echo "      No SKYPILOT_TEMPLATE set and no experiment.yaml found in $RESEARCH_DIR."
    echo "      You'll need to create $RESEARCH_DIR/experiment.yaml before running experiments."
fi
sed "s/MAX_CLUSTERS_PLACEHOLDER/$MAX_CLUSTERS/" instructions.md > "$RESEARCH_DIR/instructions.md"

# 7. Configure W&B experiment tracking
echo "[7/10] Configuring W&B experiment tracking..."
if [ -z "${WANDB_API_KEY:-}" ]; then
    echo "      Enter your W&B API key (https://wandb.ai/authorize):"
    read -r WANDB_API_KEY
    export WANDB_API_KEY
fi
if [ -z "${WANDB_PROJECT:-}" ]; then
    echo "      Enter your W&B project name for experiment tracking (entity/project):"
    read -r WANDB_PROJECT
    if [ -z "$WANDB_PROJECT" ]; then
        echo "ERROR: WANDB_PROJECT is required. Please provide an entity/project name."
        exit 1
    fi
fi
echo "      W&B project: $WANDB_PROJECT"

# Add wandb dependency if pyproject.toml exists and doesn't already have it
if [ -f "$RESEARCH_DIR/pyproject.toml" ] && ! grep -q 'wandb' "$RESEARCH_DIR/pyproject.toml"; then
    sed -i.bak '/"torch==/a\
    "wandb>=0.19.0",
' "$RESEARCH_DIR/pyproject.toml"
    rm -f "$RESEARCH_DIR/pyproject.toml.bak"
    echo "      Added wandb dependency to pyproject.toml"
fi

# Add W&B env vars to experiment.yaml if present
if [ -f "$RESEARCH_DIR/experiment.yaml" ] && ! grep -q 'WANDB_PROJECT' "$RESEARCH_DIR/experiment.yaml"; then
    sed -i.bak "/EXPERIMENT_DESC:/a\\
  WANDB_PROJECT: \"$WANDB_PROJECT\"\\
  WANDB_API_KEY: \"$WANDB_API_KEY\"
" "$RESEARCH_DIR/experiment.yaml"
    rm -f "$RESEARCH_DIR/experiment.yaml.bak"
    echo "      Added W&B env vars to experiment.yaml"
fi

# 8. Check for Node.js / npm (required by Weave plugin)
if ! command -v npm &>/dev/null; then
    echo "[8/10] ERROR: npm not found. Install Node.js (https://nodejs.org) and re-run."
    exit 1
else
    echo "[8/10] npm available ($(npm --version))"
fi

# 9. Install Weave Claude Code plugin
if ! command -v weave-claude-plugin &>/dev/null; then
    echo "[9/10] Installing weave-claude-plugin..."
    npm install -g weave-claude-plugin
else
    echo "[9/10] weave-claude-plugin already installed"
fi
if [ -z "${WEAVE_PROJECT:-}" ]; then
    echo "      Enter your Weave project for Claude session tracing (entity/project):"
    read -r WEAVE_PROJECT
    if [ -z "$WEAVE_PROJECT" ]; then
        echo "ERROR: WEAVE_PROJECT is required. Please provide an entity/project name."
        exit 1
    fi
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

# 10. Register W&B MCP server for Claude Code (hosted endpoint, no local install needed)
echo "[10/10] Configuring W&B MCP server for Claude Code..."
if command -v claude &>/dev/null; then
    claude mcp add --transport http -s project wandb https://mcp.withwandb.com/mcp \
        -H "Authorization: Bearer $WANDB_API_KEY" 2>/dev/null \
        && echo "      W&B MCP server registered (project scope)" \
        || echo "      WARNING: Failed to register W&B MCP server. You can add it manually later."
else
    echo "      Claude Code CLI not found — skipping MCP registration."
    echo "      Install Claude Code, then run:"
    echo "        claude mcp add --transport http -s project wandb https://mcp.withwandb.com/mcp -H \"Authorization: Bearer \$WANDB_API_KEY\""
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
echo " Open Claude Code/Codex/any agent in the $RESEARCH_DIR directory,"
echo " then paste this prompt:"
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
