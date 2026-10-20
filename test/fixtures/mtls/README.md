# Test-only mTLS identity fixtures

Public test credentials for isolated loopback integration tests. Never use for production. CA valid for ten years, leaf identities for one year from October 2026 (compatible with platform TLS validity policies). Regenerate before October 2027. CA private key is not retained; no runtime openssl dependency is introduced. These files are not application assets or distributed credentials.

Regenerate using `python3 tool/generate_mtls_fixtures.py` with OpenSSL 3.6+. The generator backdates identities by one day to tolerate CI clock skew. RSA and P-256 identities and a PEM chain are covered.
