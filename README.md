# autolab

Run autonomous AI research experiments on CoreWeave GPUs via [SkyPilot](https://skypilot.co/), with [W&B](https://wandb.ai/) experiment tracking and [Weave](https://wandb.ai/site/weave) session tracing.

Point it at any research repo that has a `program.md` describing the research goals, and let an AI agent run parallel experiments autonomously.

https://github.com/user-attachments/assets/2c672b8c-990b-4321-b2f8-e40fc6d3d2cf

## How it works

1. You provide a research repo (e.g. a training script + `program.md` describing what to optimize)
2. `setup.sh` clones the repo, wires up SkyPilot + W&B + Weave
3. An AI agent (Claude Code, Codex, etc.) reads `instructions.md` and `program.md`, then runs experiments in a loop — launching parallel GPU jobs, tracking results, and iterating

## Prerequisites

| Dependency | Install |
|---|---|
| **Git** | Included on macOS. Linux: `sudo apt install git` |
| **Node.js 18+** (includes npm) | `brew install node` or download from [nodejs.org](https://nodejs.org) |
| **kubectl** | `brew install kubectl` or see [install docs](https://kubernetes.io/docs/tasks/tools/) |
| **CoreWeave kubeconfig** | Save to `~/.kube/config-cw*` — download from your CoreWeave dashboard |
| **W&B API key** | Get yours at [wandb.ai/authorize](https://wandb.ai/authorize) |

## Examples

The `examples/` folder has ready-to-use configs:

| Example | Research repo | What it optimizes |
|---|---|---|
| **autoresearch** | [karpathy/autoresearch](https://github.com/karpathy/autoresearch) | LLM training — minimize val_bpb |
| **autoinference** | (your repo) | LLM inference — optimize throughput/latency |

To use an example, either copy its config or pass `--example` to Docker:

```bash
# Option A: copy config locally
cp examples/autoresearch/config.env config.env
# edit config.env — set your W&B keys

# Option B: pass as env var to Docker (no config.env needed)
docker run -it \
  -e EXAMPLE=autoresearch \
  -e ANTHROPIC_API_KEY -e WANDB_API_KEY \
  -e WANDB_ENTITY=your-entity \
  ...
  autolab
```

## Quick start

1. Copy a config from `examples/` or start from the template:

```bash
cp config.env.example config.env
# edit config.env — at minimum set RESEARCH_REPO
```

2. Run setup:

```bash
./setup.sh
```

3. Start the agent:

```bash
export KUBECONFIG=~/.kube/config-cw<your-cluster>
cd <research-dir>
claude
```

Then paste:

```
Read instructions.md and start running parallel experiments.
```

## Configuration

All settings live in `config.env` (see `config.env.example`). You can also set them as environment variables:

```bash
export RESEARCH_REPO="https://github.com/your-org/your-research.git"
export WANDB_API_KEY="your-key"
export WANDB_ENTITY="your-entity"
export WANDB_PROJECT="project-name"
export WEAVE_PROJECT="entity/project"
./setup.sh
```

### What your research repo needs

- **`program.md`** — Describes the research goal, optimization target, what files can be modified, and any constraints. This is what the agent reads to understand what to do.
- **A training/evaluation script** — The code the agent will modify and run.
- **`experiment.yaml`** (optional) — A SkyPilot task template. If not present, set `SKYPILOT_TEMPLATE` in `config.env` to point to one.

## Docker (recommended for autonomous runs)

Run the agent in a container with full permissions — no interactive approval needed:

```bash
docker build -t autolab .

docker run -it \
  -v ~/.ssh:/home/autolab/.ssh:ro \
  -v /path/to/kube-configs:/home/autolab/.kube:ro \
  -v $(pwd)/config.env:/home/autolab/app/config.env:ro \
  -e ANTHROPIC_API_KEY \
  -e WANDB_API_KEY \
  -e KUBECONFIG=/home/autolab/.kube/your-kubeconfig \
  autolab
```

The container handles all setup automatically — clones the research repo, configures SkyPilot + W&B, and launches Claude Code in headless mode.

Weave session traces go to the `WEAVE_PROJECT` set in `config.env`, keeping autonomous runs separate from your local Claude Code traces.

## Useful commands

```bash
sky status                 # List all clusters
sky logs <cluster-name>    # Stream job logs
sky down -a -y             # Tear down all clusters

wandb login                # Authenticate W&B CLI
weave-claude-plugin status # Check Weave tracing status
weave-claude-plugin logs   # View plugin logs
```
