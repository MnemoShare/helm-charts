#!/usr/bin/env bash
set -euo pipefail
contract_dir=${1:-charts/mnemoshare}/tests/contracts/migration-operation/v1
(cd "$contract_dir" && sha256sum -c SHA256SUMS)
test "$(sed -n 's/^path=//p' "$contract_dir/UPSTREAM")" = contracts/migration-operation/v1
python3 - "$contract_dir" <<'PY'
import json, pathlib, sys
from jsonschema import Draft202012Validator
root = pathlib.Path(sys.argv[1])
schema = json.loads((root / "schema.json").read_text())
contract = json.loads((root / "contract.json").read_text())
Draft202012Validator.check_schema(schema)
Draft202012Validator(schema).validate(contract)
assert contract["provenance"]["schema"] == "mnemoshare.migration-operation.v1"
PY
echo 'frozen migration-operation v1 passed'
