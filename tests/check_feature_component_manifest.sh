#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

node tools/build_feature_baseline.mjs --check
node tests/check_feature_component_manifest.mjs
