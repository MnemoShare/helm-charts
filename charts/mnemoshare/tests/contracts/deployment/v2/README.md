# Deployment contract v2

This directory is the generated, deployment-facing projection of MnemoShare's typed process composition. `contract.json` is copied byte-for-byte (plus a trailing newline) from `deploymentcontract.CanonicalJSON`; it is never a second process registry. Helm, operators, and other repositories may vendor this directory and verify `SHA256SUMS` without importing Go code.

The application link generator owns process and adapter facts. The schema owns only the stable v2 transport grammar. `README.md`, `schema.json`, and `conformance.json` are immutable once v2 exists: the generator rejects changes and requires a new version directory. Generated composition changes refresh only `contract.json` and `SHA256SUMS`.

Consumers validate the JSON Schema and the semantic vectors in `conformance.json`: identifiers and executables are unique, adapter references resolve, and exactly one image default exists. To verify or restamp `fingerprint`, set that property to the empty string, serialize the entire contract with RFC 8785 JSON Canonicalization Scheme (JCS), then SHA-256 those UTF-8 bytes and encode the digest as 64 lowercase hexadecimal characters. The independent `restamp` vector supplies the input, exact JCS bytes, and expected digest.

Run `go generate ./internal/application/link` to update the mutable snapshot, `go run ./tools/deploymentcontractbundle -root . -check` to detect drift, and `(cd contracts/deployment/v2 && sha256sum -c SHA256SUMS)` to verify the vendorable bundle from the repository root.
