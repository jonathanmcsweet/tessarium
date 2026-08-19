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
# A second server instance the e2e downloads its basemap from.
FIXTURE_PORT ?= 7374
MULTIPART_PORT ?= 7375
# Its source disagrees with its archive about tile compression, which the
# server must refuse rather than write.
MISMATCH_PORT ?= 7376
# Downloads through a deliberately slow proxy, so one can be cancelled
# halfway on purpose rather than by luck.
CANCEL_PORT ?= 7377
# The delaying proxy itself, run by the e2e script.
PROXY_PORT ?= 7378

.PHONY: all env verify extract build ui test test-core test-static test-extraction test-lowstar test-ui run package package-deb package-appimage clean

# The wall's stages share files (gen_check outputs, .checked caches, the
# port 737x range); they are cheap to run in order and wrong to interleave.
.NOTPARALLEL:

all: build ui

env:
	@echo 'export PATH=$(FSTAR_BIN):$$PATH'
	@echo 'eval "$$(opam env --switch=$(SWITCH))"'
	@echo 'export NVM_DIR="$$HOME/.nvm"; . "$$NVM_DIR/nvm.sh"'
	@echo '# eval "$$(make env)" to apply'

verify:
	$(MAKE) -C fstar verify

# The one test anywhere that EXECUTES the F*: the extracted core's answers,
# recomputed inside F*'s own evaluator from the proved source. Slow (~3
# minutes, almost all of it the grid-touching points), which is why it
# is its own target -- but it is the only bridge across the trusted
# extraction pipeline that does not itself trust that pipeline.
test-extraction:
	dune build ocaml/tools/gen_check.exe
	./_build/default/ocaml/tools/gen_check.exe \
	  fstar/check/Tessarium.Check.Expected.fst
	PATH="$(FSTAR_BIN):$$PATH" $(MAKE) -C fstar check-extraction

# Regenerating extracted OCaml is the only sanctioned way to change it. CI
# runs this and fails on any diff, which is what makes "never hand-edit
# extracted code" enforceable rather than merely stated.
extract:
	$(MAKE) -C fstar extract

# The machine-integer Feistel, proved equal to the spec and emitted as C by
# KaRaMeL, replaying the vectors the evaluator leg re-derives. Fast (~30s):
# the agreement is a theorem discharged in low-verify; this compiles the
# emitted C and lets it answer for the same numbers as everyone else.
KRML_ROOT := $(FSTAR_BIN)/..
test-lowstar:
	dune build ocaml/tools/gen_check.exe
	./_build/default/ocaml/tools/gen_check.exe - fstar/low/check_vectors.h
	PATH="$(FSTAR_BIN):$$PATH" $(MAKE) -C fstar low-extract
	@mkdir -p _build
	cc -std=c11 -Wall -D_DEFAULT_SOURCE \
	  -I fstar/low/out -I fstar/low \
	  -I "$(KRML_ROOT)/include/krml" -I "$(KRML_ROOT)/lib/krml/dist/minimal" \
	  fstar/low/out/Tessarium_Low_Feistel.c fstar/low/out/Tessarium_Low_Grid.c \
	  fstar/low/out/Tessarium_Low_Check.c \
	  fstar/low/check_main.c -o _build/low_check
	./_build/low_check

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

