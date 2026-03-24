# Autoresearch + SkyPilot + W&B

Run [karpathy/autoresearch](https://github.com/karpathy/autoresearch) experiments on CoreWeave GPUs via [SkyPilot](https://skypilot.co/), with [W&B](https://wandb.ai/) experiment tracking and [Weave](https://wandb.ai/site/weave) session tracing.

## Prerequisites

| Dependency | Install |
|---|---|
| **Git** | Included on macOS. Linux: `sudo apt install git` |
| **Node.js 18+** (includes npm) | `brew install node` or download from [nodejs.org](https://nodejs.org) |
| **kubectl** | `brew install kubectl` or see [install docs](https://kubernetes.io/docs/tasks/tools/) |
| **CoreWeave kubeconfig** | Save to `~/.kube/config-cw*` — download from your CoreWeave dashboard |
| **W&B API key** | Get yours at [wandb.ai/authorize](https://wandb.ai/authorize) |

## Setup

```bash
./setup.sh
```

The script will:

1. Install [uv](https://github.com/astral-sh/uv) (if missing)
2. Install [SkyPilot](https://skypilot.co/) via uv (if missing)
3. Install [socat](https://linux.die.net/man/1/socat) (if missing) — required for SkyPilot Kubernetes mode
4. Auto-detect your CoreWeave kubeconfig and verify cluster connectivity
5. Clone [karpathy/autoresearch](https://github.com/karpathy/autoresearch)
6. Download the SkyPilot experiment template and agent instructions
7. Configure [W&B](https://docs.wandb.ai/models) experiment tracking — prompts for your W&B API key
8. Verify npm is available
9. Install and configure the [Weave Claude Code plugin](https://github.com/wandb/claude_code_weave_plugin) — prompts for your Weave project and W&B API key

## Usage

Make sure `KUBECONFIG` is set (the setup script prints the value to use):

```bash
export KUBECONFIG=~/.kube/config-cw<your-cluster>
cd autoresearch
claude
```

Then paste this prompt:

```
Read instructions.md and start running parallel experiments.
```

Experiments will run on CoreWeave Kubernetes automatically.

## Useful commands

```bash
sky status                 # List all clusters
sky logs <cluster-name>    # Stream job logs
sky down -a -y             # Tear down all clusters

wandb login                # Authenticate W&B CLI
weave-claude-plugin status # Check Weave tracing status
weave-claude-plugin logs   # View plugin logs
```
