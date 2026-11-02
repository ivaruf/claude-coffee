#!/bin/sh
# Every backend's scenarios and install test, on any machine: each fixture fakes its system's commands
# and uname, so this never touches your real settings.
set -e
cd "$(dirname "$0")"
for f in fixtures/*.sh; do
  os=$(basename "$f" .sh)
  sh hook.test.sh "$os"
  sh "install-$os.test.sh"
done