test: test-core test-static test-extraction test-lowstar test-ui

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
#
# Two instances. The one under test starts with an EMPTY basemap directory
# and downloads its tiles, in-app, from the second, which serves a generated
# fixture archive -- so the e2e drives the whole region downloader against
# this project's own Range implementation, with no external network.
#
# The e2e runs in a subshell: the EXIT trap reads the .pid files relative to
# the repo root, and a bare `cd ui` would leave the trap there -- its kills
# would fail and the leaked servers would outlive the test, holding any pipe
# on our output open forever.
test-ui:
	@dune build ocaml/server/bin/main.exe ocaml/tools/gen_basemap_fixture.exe
	@rm -rf _build/e2e-fixture _build/e2e-basemap _build/e2e-multipart \
	  _build/e2e-mismatch _build/e2e-cancel \
	  && mkdir -p _build/e2e-basemap _build/e2e-multipart _build/e2e-mismatch \
	  _build/e2e-cancel
	@./_build/default/ocaml/tools/gen_basemap_fixture.exe _build/e2e-fixture
	@cp _build/e2e-fixture/map-shallow.pmtiles _build/e2e-mismatch/map.pmtiles
	@./_build/default/ocaml/server/bin/main.exe \
	  --port $(FIXTURE_PORT) --basemap _build/e2e-fixture --no-open & \
	  echo $$! > .fixture.pid; \
	  ./_build/default/ocaml/server/bin/main.exe \
	  --port $(PORT) --basemap _build/e2e-basemap --no-open \
	  --basemap-source http://127.0.0.1:$(FIXTURE_PORT)/basemap/map.pmtiles \
	  --basemap-assets http://127.0.0.1:$(FIXTURE_PORT)/basemap/assets.tar.gz & \
	  echo $$! > .server.pid; \
	  ./_build/default/ocaml/server/bin/main.exe \
	  --port $(MULTIPART_PORT) --basemap _build/e2e-multipart --no-open \
	  --tile-budget 1024,256,8,1 \
	  --basemap-source http://127.0.0.1:$(FIXTURE_PORT)/basemap/map.pmtiles \
	  --basemap-assets http://127.0.0.1:$(FIXTURE_PORT)/basemap/assets.tar.gz & \
	  echo $$! > .multipart.pid; \
	  ./_build/default/ocaml/server/bin/main.exe \
	  --port $(MISMATCH_PORT) --basemap _build/e2e-mismatch --no-open \
	  --basemap-source http://127.0.0.1:$(FIXTURE_PORT)/basemap/map-raw.pmtiles \
	  --basemap-assets http://127.0.0.1:$(FIXTURE_PORT)/basemap/assets.tar.gz & \
	  echo $$! > .mismatch.pid; \
	  ./_build/default/ocaml/server/bin/main.exe \
	  --port $(CANCEL_PORT) --basemap _build/e2e-cancel --no-open \
	  --tile-budget 64,16,16 \
	  --basemap-source http://127.0.0.1:$(PROXY_PORT)/basemap/map-slow.pmtiles \
	  --basemap-assets http://127.0.0.1:$(FIXTURE_PORT)/basemap/assets.tar.gz & \
	  echo $$! > .cancel.pid; \
	  trap 'kill $$(cat .server.pid) $$(cat .fixture.pid) \
	      $$(cat .multipart.pid) $$(cat .mismatch.pid) \
	      $$(cat .cancel.pid) 2>/dev/null; \
	    rm -f .server.pid .fixture.pid .multipart.pid .mismatch.pid \
	      .cancel.pid' EXIT; \
	  for i in $$(seq 40); do \
	    curl -sf -o /dev/null http://127.0.0.1:$(PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(FIXTURE_PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(MULTIPART_PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(MISMATCH_PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(CANCEL_PORT)/healthz \
	    && break; sleep 0.25; \
	  done; \
	  ( cd ui && E2E_PROXY_PORT=$(PROXY_PORT) \
	      E2E_FIXTURE=http://127.0.0.1:$(FIXTURE_PORT) \
	      node test/e2e.mjs http://127.0.0.1:$(PORT) \
	      http://127.0.0.1:$(MULTIPART_PORT) http://127.0.0.1:$(MISMATCH_PORT) \
	      http://127.0.0.1:$(CANCEL_PORT) )

# No --ui: the binary serves the UI it was built with. Pass --ui to override
# with a directory, which is what `npm run dev` wants.
run: build
	./_build/default/ocaml/server/bin/main.exe --port $(PORT) --basemap basemap

package: build
	tools/package.sh

package-deb: build
	tools/package-deb.sh

package-appimage: build
	tools/package-appimage.sh

clean:
	dune clean
	$(MAKE) -C fstar clean
	rm -rf ui/dist ui/node_modules ocaml/server/ui_dist dist
