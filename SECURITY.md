# Security Policy

## Supported Versions

ProtoDesk is currently an early-stage project. Security fixes are applied to the
latest revision on the default branch; older revisions are not supported.

## Reporting a Vulnerability

Please do not disclose suspected vulnerabilities in a public issue. Use GitHub's
private vulnerability reporting feature for this repository when available.

Include a concise description, reproduction steps, affected versions or commits,
and the potential impact. Please avoid including real credentials, tokens,
private keys, or sensitive production data in a report.

## Local Data

ProtoDesk stores server profiles, request history, collections, and saved
requests locally. Treat exported workspaces as potentially sensitive because
they can contain server addresses, metadata values, request bodies, and local
proto paths. Review exports before sharing or committing them.
