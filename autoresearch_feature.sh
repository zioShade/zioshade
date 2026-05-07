#!/bin/bash
set -o pipefail
cd "$(dirname "$0")"
python3 autoresearch_feature_bench.py
exit 0
