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

- **Daily 02:00**: bump our melange recipes to the latest upstream release.
  A bump opens a PR, builds the packages, gates the affected images, merges
  and publishes, all without a person.
- **Daily 04:00**: rescan published images. Only images with fixable findings
  are re-locked and rebuilt. Identical rebuilds are skipped.
- **Push to main**: rebuild all, publish only changed digests.
- **PR**: gate everything, publish nothing.

Gates:

- Build from a fresh lockfile, syft SBOM.
- grype + trivy with `vex/`. Packages we build are also matched against the
  other distro's advisories, since their own distro's can miss newer versions.
- Policy (`policies/vulnerability.rego`): Critical, or High that is in CISA
  KEV or scores CVSS > 8.0, fails. Anything else warns and is published as a
  VEX `affected` statement.
- OCI media types and annotations, ELF hardening (`scripts/harden.sh`: exec
  stack, W+X segments or text relocations fail; PIE, RELRO and stack
  protector are reported), dockle.
- Functional test (`images/<name>/test.sh`), run read-only, with all
  capabilities dropped and no-new-privileges. arm64 via qemu.

Publish rebuilds from the tested lockfile and stops unless the digests match.
Then it signs with cosign (keyless), attests SBOM, VEX, lockfile and SLSA
provenance, and moves `<flavor>` last. Failed daily runs and unfixable
blocking findings open an issue.

We build what the distro ships too late (`melange/`, per flavor in
`melange/flavors.yaml`): busybox (hardened), plus sqlite and nghttp2 for musl.
They replace the distro's packages everywhere, also as dependencies (Alpine's
nodejs links to our sqlite). `packages.yaml` builds a recipe only when its
inputs change. Bump `package.epoch` when changing a recipe by hand.

## Verify

```sh
IMG=ghcr.io/xilasec/node24:musl
ID=https://github.com/xilasec/hardened-images/.github/workflows/build.yaml@refs/heads/main
ISSUER=https://token.actions.githubusercontent.com
cosign verify "$IMG" --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
gh attestation verify "oci://$IMG" --repo xilasec/hardened-images
# VEX uses the legacy attestation format, the one trivy --vex oci discovers
cosign verify-attestation "$IMG" --type openvex --new-bundle-format=false \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER"
trivy image --vex oci "$IMG"   # applies our published VEX
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
