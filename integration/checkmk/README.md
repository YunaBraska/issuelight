# Checkmk integration lab

This lab qualifies the built-in provider against the pinned official Checkmk
Community image and its real REST API and monitoring core. Docker is required.

Run the complete provider path:

```sh
scripts/checkmk_lab.sh test
```

The script creates an isolated Checkmk site, adds one host through the REST API,
injects a real DOWN result through Livestatus, and runs the Swift live tests for
discovery, snapshots, authentication failure, acknowledgement, and downtime.
It removes the container on exit.

Run only the external-system checks used by Linux CI:

```sh
scripts/checkmk_lab.sh api-test
```

The image is pinned by digest in `scripts/checkmk_lab.sh`. Credentials and the
published loopback port are temporary lab values and are not production
defaults.
