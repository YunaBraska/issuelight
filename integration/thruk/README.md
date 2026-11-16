# Thruk integration lab

This lab qualifies IssueLight against a real OMD Labs installation with Thruk
and Naemon. It uses the official multi-architecture image pinned by digest and
creates one deterministic critical service.

Run the complete macOS provider test:

```sh
scripts/thruk_lab.sh test
```

The command verifies the real REST API, then drives connection testing,
authentication, trust rejection, snapshots, recheck, acknowledgement, and
downtime through the built-in `ThrukProvider`. The container is removed on
completion. The image remains cached by the selected Docker engine.

For manual app review:

```sh
scripts/thruk_lab.sh start
scripts/thruk_lab.sh status
scripts/thruk_lab.sh api-key
scripts/thruk_lab.sh stop
```

`start` prints the random local port and disposable Basic credentials. Basic
authentication is sufficient for reads. Thruk requires an API key or browser
CSRF token for commands. `api-key` prints the lab-only key for an IssueLight
source configured with API-key authentication.

The script uses the current Docker context or `DOCKER_HOST`. It does not start
the Icinga 2 lab. Use `api-test` when only the external Thruk contract should be
verified, such as on a Linux CI runner.
