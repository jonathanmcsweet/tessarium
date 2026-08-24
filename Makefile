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

# The machine-integer core (every pure-math stage), proved equal to the
# spec and emitted as C by KaRaMeL, replaying gen_check's vectors and
# sweeping the whole band table. Fast when .checked files are warm (~30s;
# minutes cold): the agreement is a theorem discharged in low-verify; this
# compiles the emitted C and lets it answer for the same numbers as
# everyone else. -Wno-parentheses: KaRaMeL inlines the hash helpers
# into flat expressions that lean on C precedence (correctly); the
# warning fires hundreds of times on that one generated file.
KRML_ROOT := $(FSTAR_BIN)/..
test-lowstar:
	dune build ocaml/tools/gen_check.exe
	./_build/default/ocaml/tools/gen_check.exe - fstar/low/check_vectors.h
	PATH="$(FSTAR_BIN):$$PATH" $(MAKE) -C fstar low-extract
	@mkdir -p _build
	cc -std=c11 -Wall -Wno-parentheses -D_DEFAULT_SOURCE \
	  -I fstar/low/out -I fstar/low \
	  -I "$(KRML_ROOT)/include/krml" -I "$(KRML_ROOT)/lib/krml/dist/minimal" \
	  fstar/low/out/Tessarium_Low_Feistel.c fstar/low/out/Tessarium_Low_Grid.c \
	  fstar/low/out/Tessarium_Low_Codec.c fstar/low/out/Tessarium_Low_Api.c \
	  fstar/low/out/Tessarium_Low_Blake2s.c fstar/low/out/Tessarium_Low_Core.c \
	  fstar/low/out/Tessarium_Low_Check.c \
	  fstar/low/check_main.c -o _build/low_check
	./_build/low_check

# Refresh the committed copy of the KaRaMeL emission that the
# side-by-side wall links, and that the server's HTTP API now answers from
# (ocaml/c_core/vendor) -- committed
# generated code, CI-diffed like ocaml/extracted. Copies every emitted
# module except the test-only Check, so a new module cannot be silently
# skipped, and diffs the hand-pinned krml runtime headers against the
# toolchain's copies, so a hand edit to those fails here too.
sync-c-core:
	PATH="$(FSTAR_BIN):$$PATH" $(MAKE) -C fstar low-extract
	@for f in fstar/low/out/Tessarium_Low_*.c fstar/low/out/Tessarium_Low_*.h; do \
	  case $$f in *Tessarium_Low_Check*) continue ;; esac; \
	  cp $$f ocaml/c_core/vendor/ || exit 1; \
	done
	@bad=0; for h in $$(cd ocaml/c_core/vendor && find . -name "*.h" ! -name "Tessarium_Low_*"); do \
	  src="$(FSTAR_BIN)/../include/krml/$$h"; \
	  [ -f "$$src" ] || src="$(FSTAR_BIN)/../lib/krml/dist/minimal/$$h"; \
	  cmp -s "ocaml/c_core/vendor/$$h" "$$src" \
	    || { echo "vendored $$h differs from the toolchain's copy"; bad=1; }; \
	done; [ $$bad -eq 0 ]
	@echo "ocaml/c_core/vendor refreshed"

# The same vendored C, compiled to WebAssembly by a pinned zig
# (~/toolchain/zig, 0.13.0). wasm/core.wasm is committed generated code:
# `make test` needs only node, and runs the COMMITTED module -- a local
# edit to wasm/glue.c or the vendored C is invisible to every local
# test until this target reruns; CI rebuilds and byte-diffs, which is
# what catches a stale artifact. wasm32-wasi for the libc headers; the
# module's ONE import is random_get, pulled in by the prebuilt libc
# init (crt) for its stack guard -- not removable by our flags -- and
# the wall allow-lists exactly it, nothing else.
ZIG := $(HOME)/toolchain/zig/zig
C_CORE_SRC := $(addprefix ocaml/c_core/vendor/Tessarium_Low_,\
  Feistel.c Grid.c Codec.c Api.c Blake2s.c Core.c)
sync-wasm:
	$(ZIG) cc -target wasm32-wasi -O2 -Wl,--no-entry -mexec-model=reactor \
	  -Wl,--strip-all \
	  -I ocaml/c_core/vendor -D_DEFAULT_SOURCE \
	  -o wasm/core.wasm $(C_CORE_SRC) wasm/glue.c
	@echo "wasm/core.wasm rebuilt"

# The KDF's browser build: the vendored Argon2 reference C (the same files
# the server's FFI links) compiled by the same pinned zig. Committed like
# core.wasm, CI rebuilds and byte-diffs. ARGON2_NO_THREADS: p=1 is baked
# in the glue, thread.c is not vendored.
ARGON2_SRC := $(addprefix ocaml/argon2/vendor/,argon2.c core.c encoding.c ref.c) \
  ocaml/argon2/vendor/blake2/blake2b.c
