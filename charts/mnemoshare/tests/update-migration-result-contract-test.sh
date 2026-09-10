#!/usr/bin/env bash
set -euo pipefail

test_dir=$(cd "$(dirname "$0")" && pwd)
fixture=${test_dir}/contracts/migration-result/v1
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
app=${root}/app
consumer=${root}/consumer
mkdir -p "${app}/contracts/migration-result/v1" "${consumer}/charts/mnemoshare/tests"
cp "$test_dir/update-migration-result-contract.sh" "${consumer}/charts/mnemoshare/tests/"
cp "$fixture"/{README.md,SHA256SUMS,schema.json,conformance.json} "${app}/contracts/migration-result/v1/"
git -C "$app" init -q
git -C "$app" add .
git -C "$app" -c user.name=test -c user.email=test@example.com commit -q -m fixture
commit=$(git -C "$app" rev-parse HEAD)
updater=${consumer}/charts/mnemoshare/tests/update-migration-result-contract.sh

"$updater" "$app" "$commit"
destination=${consumer}/charts/mnemoshare/tests/contracts/migration-result/v1
before=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
"$updater" "$app" "$commit"
after=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
test "$before" = "$after"

printf 'changed\n' > "${destination}/schema.json"
changed_before=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
if "$updater" "$app" "$commit"; then
  echo 'updater replaced differing immutable v1' >&2
  exit 1
fi
changed_after=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
test "$changed_before" = "$changed_after"

rm "${destination}/conformance.json"
incomplete_before=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
if "$updater" "$app" "$commit"; then
  echo 'updater filled incomplete immutable v1' >&2
  exit 1
fi
incomplete_after=$(find "$destination" -type f -printf '%f\n' | sort | while read -r name; do sha256sum "${destination}/${name}"; done)
test "$incomplete_before" = "$incomplete_after"
