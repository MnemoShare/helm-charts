#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
fixture=${test_dir}/contracts/deployment/v2
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
app=${root}/app
consumer=${root}/consumer
mkdir -p "${app}/contracts/deployment/v2" "${consumer}/charts/mnemoshare/tests"
cp "$test_dir/update-deployment-contract.sh" "${consumer}/charts/mnemoshare/tests/"
cp "$fixture"/{README.md,SHA256SUMS,schema.json,conformance.json,contract.json} "${app}/contracts/deployment/v2/"
git -C "$app" init -q
git -C "$app" add .
git -C "$app" -c user.name=test -c user.email=test@example.com commit -q -m fixture
commit=$(git -C "$app" rev-parse HEAD)
updater=${consumer}/charts/mnemoshare/tests/update-deployment-contract.sh

"$updater" "$app" "$commit"
destination=${consumer}/charts/mnemoshare/tests/contracts/deployment/v2
before=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
"$updater" "$app" "$commit"
after=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
test "$before" = "$after"

printf '{}\n' > "${app}/contracts/deployment/v2/contract.json"
(cd "${app}/contracts/deployment/v2" && sha256sum README.md conformance.json contract.json schema.json > SHA256SUMS)
git -C "$app" add .
git -C "$app" -c user.name=test -c user.email=test@example.com commit -q -m refresh
refresh=$(git -C "$app" rev-parse HEAD)
"$updater" "$app" "$refresh"
test "$(cat "${destination}/contract.json")" = '{}'
test "$(sed -n 's/^commit=//p' "${destination}/UPSTREAM")" = "$refresh"

printf 'changed grammar\n' > "${app}/contracts/deployment/v2/schema.json"
(cd "${app}/contracts/deployment/v2" && sha256sum README.md conformance.json contract.json schema.json > SHA256SUMS)
git -C "$app" add .
git -C "$app" -c user.name=test -c user.email=test@example.com commit -q -m grammar
grammar=$(git -C "$app" rev-parse HEAD)
if "$updater" "$app" "$grammar"; then
  echo 'updater replaced immutable v2 grammar' >&2
  exit 1
fi
