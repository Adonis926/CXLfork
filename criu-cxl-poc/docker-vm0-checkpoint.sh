#!/bin/sh
set -eu

IMAGE="${IMAGE:-criu-cxl-poc:local}"
DAX="${DAX:-/dev/dax0.0}"
MB="${MB:-16}"
ITERS="${ITERS:-200000}"

docker rm -f cxl-checkpoint >/dev/null 2>&1 || true
docker run --rm --name cxl-checkpoint \
  --privileged \
  --device "${DAX}:${DAX}" \
  "${IMAGE}" \
  checkpoint --dax "${DAX}" --mb "${MB}" --iters "${ITERS}"
