# Icinga 2 Integration Lab

This lab runs the real official Icinga 2, Icinga DB, and Icinga Web images. It
is external-system test infrastructure, not a production fake server.

The image is pinned to the multi-platform Icinga 2.16 digest. The lab exposes
only `127.0.0.1:5665`, uses Icinga's generated private CA, and provides:

- a least-privilege Basic-auth API user;
- a least-privilege X.509 client-certificate API user;
- an authenticated user without object permissions;
- healthy and failing host/service objects;
- a working Icinga Web interface with real Icinga DB data and object links;
- generated CA and PKCS#12 artifacts outside the repository.

Icinga Web is exposed only on `127.0.0.1:8080`. Open
`http://localhost:8080/icingaweb2/icingadb/hosts` for manual review. The
loopback-only test gateway supplies the isolated `icingaadmin` identity so the
fixture needs no browser password. Never reuse that gateway configuration for
a deployed Icinga Web instance.

The same Compose project includes an isolated OpenSSH gateway on
`127.0.0.1:2222`. Its key-only account may forward only to the fixture's HTTP
and Icinga API endpoints. The live app tests use the real macOS OpenSSH client,
verify successful HTTP and HTTPS APIs through SOCKS and loopback forwards,
cover every server-trust mode plus mTLS, and confirm that disabling a source
closes its owned port. Host-key checking remains strict through a generated,
isolated `known_hosts` file.

The Compose project name is fixed to `issuelight-icinga2` so old monitoring
labs cannot leak objects or volumes into this fixture. The image's sample host
and service definitions are masked. `start` forces the four IssueLight checks
and waits for their expected results, leaving exactly the intended failing host
and service in the problem snapshot.

`start` replaces the image's generated API leaf with a certificate signed by
the same Icinga CA and containing `serverAuth` plus the `localhost` SAN required
by Apple's SSL policy. It does not weaken the client trust checks.

Create `integration/icinga2/.env.local` from `.env.example`, then run:

```sh
./scripts/icinga2_lab.sh start
./scripts/icinga2_lab.sh verify
./scripts/icinga2_lab.sh stop
```

`start` also creates accepted `issuelight-live-client.issuelight.invalid` and rejected
`issuelight-live-rejected.issuelight.invalid` identities signed by the lab CA. The
PKCS#12 file and CA certificate are written to
`ISSUELIGHT_ICINGA_ARTIFACTS_DIR`. The generated server leaf is exported there
as `server.crt` for exact-certificate pinning tests. The PKCS#12 password
remains only in the ignored `.env.local` file.

`verify` imports those dedicated test identities into isolated temporary macOS
Keychains, resolves their persistent references through `IssueLightCore`,
proves accepted and rejected real mTLS connections, and deletes the Keychains.
It also imports the lab CA as a source-specific reference, proves that an
unrelated CA is rejected, builds the native app test bundle, and refreshes two
persisted sources with verification enabled through the real built-in Icinga 2
provider. The PKCS#12 files intentionally omit the lab CA so identity import
does not silently alter server trust.

The real Icinga fixture exposes its API over HTTPS and requires authentication,
so plain HTTP on that TLS-only port remains a negative test. The provider also
has a local plain-HTTP transport boundary for deployments that expose Icinga
through an explicit HTTP reverse proxy. The matrix proves that the lab's private
CA is rejected without an explicit trust decision. Host and service deep links
are verified against the real Icinga Web interface.
