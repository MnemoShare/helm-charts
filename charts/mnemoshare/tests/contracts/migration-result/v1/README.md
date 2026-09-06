# Migration result v1

This directory is the immutable deployment-facing contract emitted by `mnemoshare-migrate plan --result`. Consumers must accept every `valid` conformance vector and reject every `invalid` vector. Reproduce into an empty root with `go run ./tools/migrationresultcontract -root ROOT`; verify this checkout with `-check`. Normal generation refuses to change an existing v1 artifact. Any rule, fixture, or shape evolution requires a new version directory and consumer adoption.
