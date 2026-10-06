# Rocky Linux image mode on bare metal, with Artifact Keeper as the source of truth.
# Pipeline: registry-up -> base -> rpm -> image -> push -> (deploy/deploy.mk: vm-*)
# Every target is re-runnable. No sudo anywhere; rootless podman only.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

AK            ?= localhost:30080
EDGE_REPO     := $(AK)/oci-bootc/rocky-edge
# edge-site-config releases built into rocky-edge:<osver>-<rel>
RELEASES      ?= 1 2
# release the floating tag rocky-edge:10 points at (make promote REL=2 for day-2)
REL           ?= 1

.PHONY: help registry-up registry-down base base-rebuild rpm rpm-build rpm-upload \
        image push promote all clean

help: ## list targets
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

registry-up: ## start Artifact Keeper and create repos/token/edge.repo (idempotent)
	registry/up.sh
	registry/bootstrap.sh

registry-down: ## stop Artifact Keeper (volumes kept)
	registry/down.sh

base: ## build RESF rocky-bootc base rootless (skips if built), lint, push oci-bootc/rocky-bootc-base:10
	base/build.sh

base-rebuild: ## force a fresh base build and push
	REBUILD=1 base/build.sh

rpm: rpm-build rpm-upload ## build edge-site-config 1.0-{1,2} and upload to rpm-edge-site

rpm-build:
	RELEASES="$(RELEASES)" rpms/build.sh

rpm-upload:
	rpms/upload.sh

image: ## build + smoke-test localhost/rocky-edge:<osver>-<rel> for each of RELEASES
	for r in $(RELEASES); do SITE_RELEASE=$$r image/build.sh; done

push: ## push rocky-edge:<osver>-<rel> tags and point rocky-edge:10 at release $(REL)
	RELEASES="$(RELEASES)" FLOAT_RELEASE="$(REL)" image/push.sh

promote: ## move rocky-edge:10 to release $(REL) (registry-side copy), e.g. make promote REL=2
	RELEASES="$(REL)" FLOAT_RELEASE="$(REL)" image/push.sh

all: registry-up base rpm image push ## everything up to a pushed edge image

clean: ## remove local build scratch (not images, not registry data)
	rm -rf base/.work rpms/.work rpms/out image/.work

-include deploy/deploy.mk
