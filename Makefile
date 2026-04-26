DATE   := $(shell date -u +%Y%m%d)
BUILD  ?= ubuntu-noble
IMAGE  := ghcr.io/xilasec/$(BUILD):$(DATE)
LATEST := ghcr.io/xilasec/$(BUILD):latest
TAR    := dist/$(BUILD).tar

# Pass storage driver as flags to avoid touching /etc/containers/storage.conf
FUSE   := $(shell command -v fuse-overlayfs 2>/dev/null && test -c /dev/fuse && echo yes)
ifdef FUSE
  BSTORE := --storage-driver overlay --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs
else
  BSTORE := --storage-driver vfs
endif

build:
	sudo rm -rf tmp
	./scripts/build.sh $(BUILD) $(DATE) $(BSTORE)

sbom:
	./scripts/sbom.sh $(IMAGE) $(TAR)

scan:
	./scripts/scan.sh $(IMAGE) $(TAR)

verify:
	./scripts/verify.sh $(IMAGE)

compliance:
	./scripts/compliance.sh $(IMAGE)

sign:
	./scripts/sign.sh $(IMAGE)

load:
	sudo podman $(BSTORE) load < $(TAR)

test:
	sudo podman $(BSTORE) run --rm -it --entrypoint /bin/sh $(IMAGE)

rmi:
	sudo buildah $(BSTORE) rmi $(IMAGE) $(LATEST) 2>/dev/null || true

clean-json:
	rm -f sbom-*.json scan-*.json trivy-*.json compliance-*.json

all: build sbom scan verify compliance clean-json
