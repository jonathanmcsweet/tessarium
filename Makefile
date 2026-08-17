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

.PHONY: all env verify extract build ui test test-core test-ui run clean

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

ui:
	cd ui && npm ci --no-audit --no-fund && npm run build

test: test-core test-ui

test-core:
	dune build @runtest --force

# The browser test needs both halves running, so it starts the server it is
# about to drive rather than assuming one is up.
test-ui:
	@dune build ocaml/server/bin/main.exe
	@./_build/default/ocaml/server/bin/main.exe \
	  --port $(PORT) --ui ui/dist --basemap basemap --no-open & \
	  echo $$! > .server.pid; \
	  trap 'kill $$(cat .server.pid) 2>/dev/null; rm -f .server.pid' EXIT; \
	  for i in $$(seq 40); do \
	    curl -sf -o /dev/null http://127.0.0.1:$(PORT)/healthz && break; sleep 0.25; \
	  done; \
	  cd ui && node test/e2e.mjs http://127.0.0.1:$(PORT)

run: build
	./_build/default/ocaml/server/bin/main.exe --port $(PORT) --ui ui/dist --basemap basemap

clean:
	dune clean
	$(MAKE) -C fstar clean
	rm -rf ui/dist ui/node_modules
