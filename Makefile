DATE   := $(shell date -u +%Y%m%d)
BUILD  := ubuntu-noble
IMAGE  := ghcr.io/xilasec/$(BUILD):$(DATE)
LATEST := ghcr.io/xilasec/$(BUILD):latest
TAR    := dist/$(BUILD).tar

build:
	sudo rm -rf tmp
	./scripts/build.sh $(BUILD) $(DATE)

sbom:
	./scripts/sbom.sh $(IMAGE) $(TAR)

scan:
	./scripts/scan.sh $(IMAGE)

verify:
	./scripts/verify.sh $(IMAGE)

compliance:
	./scripts/compliance.sh $(IMAGE)

sign:
	./scripts/sign.sh $(IMAGE)

load:
	docker load < $(TAR)

test:
	docker run --rm -it --entrypoint /bin/sh $(IMAGE)

rmi:
	docker rmi $(IMAGE) $(LATEST) 2>/dev/null || true

all: build sbom scan verify compliance sign
