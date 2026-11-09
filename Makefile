# Local entry points; CI runs the same scripts (.github/workflows/build.yaml).
#
#   make all IMAGE=node24 FLAVOR=musl            # host arch
#   make all IMAGE=node24 FLAVOR=glibc ARCH=arm64
#   make every                                   # all images x flavors, host arch

IMAGE    ?= node24
FLAVOR   ?= musl
ARCH     ?= host
REGISTRY ?= ghcr.io/xilasec
OUTDIR   ?= dist
DOCKER   ?= docker
export REGISTRY OUTDIR DOCKER

ARGS   := $(IMAGE) $(FLAVOR) $(ARCH)
IMAGES := $(notdir $(patsubst %/,%,$(wildcard images/*/)))

.PHONY: tools packages lock build repro sbom scan verify compliance test all every \
        publish policy-test matrix clean

tools:
	scripts/install-tools.sh apko melange syft grype trivy opa dockle cosign

packages:
	scripts/packages.sh $(FLAVOR) $(ARCH)

lock:
	scripts/lock.sh $(IMAGE) $(FLAVOR)

build:
	scripts/build.sh $(ARGS)

repro:
	scripts/repro.sh $(ARGS)

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

all: build repro sbom scan verify compliance test

every:
	@set -e; for i in $(IMAGES); do for f in musl glibc; do \
	  $(MAKE) --no-print-directory all IMAGE=$$i FLAVOR=$$f ARCH=$(ARCH); \
	done; done

# Needs dist/ results for every arch of the flavor (CI provides them).
publish:
	scripts/publish.sh push $(IMAGE) $(FLAVOR)

policy-test:
	opa test policies -v

matrix:
	scripts/matrix.sh

clean:
	rm -rf $(OUTDIR)
