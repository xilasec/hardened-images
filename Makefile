IMAGE    ?= node24
FLAVOR   ?= musl
ARCH     ?= host
MODE     ?= all
REGISTRY ?= ghcr.io/xilasec
OUTDIR   ?= dist
DOCKER   ?= docker
export REGISTRY OUTDIR DOCKER

ARGS := $(IMAGE) $(FLAVOR) $(ARCH)

.PHONY: tools packages lock build sbom scan verify compliance test all ci policy-test clean

tools:
	scripts/install-tools.sh apko melange syft grype trivy opa dockle cosign

packages:
	scripts/packages.sh $(FLAVOR) $(ARCH)

lock:
	scripts/lock.sh $(IMAGE) $(FLAVOR)

build: lock
	scripts/build.sh $(ARGS)

sbom:
	scripts/sbom.sh $(ARGS)

scan:
	scripts/scan.sh $(ARGS)

verify:
	scripts/verify.sh $(ARGS)

compliance:
	scripts/compliance.sh $(ARGS)

test:
	scripts/test.sh $(ARGS)

all: build sbom scan verify compliance test

# What CI runs: MODE=scan|diff|all
ci:
	scripts/ci.sh $(MODE)

policy-test:
	opa test policies

clean:
	rm -rf $(OUTDIR) images/*/*.lock.json
