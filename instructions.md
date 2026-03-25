# Parallel Research with SkyPilot

You are an autonomous research agent running parallel GPU experiments via SkyPilot.

## Setup

1. **Read the research program**: Read `program.md` in this directory. It defines what you can/cannot modify, the optimization target, and any constraints. Follow those rules. Identify the **target script** — the file `program.md` says you should edit (e.g., `train.py`, `serve.py`, etc.).
1b. **Check git state**: Run `git branch` to see which branch you're on. If you're already on an experiment branch (not `main`), continue from where it left off — read `results.tsv` if present to understand prior experiments. If you're on `main`, create a new branch as described in `program.md`.
2. **Load the SkyPilot skill**: Fetch and follow the [SkyPilot skill](https://raw.githubusercontent.com/skypilot-org/skypilot/refs/heads/master/agent/skills/skypilot/SKILL.md) — run its "Before You Start" bootstrap to confirm SkyPilot is installed and credentials are configured.
3. **Read the codebase**: Read `README.md` and any training/evaluation scripts referenced in `program.md` for full context.
4. **Set infra to Kubernetes**: This setup uses CoreWeave via Kubernetes. Set `infra: kubernetes` in `experiment.yaml` under `resources`. Do **NOT** modify the `accelerators` or `image_id` fields — they are pre-configured for this cluster. Do not prompt the user for an infra preference.
5. **Instrument the target script with W&B tracking**: The target script **must** include W&B experiment tracking so that metrics, hyperparameters, and system stats are logged automatically. See [W&B Experiment Tracking](#wb-experiment-tracking) below for what to add.
6. **Verify W&B instrumentation**: Run a short smoke test and use the W&B MCP to confirm metrics landed. See [Verify W&B Instrumentation](#verify-wb-instrumentation) below. Do **not** start the experiment loop until verification passes.

## W&B Experiment Tracking

### What to add

**1. Initialize a W&B run** (at the top of the target script, after other imports):

```python
import wandb
wandb.init(
    entity=os.environ.get("WANDB_ENTITY", None),
    project=os.environ.get("WANDB_PROJECT", "research"),
    name=os.environ.get("EXPERIMENT_ID", "baseline"),
    notes=os.environ.get("EXPERIMENT_DESC", ""),
    config={...},  # all tunable hyperparameters
)
```

**2. Log step metrics** (inside the main loop):

```python
wandb.log({...}, step=step)  # loss, learning rate, throughput, etc.
```

**3. Log final summary** (at the end, after evaluation):

```python
wandb.summary.update({...})  # final eval metrics
wandb.finish()
```

Read the target script to determine which hyperparameters belong in `config`, which per-step metrics to log, and which final eval metrics to put in `summary`. Log everything that is printed or used for decision-making.

### Rules

- **Add `wandb` to `pyproject.toml` dependencies** before instrumenting the target script. Run `uv add wandb` or manually add `"wandb>=0.19.0"` to the `dependencies` list. Without this, `uv sync` on the cluster won't install wandb and the script will crash with `ModuleNotFoundError`.
- Do **NOT** remove W&B tracking lines when modifying the target script.
- Always use `os.environ.get("WANDB_PROJECT", "research")` — never hardcode the project name.
- `WANDB_API_KEY`, `WANDB_ENTITY`, `WANDB_PROJECT`, `EXPERIMENT_ID`, and `EXPERIMENT_DESC` are passed as environment variables via `experiment.yaml` and `sky launch --env`.

## Verify W&B Instrumentation

After instrumenting the target script with W&B tracking, run **one short smoke test** to verify metrics actually land in W&B before starting the full experiment loop.

1. **Submit a short trial:**
   ```bash
   sky launch -c gpu-01 experiment.yaml \
     --env EXPERIMENT_ID=exp-smoke \
     --env EXPERIMENT_DESC="smoke test - verify W&B instrumentation" \
     -i 30 --down -d -y
   ```
   **Important:** Use `-c gpu-01` so the cluster is reusable for the experiment loop. Do NOT use auto-generated names.

2. **Wait for completion** — monitor with `sky logs gpu-01` until the job finishes.

3. **Verify via W&B MCP** — use the `query_wandb_tool` MCP tool to check the run landed correctly. The W&B project is set via the `WANDB_PROJECT` env var (format: `entity/project`).

   Query for the smoke-test run and confirm:
   - A run with `displayName` = `"exp-smoke"` exists
   - Run `state` is `"finished"`
   - `summaryMetrics` is non-empty and contains the final eval metrics you logged via `wandb.summary.update()`
   - `config` is non-empty and contains the hyperparameters you passed to `wandb.init(config={...})`
   - `_step` > 0 (step-level metrics were logged via `wandb.log()`)

   Example GraphQL query:
   ```graphql
   query SmokeCheck($entity: String!, $project: String!, $filter: JSONString) {
     project(name: $project, entityName: $entity) {
       runs(first: 1, filters: $filter) {
         edges { node { id name displayName state summaryMetrics config } }
         pageInfo { endCursor hasNextPage }
       }
     }
   }
   ```
   With variables: `{"entity": "<entity>", "project": "<project>", "filter": "{\"displayName\":{\"$eq\":\"exp-smoke\"}}"}`

4. **If verification fails** — fix the `wandb.init()`, `wandb.log()`, or `wandb.summary.update()` calls in the target script and re-run with `sky exec gpu-01` (do NOT tear down and relaunch — reuse the cluster).

5. **Proceed** to the experiment loop. The `gpu-01` cluster is already running with all dependencies installed and model weights cached. Use `sky exec gpu-01` for all subsequent experiments — this skips the setup phase entirely.

## Launching Experiments

Use the SkyPilot skill for all infrastructure operations. The template `experiment.yaml` defines a single experiment run.

**IMPORTANT: Launch clusters once, then reuse them with `sky exec`.** The `setup:` block in experiment.yaml (which installs dependencies and downloads model weights) only runs on `sky launch`. Using `sky exec` on an existing cluster skips setup entirely and goes straight to the `run:` block, saving significant time.

**Launch a cluster (first time only):**
```bash
sky launch -c gpu-01 experiment.yaml --env EXPERIMENT_ID=exp-01 --env EXPERIMENT_DESC="baseline" -i 30 --down -d -y
```

The `-i 30 --down` flag auto-destroys the cluster after 30 minutes of idleness (no running or queued jobs), preventing orphaned GPU pods.

**Run subsequent experiments on the same cluster:**
```bash
sky exec gpu-01 experiment.yaml --env EXPERIMENT_ID=exp-02 --env EXPERIMENT_DESC="increase LR" -d
```

This is **much faster** than `sky launch` — it reuses the running cluster with all dependencies already installed and model weights already cached. Always prefer `sky exec` over `sky launch` after the cluster is up.

**Do NOT `sky down` clusters between experiments.** Keep them running and pipeline jobs with `sky exec`. The idle timeout handles cleanup automatically.

**Workdir isolation**: SkyPilot snapshots the working directory at submission time. To run different code variants in parallel, copy files to a per-experiment folder and use `--workdir`:
```bash
mkdir -p /tmp/experiments/exp-03
cp <relevant files> /tmp/experiments/exp-03/
# edit files in /tmp/experiments/exp-03/
sky exec gpu-01 experiment.yaml --workdir /tmp/experiments/exp-03 --env EXPERIMENT_ID=exp-03 --env EXPERIMENT_DESC="wider model" -d
```

Keep at most **MAX_CLUSTERS_PLACEHOLDER clusters** running at a time.

## Checking Results

Use `sky logs` to stream job output:
```bash
sky logs gpu-01      # latest job
sky logs gpu-01 2    # specific job ID
```

Or SSH in and inspect directly (workdir syncs to `~/sky_workdir`):
```bash
ssh gpu-01
cd ~/sky_workdir
tail -20 run.log
```

Check status:
```bash
sky status           # all clusters
sky queue gpu-01     # jobs on a specific cluster
```

## Tracking Results

Maintain a local `results.tsv` (tab-separated):

```
experiment_id	status	metric	description
exp-01	keep	0.997900	baseline
exp-02	discard	1.005000	switch to GeLU
exp-03	crash	0.000000	double width (OOM)
```

Status: `keep` (improvement), `discard` (no improvement), `crash` (failed).

## The Experiment Loop

Run experiments in **batches** across all available clusters. Each batch fills every cluster with one experiment, then waits for all to finish before deciding what to keep.

LOOP FOREVER:

1. **Check state**: Review `results.tsv`, `sky status`, `sky queue`.
2. **Plan a batch**: Pick exactly MAX_CLUSTERS_PLACEHOLDER ideas — one per cluster. You have MAX_CLUSTERS_PLACEHOLDER clusters (gpu-01 through gpu-0MAX_CLUSTERS_PLACEHOLDER). **Always use all of them** to maximize parallelism.
3. **Prepare all experiments**: For each idea, copy code to a per-job folder (`/tmp/experiments/exp-NN/`) and make your changes.
4. **Submit the entire batch**: Submit one experiment to each cluster. Each cluster runs a different experiment simultaneously:
   ```bash
   sky exec gpu-01 experiment.yaml --workdir /tmp/experiments/exp-01 --env EXPERIMENT_ID=exp-01 --env EXPERIMENT_DESC="..." -d
   sky exec gpu-02 experiment.yaml --workdir /tmp/experiments/exp-02 --env EXPERIMENT_ID=exp-02 --env EXPERIMENT_DESC="..." -d
   ```
   Use `-d` (detached) so submissions don't block. If a cluster doesn't exist yet, use `sky launch -c gpu-NN ... -i 30 --down -d -y` instead. **Do NOT queue multiple jobs on the same cluster** — spread them across all available clusters.
5. **Poll until all finish**: Do **NOT** block on `sky logs`. Instead, poll every 30-60 seconds:
   ```bash
   sky queue gpu-01 2>&1 | tail -5
   sky queue gpu-02 2>&1 | tail -5
   # ... for each cluster
   ```
   A job is done when its status shows `SUCCEEDED` or `FAILED`. Keep polling until all jobs in the batch are done.
6. **Collect results**: Once all jobs finish, get results from each:
   ```bash
   sky logs gpu-01 <job-id> 2>&1 | tail -20
   sky logs gpu-02 <job-id> 2>&1 | tail -20
   ```
7. **Record all results** in `results.tsv`. Mark each as `keep` (improvement), `discard` (no improvement), or `crash` (failed).
8. **Keep the best**: If any experiment improved the metric, copy the winning code back, commit, and `git push`. Always push after committing.
9. **Repeat** with a new batch informed by the results.

**Timeout**: If a run exceeds 10 minutes, treat as failure. **Crashes**: Check logs, fix trivial issues and resubmit, or log as `crash`.

**NEVER STOP**: Do NOT pause to ask the human if you should continue. Work *indefinitely* until manually stopped. If stuck, re-read the code, combine near-misses, try radical changes.

## Cleanup

```bash
sky down -a -y
```
