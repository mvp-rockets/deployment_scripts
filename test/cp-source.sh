#!/usr/bin/env bash

ssh -i golden-key ubuntu@192.168.56.20 "mkdir -p ~/source"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR=$(builtin cd "$SCRIPT_DIR/../../"; pwd)
project=$(basename "$PROJECT_DIR")
rsync -Pav –-exclude-from='../../.gitignore' -e "ssh -i golden-key" -r "../../../$project" ubuntu@192.168.56.20:~/source/
