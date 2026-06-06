DATE   := $(shell date -u +%Y%m%d)
BUILD  ?= ubuntu-noble
IMAGE  := ghcr.io/xilasec/$(BUILD):$(DATE)
LATEST := ghcr.io/xilasec/$(BUILD):latest
EXPECT ?=

# Build output dir (OCI archive) and debootstrap scratch dir. Override both to a
# writable native path when the repo is mounted read-only (e.g. inside Lima):
#   make build BUILD=ubuntu-node24 OUTDIR=/var/tmp/dist WORKDIR=/var/tmp/work
OUTDIR  ?= dist
WORKDIR ?= tmp
export OUTDIR WORKDIR
TAR    := $(OUTDIR)/$(BUILD).tar

# Target arch for the build. Empty => host arch (amd64 on x86, arm64 on Apple
# Silicon). Override with `make build ARCH=arm64 ...` or `ARCH=arm64 make ...`.
ARCH   ?=
export ARCH

# Pass storage driver as flags to avoid touching /etc/containers/storage.conf
FUSE   := $(shell command -v fuse-overlayfs 2>/dev/null && test -c /dev/fuse && echo yes)
ifdef FUSE
  BSTORE := --storage-driver overlay --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs
else
  BSTORE := --storage-driver vfs
endif

build:
	sudo rm -rf $(WORKDIR)
	./scripts/build.sh $(BUILD) $(DATE) $(BSTORE)

sbom:
	./scripts/sbom.sh $(IMAGE) $(TAR)

scan:
	./scripts/scan.sh $(IMAGE) $(TAR)

verify:
	./scripts/verify.sh $(IMAGE)

compliance:
	./scripts/compliance.sh $(IMAGE)

# Functional smoke test (e.g. `make smoke BUILD=ubuntu-node24 EXPECT=v24`).
smoke:
	./scripts/smoke.sh $(TAR) $(IMAGE) $(EXPECT)

sign:
	./scripts/sign.sh $(IMAGE)

load:
	sudo docker load -i $(TAR)

# Open a shell in the built image. Loads the archive first and resolves the ref
# docker actually loaded (apko tags single-arch images with an -<arch> suffix).
shell:
	@REF=$$(sudo docker load -i $(TAR) | sed -n 's/^Loaded image: //p' | head -1); \
	echo "[+] entering $$REF"; \
	sudo docker run --rm -it --entrypoint /bin/sh "$$REF"

# Back-compat alias for `shell`.
test: shell

rmi:
	sudo buildah $(BSTORE) rmi $(IMAGE) $(LATEST) 2>/dev/null || true

clean-json:
	rm -f $(OUTDIR)/sbom-*.json $(OUTDIR)/scan-*.json $(OUTDIR)/trivy-*.json $(OUTDIR)/compliance-*.json

all: build sbom scan verify compliance clean-json
