#!/usr/bin/env bash
set -euo pipefail

contract_dir=$(cd "$(dirname "$0")" && pwd)/contracts/deployment/v3
expected_commit=eb6da48f6f874514c07cd6bf1d6daffaf9c6b101
expected_fingerprint=57c7275aee8df2c88b551911c4cfc2e96bbfda3ad86eba5112822dd058cbf7de

test "$(sed -n 's/^repository=//p' "$contract_dir/UPSTREAM")" = https://github.com/MnemoShare/mnemoshare.git
test "$(sed -n 's/^commit=//p' "$contract_dir/UPSTREAM")" = "$expected_commit"
test "$(sed -n 's/^path=//p' "$contract_dir/UPSTREAM")" = contracts/deployment/v3
test "$(sed -n 's/^sha256sums=//p' "$contract_dir/UPSTREAM")" = "$(sha256sum "$contract_dir/SHA256SUMS" | cut -d' ' -f1)"
(cd "$contract_dir" && sha256sum -c SHA256SUMS)

python3 - "$contract_dir" "$expected_fingerprint" <<'PY'
import hashlib, json, pathlib, sys
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

root, expected = pathlib.Path(sys.argv[1]), sys.argv[2]
schema = json.loads((root / "schema.json").read_text())
vectors = json.loads((root / "conformance.json").read_text())
contract = json.loads((root / "contract.json").read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
validator.validate(contract)
assert contract["provenance"]["schema"] == "mnemoshare.deployment-contract.v3"
assert contract["fingerprint"] == expected
assert any(x["id"] == "emailgateway" for x in contract["executables"])
for vector in vectors["valid"]:
    validator.validate(vector["json"])
for vector in vectors["invalid"]:
    try:
        validator.validate(vector["json"])
    except ValidationError:
        continue
restamp = vectors["restamp"]
canonical = json.dumps(restamp["input"], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
assert canonical == restamp["canonical_jcs"]
assert hashlib.sha256(canonical.encode()).hexdigest() == restamp["sha256"]
PY

echo 'frozen deployment contract v3 passed'
