# Build rules for the dsh-emacs-bridge package tar.
#
# `make package` builds the DSH plugin bundles and stages a multi-file
# Emacs package tar (dsh-bridge-<version>.tar) containing the Emacs
# package, a generated dsh-bridge-pkg.el, and the prebuilt plugin as
# payload.  Install it with `M-x package-install-file', then run
# `M-x dsh-bridge-install-plugin' to install the plugin into DSH.
#
# The package version's single source of truth is the Version header of
# emacs/dsh-bridge.el (the plugin's package.json version is unused).

VERSION := $(shell sed -n 's/^;; Version: //p' emacs/dsh-bridge.el | head -1)

TAR   := dsh-bridge-$(VERSION).tar
STAGE := .package/dsh-bridge-$(VERSION)

PLUGIN_SRC := $(wildcard dsh-plugin/src/*.ts dsh-plugin/src/client/*.ts dsh-plugin/src/client/*.tsx)

.PHONY: all build package test clean

all: package

build: dsh-plugin/lib/index.js dsh-plugin/lib/client.js

dsh-plugin/lib/index.js dsh-plugin/lib/client.js: $(PLUGIN_SRC) dsh-plugin/tsdown.config.ts dsh-plugin/tsdown.client.config.ts
	cd dsh-plugin && pnpm build

package: $(TAR)

$(TAR): build emacs/dsh-bridge.el dsh-plugin/package.json dsh-plugin/cordis.patch.yml
	rm -rf .package
	mkdir -p $(STAGE)/dsh-plugin/lib
	cp emacs/dsh-bridge.el $(STAGE)/
	cp dsh-plugin/package.json dsh-plugin/cordis.patch.yml $(STAGE)/dsh-plugin/
	cp dsh-plugin/lib/index.js dsh-plugin/lib/client.js $(STAGE)/dsh-plugin/lib/
	printf '%s\n' \
	  '(define-package "dsh-bridge" "$(VERSION)"' \
	  '  "Two-way bridge between Emacs and a running DeepSeek Harness session."' \
	  '  (quote ((emacs "29.1"))))' \
	  > $(STAGE)/dsh-bridge-pkg.el
	tar --format=ustar -cf $@ -C .package dsh-bridge-$(VERSION)

test:
	cd dsh-plugin && pnpm test
	emacs --batch -L emacs -l emacs/dsh-bridge-tests.el \
	      -f ert-run-tests-batch-and-exit

clean:
	rm -rf .package dsh-bridge-*.tar
