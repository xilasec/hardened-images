#!/bin/bash
set -euo pipefail

CONFIG=$1
OUT=$2
TAG=$3

rm -rf "$OUT"

apko build "$CONFIG" "$TAG" "$OUT"
