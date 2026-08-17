# Top-level build. Each stage feeds the next:
#
#   verify   prove the F* core
#   extract  regenerate ocaml/extracted from the proved source
#   build    compile the native binary and the js_of_ocaml bundle
#   ui       build the web UI against that bundle
#   test     everything: vectors natively, vectors in JS, server, browser
#
# The environment this needs is not on PATH by default; see `make env`.

FSTAR_BIN := $(HOME)/toolchain/fstar/bin
SWITCH    := tessarium
PORT      ?= 7373

.PHONY: all env verify extract build ui test test-core test-static test-ui run package clean

all: build ui

env:
	@echo 'export PATH=$(FSTAR_BIN):$$PATH'
	@echo 'eval "$$(opam env --switch=$(SWITCH))"'
	@echo 'export NVM_DIR="$$HOME/.nvm"; . "$$NVM_DIR/nvm.sh"'
	@echo '# eval "$$(make env)" to apply'

verify:
	$(MAKE) -C fstar verify

# Regenerating extracted OCaml is the only sanctioned way to change it. CI
# runs this and fails on any diff, which is what makes "never hand-edit
# extracted code" enforceable rather than merely stated.
extract:
	$(MAKE) -C fstar extract

build:
	dune build

# The built UI is copied where dune can see it, so the next `make build`
# compiles it into the server binary. ui/dist itself is not depended on
# directly: that would put ui/node_modules in dune's view.
ui:
	cd ui && npm ci --no-audit --no-fund && npm run build
	rm -rf ocaml/server/ui_dist
	cp -r ui/dist ocaml/server/ui_dist
	@echo "  UI copied to ocaml/server/ui_dist; run 'make build' to embed it"

test: test-core test-static test-ui

# Via check-suites.sh, not `dune test` directly: dune reports failures but
# cannot tell you a suite produced no output at all, which is how the
# differential check once stopped running for several commits.
test-core:
	tools/check-suites.sh

# Lint, types and message catalogues. Fast, needs nothing running, and catches
# the class of mistake the browser test cannot see: a message a locale is
# missing, a placeholder a translator dropped, an accessibility rule broken.
test-static:
	@cd ui && npm run check

# The browser test needs both halves running, so it starts the server it is
# about to drive rather than assuming one is up. No --ui: this exercises the
# UI compiled into the binary, which is what actually ships.
test-ui:
	@dune build ocaml/server/bin/main.exe
	@./_build/default/ocaml/server/bin/main.exe \
	  --port $(PORT) --basemap basemap --no-open & \
	  echo $$! > .server.pid; \
	  trap 'kill $$(cat .server.pid) 2>/dev/null; rm -f .server.pid' EXIT; \
	  for i in $$(seq 40); do \
	    curl -sf -o /dev/null http://127.0.0.1:$(PORT)/healthz && break; sleep 0.25; \
	  done; \
	  cd ui && node test/e2e.mjs http://127.0.0.1:$(PORT)

# No --ui: the binary serves the UI it was built with. Pass --ui to override
# with a directory, which is what `npm run dev` wants.
run: build
	./_build/default/ocaml/server/bin/main.exe --port $(PORT) --basemap basemap

package: build
	tools/package.sh

clean:
	dune clean
	$(MAKE) -C fstar clean
	rm -rf ui/dist ui/node_modules ocaml/server/ui_dist dist
