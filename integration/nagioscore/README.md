# Nagios Core integration lab

This lab builds the official Nagios Core 4.5.14 release from its pinned source
archive and qualifies the classic JSON and command CGI boundary. Docker is
required.

Run the provider integration:

```sh
scripts/nagioscore_lab.sh test
```

The script starts an isolated instance, injects deterministic host and service
problems through the real external command pipe, and tests discovery, Basic
authentication, snapshots, recheck, acknowledgement, downtime, and CSRF
handling. The container is removed on exit.

Run only the external contract used by Linux CI:

```sh
scripts/nagioscore_lab.sh api-test
```

The Debian base, Nagios version, and source checksum are pinned in the lab
Dockerfile. Credentials and the loopback port are temporary lab values.
