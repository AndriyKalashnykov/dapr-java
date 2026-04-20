#!/usr/bin/env bash
# One-shot mirror of the upstream salaboy/* demo images into this project's
# GHCR namespace. Run ONCE to cover the :0.1.0 tag referenced in k8s/*.yaml
# until the first-party release workflow (.github/workflows/ci.yml
# publish-images job) cuts a newer tag.
#
# Prereqs:
#   gh auth login                     # or export GH_TOKEN
#   echo $GH_TOKEN | docker login ghcr.io -u AndriyKalashnykov --password-stdin
#
# Usage:
#   ./scripts/mirror-salaboy-images.sh            # mirror :0.1.0
#   ./scripts/mirror-salaboy-images.sh 0.1.0      # explicit tag
#
# After this completes, the k8s/pizza-*.yaml image: lines (which point at
# ghcr.io/andriykalashnykov/pizza-*:0.1.0) will resolve. From that point
# you own the bits — future tags should come from the release workflow.

set -euo pipefail

TAG="${1:-0.1.0}"
SRC_NS="salaboy"
DST_NS="ghcr.io/andriykalashnykov"
SERVICES=(pizza-store pizza-kitchen pizza-delivery)

for svc in "${SERVICES[@]}"; do
  src="${SRC_NS}/${svc}:${TAG}"
  dst="${DST_NS}/${svc}:${TAG}"
  echo "--- Mirroring ${src} → ${dst} ---"
  docker pull "${src}"
  docker tag "${src}" "${dst}"
  docker push "${dst}"
done

echo "Mirrored ${#SERVICES[@]} images at tag ${TAG} into ${DST_NS}."
