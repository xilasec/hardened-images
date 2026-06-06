# hardened-images

Reproducible, developer-friendly, signed, and hardened base container images
with full transparency.

Every image is built from a declarative config, scanned by two independent
vulnerability scanners (grype + trivy), gated by an OPA policy, checked against
CIS with dockle, smoke-tested, and finally signed with cosign (keyless) plus an
SLSA provenance attestation. All of this runs on GitHub Actions.

## Available images

| Image            | Base          | Builder                | Notes                                  |
| ---------------- | ------------- | ---------------------- | -------------------------------------- |
| `alpine-balanced`| Alpine (musl) | apko + melange         | busybox/musl rebuilt from source       |
| `ubuntu-noble`   | Ubuntu 24.04  | debootstrap + buildah  | minimal glibc base                     |
| `alpine-node24`  | Alpine (musl) | apko                   | Node.js 24 LTS, `node` at `/usr/bin/node` |
| `ubuntu-node24`  | Ubuntu 24.04  | debootstrap + buildah  | Node.js 24 LTS, `node` at `/usr/bin/node` |

The two `node24` variants are intentionally interchangeable: Node lands at the
same path (`/usr/bin/node`) and both run as the non-root user `appuser`
(uid 1000), so you can pick a base by size/libc preference without changing how
you consume the image.

Both `node24` images build for **amd64 and arm64**. The build picks one arch at
a time - the host arch by default, or `ARCH=arm64`/`ARCH=amd64` to override - and
selects the right apt mirror / package set / Node tarball for it, so each arch
builds natively without emulation. (`alpine-balanced`/`ubuntu-noble` remain
amd64-only for now: balanced depends on x86_64 melange packages.)

### How Node 24 gets in (and stays reproducible)

- **Alpine** pulls `nodejs` (24.x, `main`) and `npm` (`community`) straight from
  Alpine v3.23's signed package index via apko. No third-party repos.
- **Ubuntu** noble doesn't package Node 24, so instead of adding a third-party
  apt source we fetch the official upstream tarball and pin it by `sha256`
  (see `images/ubuntu/node24.yaml`). The bytes are verified before they touch
  the rootfs. The Node binary is deliberately left unstripped so syft can
  fingerprint the runtime version and grype can scan it for CVEs.

## Build & test locally

Everything is driven by the `Makefile`. Pick an image with `BUILD=`:

```sh
make build   BUILD=ubuntu-node24      # build the OCI archive into dist/
make sbom    BUILD=ubuntu-node24      # syft SPDX SBOM
make scan    BUILD=ubuntu-node24      # grype (gate) + trivy (second opinion)
make verify  BUILD=ubuntu-node24      # OPA policy gate
make smoke   BUILD=ubuntu-node24 EXPECT=v24   # run it and assert node works
```

`make all BUILD=<image>` runs build → sbom → scan → verify → compliance.

### On Apple Silicon (arm64)

The build needs Linux, so use a native arm64 Linux VM (e.g. `colima start` or
`limactl start` - both default to arm64 on Apple Silicon, so this is native and
fast). Install the same tooling CI uses (note: install **mikefarah `yq`** from
its release binary, not `apt install yq`), then build the arm64 image:

```sh
ARCH=arm64 make build BUILD=ubuntu-node24
ARCH=arm64 make smoke BUILD=ubuntu-node24 EXPECT=v24
# or the Alpine variant
ARCH=arm64 make build BUILD=alpine-node24
ARCH=arm64 make smoke BUILD=alpine-node24 EXPECT=v24
```

### On GitHub Actions

The workflow is `workflow_dispatch`. Pick what to build with the `images` input
(`all`, `node24`, or a single image) so a test run doesn't rebuild everything:

```sh
gh workflow run build.yaml --ref <branch> -f images=node24
gh run watch
```

> CI runs on `ubuntu-latest` (Ubuntu 24.04, amd64), which is also the closest
> match for the `ubuntu-noble` debootstrap target, so local-on-noble matches CI.
> The Smoke test runs before publishing, so a green build through that step
> means the image works.

## Roadmap

nginx

python

go

swift

rust

<!-- +++ -->
