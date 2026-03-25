#!/usr/bin/env bash
set -euo pipefail

# Build the image if needed
docker build -t autolab .

# Run autolab
docker run -it \
  -v ~/.ssh/id_ed25519:/home/autolab/.ssh-mount/id_ed25519:ro \
  -v ~/.ssh/id_ed25519.pub:/home/autolab/.ssh-mount/id_ed25519.pub:ro \
  -v "${KUBECONFIG_DIR:-$HOME/kube-configs}":/home/autolab/.kube:ro \
  -v "$(pwd)/config.env":/home/autolab/app/config.env:ro \
  -e ANTHROPIC_API_KEY \
  -e WANDB_API_KEY \
  -e KUBECONFIG="/home/autolab/.kube/${KUBECONFIG_FILE:-CWKubeconfig_ray}" \
  ${EXAMPLE:+-e EXAMPLE="$EXAMPLE"} \
  autolab
