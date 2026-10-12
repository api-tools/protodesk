# Security

ProtoDesk keeps workspaces and call history on the local computer. TLS validates server certificates against the system trust store; plaintext mode sends traffic without encryption. Metadata may contain credentials and is persisted with saved profiles and request history. Workspace exports include metadata and should be treated as private files.

Proto compilation operates on a copied, validated source graph and never executes generated user code. The bundled compiler is from the official Protocol Buffers distribution and verified by SHA-256 during build preparation.

Report vulnerabilities privately to the repository owner through GitHub's private vulnerability reporting when available. Do not include real credentials or private API data in public issues.
