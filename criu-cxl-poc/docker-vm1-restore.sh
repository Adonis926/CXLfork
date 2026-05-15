#!/bin/sh
set -eu

IMAGE="${IMAGE:-criu-cxl-poc:local}"
DAX="${DAX:-/dev/dax0.0}"
ITERS="${ITERS:-200000}"

docker rm -f cxl-restore >/dev/null 2>&1 || true
docker run --rm --name cxl-restore \
  --privileged \
  --device "${DAX}:${DAX}" \
  "${IMAGE}" \
  restore --dax "${DAX}" --iters "${ITERS}"
