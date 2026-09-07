#!/bin/sh

set -eu

git rev-parse --is-inside-work-tree >/dev/null
git config core.hooksPath .githooks
printf 'Configured core.hooksPath=.githooks\n'
