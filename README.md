# hardened-images

Minimal, signed, reproducible container images, built with
[apko](https://github.com/chainguard-dev/apko) and
[melange](https://github.com/chainguard-dev/melange). Every image ships in two
flavors, for amd64 and arm64:

| Flavor  | Distro      | Defined in           |
| ------- | ----------- | -------------------- |
| `musl`  | Alpine 3.23 | `flavors/musl.yaml`  |
| `glibc` | Wolfi       | `flavors/glibc.yaml` |

## Images

| Image      | Contents                                         |
| ---------- | ------------------------------------------------ |
| `base`     | libc, CA bundle. No shell.                       |
| `balanced` | busybox 1.38 without network daemons, su, suid   |
| `node24`   | Node.js 24 runtime, no npm                       |

All run as uid 1000. Images are plain OCI (index, manifests, config and
layers use OCI media types) with standard `org.opencontainers.image.*`
annotations, so they work with Docker, Podman, containerd, Kubernetes and any
OCI registry.

```
ghcr.io/xilasec/<image>:<flavor>              latest
ghcr.io/xilasec/<image>:<flavor>-YYYY-MM-DD   immutable
```

## Pipeline

- **Daily**: rescan published images. Only images with fixable findings are
  re-locked and rebuilt. Identical rebuilds are skipped.
- **Push to main**: rebuild all, publish only changed digests.
- **PR**: gate everything, publish nothing.

Gates: build from a fresh lockfile, syft SBOM, grype + trivy with
`vex/`, OPA policy (Critical or fixable High fails), dockle, functional test
(`images/<name>/test.sh`, arm64 via qemu).

Publish rebuilds from the tested lockfile and stops unless the digests match.
Then it signs with cosign (keyless), attests SBOM, VEX, lockfile and SLSA
provenance, and moves `<flavor>` last.

Patched packages live in `melange/`. `packages.yaml` builds them only when
their inputs change and commits them to `packages/`. Bump `package.epoch` when
changing a recipe.

## Verify

```sh
IMG=ghcr.io/xilasec/node24:musl
ID=https://github.com/xilasec/hardened-images/.github/workflows/build.yaml@refs/heads/main
cosign verify "$IMG" --certificate-identity "$ID" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify "oci://$IMG" --repo xilasec/hardened-images
```

## Local

```sh
make tools                                # pinned tools
make all IMAGE=node24 FLAVOR=glibc        # lock, build, gate (host arch)
make ci MODE=diff                         # what CI runs
make packages FLAVOR=musl ARCH=x86_64     # stale melange packages
```

## New image

Add `images/<name>/musl.yaml`, `glibc.yaml` (each `include: flavors/<flavor>.yaml`)
and an executable `test.sh`. CI rejects images missing a flavor.
