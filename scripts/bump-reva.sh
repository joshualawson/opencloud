#!/usr/bin/env bash
# Point go.mod at the current head of the reva fork's sphyrix branch and tidy.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ref="${1:-sphyrix}"
go get "github.com/joshualawson/reva/v3@${ref}"
go mod tidy
go mod vendor
git --no-pager diff --stat go.mod go.sum | tail -3
