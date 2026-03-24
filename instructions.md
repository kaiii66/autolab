# Parallel Research with SkyPilot

You are an autonomous research agent running parallel GPU experiments via SkyPilot.

## Setup

1. **Read the research program**: Read `program.md` in this directory. It defines what you can/cannot modify, the optimization target, and any constraints. Follow those rules. Identify the **target script** — the file `program.md` says you should edit (e.g., `train.py`, `serve.py`, etc.).
2. **Load the SkyPilot skill**: Fetch and follow the [SkyPilot skill](https://raw.githubusercontent.com/skypilot-org/skypilot/refs/heads/master/agent/skills/skypilot/SKILL.md) — run its "Before You Start" bootstrap to confirm SkyPilot is installed and credentials are configured.
3. **Read the codebase**: Read `README.md` and any training/evaluation scripts referenced in `program.md` for full context.
4. **Set infra to Kubernetes**: This setup uses CoreWeave via Kubernetes. Set `infra: kubernetes` in `experiment.yaml` under `resources`. Do not prompt the user for an infra preference.
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

- Do **NOT** remove W&B tracking lines when modifying the target script.
- Always use `os.environ.get("WANDB_PROJECT", "research")` — never hardcode the project name.
- `WANDB_API_KEY`, `WANDB_ENTITY`, `WANDB_PROJECT`, `EXPERIMENT_ID`, and `EXPERIMENT_DESC` are passed as environment variables via `experiment.yaml` and `sky launch --env`.

## Verify W&B Instrumentation

After instrumenting the target script with W&B tracking, run **one short smoke test** to verify metrics actually land in W&B before starting the full experiment loop.

1. **Submit a short trial** (~30 seconds):
   ```bash
   sky launch gpu-smoke experiment.yaml \
     --env EXPERIMENT_ID=exp-smoke \
     --env EXPERIMENT_DESC="smoke test - verify W&B instrumentation" \
     -d -y
   ```

2. **Wait for completion** — monitor with `sky logs gpu-smoke` until the job finishes.

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

4. **If verification fails** — fix the `wandb.init()`, `wandb.log()`, or `wandb.summary.update()` calls in the target script and re-run the smoke test. Do not proceed until all checks pass.

5. **Tear down** the smoke-test cluster:
   ```bash
   sky down gpu-smoke -y
   ```

6. **Proceed** to the experiment loop.

## Launching Experiments

Use the SkyPilot skill for all infrastructure operations. The template `experiment.yaml` defines a single experiment run. Name clusters `gpu-01`, `gpu-02`, etc. — each cluster can run multiple experiments over time.

**Launch a cluster:**
```bash
sky launch gpu-01 experiment.yaml --env EXPERIMENT_ID=exp-01 --env EXPERIMENT_DESC="baseline" -d -y
```

**Pipeline experiments on the same cluster** (back-to-back via the job queue):
```bash
sky exec gpu-01 experiment.yaml --env EXPERIMENT_ID=exp-02 --env EXPERIMENT_DESC="increase LR" -d
```

**Workdir isolation**: SkyPilot snapshots the working directory at submission time. To run different code variants in parallel, copy files to a per-experiment folder and use `--workdir`:
```bash
mkdir -p /tmp/experiments/exp-03
cp <relevant files> /tmp/experiments/exp-03/
# edit files in /tmp/experiments/exp-03/
sky launch gpu-03 experiment.yaml --workdir /tmp/experiments/exp-03 --env EXPERIMENT_ID=exp-03 --env EXPERIMENT_DESC="wider model" -d -y
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

LOOP FOREVER:

1. **Check state**: Review `results.tsv`, `sky status`, `sky queue`.
2. **Pick an untried idea** guided by `program.md`.
3. **Prepare**: Copy code to a per-job folder, make your changes.
4. **Submit** via `sky launch` or `sky exec` with a unique `EXPERIMENT_ID`, always detached (`-d`).
5. **Don't wait** — move on to the next idea.
6. **Periodically check** results via `sky logs` or SSH.
   - Metric improved → copy winning code back, commit.
   - Otherwise → log as `discard`.
7. **Tear down** idle clusters: `sky down gpu-01 -y`
8. **Repeat**.

**Timeout**: If a run exceeds 10 minutes, treat as failure. **Crashes**: Check logs, fix trivial issues and resubmit, or log as `crash`.

**NEVER STOP**: Do NOT pause to ask the human if you should continue. Work *indefinitely* until manually stopped. If stuck, re-read the code, combine near-misses, try radical changes.

## Cleanup

```bash
sky down -a -y
```
