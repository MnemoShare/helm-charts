#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 APP_GIT_TREE APP_COMMIT" >&2
  exit 2
fi

app_tree=$1
app_commit=$2
source_path=contracts/deployment/v3
destination=$(cd "$(dirname "$0")" && pwd)/contracts/deployment/v3
resolved=$(git -C "$app_tree" rev-parse --verify "${app_commit}^{commit}")
if [ "$resolved" != "$app_commit" ]; then
  echo "APP_COMMIT must be the exact 40-character commit identity" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for name in README.md SHA256SUMS schema.json conformance.json contract.json; do
  git -C "$app_tree" show "${app_commit}:${source_path}/${name}" > "${stage}/${name}"
done
(cd "$stage" && sha256sum -c SHA256SUMS)
sums_digest=$(sha256sum "${stage}/SHA256SUMS" | cut -d' ' -f1)
cat > "${stage}/UPSTREAM" <<EOF
# Reproduction pin only. Verify repository provenance separately.
repository=https://github.com/MnemoShare/mnemoshare.git
commit=${app_commit}
path=${source_path}
sha256sums=${sums_digest}
EOF

mkdir -p "$(dirname "$destination")"
if [ -e "$destination" ] || [ -L "$destination" ]; then
  [ -d "$destination" ] && [ ! -L "$destination" ] || { echo "vendored deployment/v3 must be a real directory" >&2; exit 1; }
  for frozen in README.md schema.json conformance.json; do
    [ -f "${destination}/${frozen}" ] && [ ! -L "${destination}/${frozen}" ] && cmp -s "${stage}/${frozen}" "${destination}/${frozen}" || {
      echo "vendored deployment/v3 grammar differs; a new contract version is required" >&2
      exit 1
    }
  done
  for entry in "$destination"/*; do
    [ -f "$entry" ] && [ ! -L "$entry" ] || { echo "vendored deployment/v3 contains a non-regular entry" >&2; exit 1; }
    case "$(basename "$entry")" in README.md|SHA256SUMS|schema.json|conformance.json|contract.json|UPSTREAM) ;; *) echo "vendored deployment/v3 contains an unmanaged entry" >&2; exit 1;; esac
  done
  for mutable in contract.json SHA256SUMS UPSTREAM; do
    install -m 0644 "${stage}/${mutable}" "${destination}/${mutable}.new"
    mv "${destination}/${mutable}.new" "${destination}/${mutable}"
  done
  exit 0
fi
mv "$stage" "$destination"
trap - EXIT
