# autoinference example

Optimizes vLLM serving config for Qwen3.5-35B-A3B on CoreWeave GPUs.

## Speed up experiments with a base image

By default, each experiment downloads ~20GB of model weights and installs all pip dependencies from scratch. Build a base image to skip this:

```bash
# 1. Copy pyproject.toml from your autoinference repo
cp /path/to/autoinference/pyproject.toml examples/autoinference/base-image/pyproject.toml

# 2. Build and push
cd examples/autoinference/base-image
./build.sh ghcr.io/your-org

# 3. Update experiment.yaml to use the new image
#    image_id: docker:ghcr.io/your-org/autoinference-base:latest
```

The base image pre-installs all Python deps and caches the model weights + GSM8K dataset. Experiment startup goes from ~10 minutes to ~30 seconds.

## Run

```bash
cp examples/autoinference/config.env config.env
# edit config.env — set WANDB_API_KEY, WANDB_ENTITY, RESEARCH_REPO

docker build -t autolab .
docker run -it \
  -v ~/.ssh/id_ed25519:/home/autolab/.ssh-mount/id_ed25519:ro \
  -v ~/.ssh/id_ed25519.pub:/home/autolab/.ssh-mount/id_ed25519.pub:ro \
  -v /path/to/kube-configs:/home/autolab/.kube:ro \
  -v $(pwd)/config.env:/home/autolab/app/config.env:ro \
  -e ANTHROPIC_API_KEY \
  -e WANDB_API_KEY \
  -e KUBECONFIG=/home/autolab/.kube/your-kubeconfig \
  autolab
```
