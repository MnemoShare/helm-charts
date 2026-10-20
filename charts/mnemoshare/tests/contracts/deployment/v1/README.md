# Deployment contract v1

This is the canonical pre-1.0 deployment grammar. It includes executable
profiles, named external persistence universes, and durable non-collection
resources. The bundle is regenerated from typed application declarations on
every build; its fingerprint identifies that exact projection.

A profile selection is disjunctive normal form: `selection` is a list of
alternatives, and every condition in an alternative's `all` list must match.
`equals`, `set`, and `unset` are the only operators. `default_profile` applies
only when the profile-selector variable is absent; it does not make malformed
or contradictory configurations valid.

Generation proves the predicate table symbolically: every case binds the
finite profile-selector vocabulary with `equals`, and cases belonging to
different profiles must be pairwise disjoint. The union of declared cases is
the accepted configuration space; a configuration outside that union is
rejected rather than guessed. This proves exactly one profile for every
accepted configuration without enumerating the unbounded environment domain.

`persistence` describes the primary application database. An
`external_universe` owns its own carrier, format ledger, admission, and
migration lifecycle. A `durable_resource` tells deployment that state must
survive process replacement without falsely describing it as a collection.

`contract.json` is generated from typed process manifests. Fingerprints use
SHA-256 over RFC 8785 JCS of the complete contract with `fingerprint` set to
`""`. Immutability begins with the first 1.0 release; later grammar changes
publish a new adjacent version and a generated transition.