sync-argon2-wasm:
	$(ZIG) cc -target wasm32-wasi -O2 -Wl,--no-entry -mexec-model=reactor \
	  -Wl,--strip-all -DARGON2_NO_THREADS \
	  -I ocaml/argon2/vendor -I ocaml/argon2/vendor/blake2 -D_DEFAULT_SOURCE \
	  -o wasm/argon2.wasm $(ARGON2_SRC) wasm/argon2_glue.c
	@echo "wasm/argon2.wasm rebuilt"

# Re-download the pinned Argon2 release and diff the vendored subset, so a
# local edit to vendor/ fails here (and in CI) instead of surviving quietly.
ARGON2_TAG := 20190702
ARGON2_SHA := daf972a89577f8772602bf2eb38b6a3dd3d922bf5724d45e7f9589b5e830442c
sync-argon2:
	@tmp=$$(mktemp -d) && cd $$tmp \
	  && curl -sL -o a.tar.gz https://github.com/P-H-C/phc-winner-argon2/archive/refs/tags/$(ARGON2_TAG).tar.gz \
	  && echo "$(ARGON2_SHA)  a.tar.gz" | sha256sum -c --quiet \
	  && tar xzf a.tar.gz && src=phc-winner-argon2-$(ARGON2_TAG) \
	  && cd - > /dev/null \
	  && bad=0 \
	  && for f in argon2.c core.c core.h encoding.c encoding.h ref.c thread.h genkat.h; do \
	       cmp -s ocaml/argon2/vendor/$$f $$tmp/$$src/src/$$f || { echo "vendored $$f differs from release $(ARGON2_TAG)"; bad=1; }; \
	     done \
	  && cmp -s ocaml/argon2/vendor/argon2.h $$tmp/$$src/include/argon2.h || { echo "vendored argon2.h differs"; bad=1; } \
	  && for f in blake2.h blake2-impl.h blake2b.c blamka-round-ref.h; do \
	       cmp -s ocaml/argon2/vendor/blake2/$$f $$tmp/$$src/src/blake2/$$f || { echo "vendored blake2/$$f differs"; bad=1; }; \
	     done \
	  && cmp -s ocaml/argon2/vendor/LICENSE $$tmp/$$src/LICENSE || { echo "vendored LICENSE differs"; bad=1; } \
	  && want="LICENSE argon2.c argon2.h blake2 core.c core.h encoding.c encoding.h genkat.h ref.c thread.h" \
	  && got=$$(ls ocaml/argon2/vendor | tr '\n' ' ' | sed 's/ $$//') \
	  && { [ "$$got" = "$$want" ] || { echo "vendor/ holds unexpected entries: $$got"; bad=1; }; } \
	  && wantb="blake2-impl.h blake2.h blake2b.c blamka-round-ref.h" \
	  && gotb=$$(ls ocaml/argon2/vendor/blake2 | tr '\n' ' ' | sed 's/ $$//') \
	  && { [ "$$gotb" = "$$wantb" ] || { echo "vendor/blake2 holds unexpected entries: $$gotb"; bad=1; }; } \
	  && rm -rf $$tmp && [ $$bad -eq 0 ]
	@echo "ocaml/argon2/vendor matches release $(ARGON2_TAG), no extra files"

build:
	dune build

# The built UI is copied where dune can see it, so the next `make build`
# compiles it into the server binary. ui/dist itself is not depended on
# directly: that would put ui/node_modules in dune's view.
ui:
	cd ui && npm ci --no-audit --no-fund && npm run build
	cp wasm/argon2.wasm ui/dist/argon2.wasm
	cp wasm/core.wasm ui/dist/core.wasm
	rm -rf ocaml/server/ui_dist
	cp -r ui/dist ocaml/server/ui_dist
	@echo "  UI copied to ocaml/server/ui_dist; run 'make build' to embed it"

test: test-core test-static test-extraction test-lowstar test-ui

# Via check-suites.sh, not `dune test` directly: dune reports failures but
# cannot tell you a suite produced no output at all, which is how the
# differential check once stopped running for several commits.
#
# check-doc-constants.mjs is here rather than in test-static because it needs
# no browser and no npm install. It holds the prose to the code: the message
# length is transcribed BY HAND into the Low* module, so nothing else can
# catch a document that still describes the shape before a constant moved --
# which is exactly what the 2026-08-23 rename left behind in two files.
test-core:
	tools/check-suites.sh
	node tools/check-doc-constants.mjs

# Lint, types, message catalogues and the browser payload budgets. Fast, needs
# no server, and catches the class of mistake the browser test cannot see: a
# message a locale is missing, a placeholder a translator dropped, an
# accessibility rule broken, a bundle that quietly grew by a megabyte. Needs
# `dune build` first -- payload.mjs measures the bundle where dune writes it --
# and `npm ci` in ui/, which `make ui` does.
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
# Depends on `ui`: the servers below serve the EMBEDDED bundle, and
# without the refresh they would greenly exercise whatever UI was last
# built into the binary -- a UI regression would pass against the
# previous good bundle.
test-ui: ui
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
