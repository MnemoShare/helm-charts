#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 APP_GIT_TREE APP_COMMIT" >&2
  exit 2
fi

app_tree=$1
app_commit=$2
source_path=contracts/migration-result/v1
destination=$(cd "$(dirname "$0")" && pwd)/contracts/migration-result/v1

resolved=$(git -C "$app_tree" rev-parse --verify "${app_commit}^{commit}")
if [ "$resolved" != "$app_commit" ]; then
  echo "APP_COMMIT must be the exact 40-character commit identity" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for name in README.md SHA256SUMS schema.json conformance.json; do
  git -C "$app_tree" show "${app_commit}:${source_path}/${name}" > "${stage}/${name}"
done
(cd "$stage" && sha256sum -c SHA256SUMS)
sums_digest=$(sha256sum "${stage}/SHA256SUMS" | cut -d' ' -f1)
cat > "${stage}/UPSTREAM" <<EOF
# Reproduction pin only. This file does not prove repository provenance or remote reachability.
repository=https://github.com/MnemoShare/mnemoshare.git
commit=${app_commit}
path=${source_path}
sha256sums=${sums_digest}
EOF

mkdir -p "$(dirname "$destination")"
if [ -e "$destination" ]; then
  if [ ! -d "$destination" ] || ! diff -qr "$stage" "$destination" >/dev/null; then
    echo "vendored migration-result/v1 is immutable and incomplete or differs; create a new contract version" >&2
    exit 1
  fi
  exit 0
fi
mv "$stage" "$destination"
trap - EXIT
