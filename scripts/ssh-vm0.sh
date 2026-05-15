#!/bin/bash
ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -i ~/.ssh/id_ed25519 \
  -p 2200 ubuntu@localhost "$@"

