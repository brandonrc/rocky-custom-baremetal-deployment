# deploy/deploy.mk -- VM harness targets, included by the root Makefile
# (`-include deploy/deploy.mk`). Works standalone too: make -f deploy/deploy.mk vm-status
#
# Override anything from lib.sh on the command line, e.g.
#   make vm-install IMAGE=rocky-edge:dev
#   make vm-upgrade PROMOTE_FROM=rocky-edge:10.2-4
#   make vm-upgrade-unsigned               # negative test: unsigned image must be refused
#   make vm-upgrade PROMOTE_FROM=          # no retag, just bootc upgrade

DEPLOY := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: vm-install vm-boot vm-verify vm-ssh vm-upgrade vm-upgrade-unsigned vm-rollback vm-stop vm-clean vm-status ks-render

ks-render:   ; $(DEPLOY)/render-ks.sh
vm-install:  ; $(DEPLOY)/vm-install.sh
vm-boot:     ; $(DEPLOY)/vm-boot.sh
vm-verify:   ; $(DEPLOY)/vm-verify.sh
vm-ssh:      ; $(DEPLOY)/vm-ssh.sh
vm-upgrade:  ; $(DEPLOY)/vm-upgrade.sh
vm-upgrade-unsigned: ; $(DEPLOY)/vm-upgrade-unsigned.sh
vm-rollback: ; $(DEPLOY)/vm-rollback.sh
vm-stop:     ; $(DEPLOY)/vm-stop.sh
vm-clean:    ; $(DEPLOY)/vm-clean.sh
vm-status:   ; $(DEPLOY)/vm-status.sh
