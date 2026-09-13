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
PORT      ?= 7373
# The app under test. Its own port, NOT $(PORT): the e2e used to reuse 7373, so
# leaving `make dev` running killed the browser suite with "Address already in
# use" partway through, which read as four unrelated download checks failing.
E2E_PORT ?= 7379
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

.PHONY: all env setup dev verify extract build ui test test-core test-static test-extraction test-lowstar test-ui run basemap print-basemap-stamp print-basemap-dir package package-deb package-rpm package-appimage test-install clean

# The stages share files (gen_check outputs, .checked caches, the 737x port
# range). Cheap to run in order, wrong to interleave.
.NOTPARALLEL:

all: build ui

# tools/env.sh holds where the toolchain is; this prints the line that applies
# it. Two spellings of that is how a shell that had sourced one still lacked
# what the other knew about.
env:
	@echo '. $(CURDIR)/tools/env.sh'
	@echo '# eval "$$(make env)" to apply'

# Toolchain, node modules, basemap, compile -- everything a bare checkout needs
# before `make run` or `make dev` can work. tools/bootstrap.sh --check reports
# without changing anything.
setup:
	tools/bootstrap.sh

verify:
	$(MAKE) -C fstar verify

# The one test anywhere that EXECUTES the F*: the extracted core's answers,
# recomputed in F*'s own evaluator from the proved source. Slow (~3 minutes,
# nearly all of it the grid-touching points), hence its own target. It is the
# only check across the extraction pipeline that does not trust that pipeline.
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

# The machine-integer core (every pure-math stage), proved equal to the spec
# and emitted as C by KaRaMeL, replaying gen_check's vectors and sweeping the
# whole band table. Fast when .checked files are warm (~30s; minutes cold).
# The agreement itself is a theorem discharged in low-verify; this compiles the
# emitted C and makes it answer for the same numbers as everyone else.
# -Wno-parentheses: KaRaMeL inlines the hash helpers into flat expressions that
# lean on C precedence, correctly, and the warning fires hundreds of times on
# that one generated file.
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

# Refresh the committed copy of the KaRaMeL emission that the side-by-side wall
# links and the server's HTTP API answers from (ocaml/c_core/vendor) --
# generated code, committed and CI-diffed like ocaml/extracted. Copies every
# emitted module except the test-only Check, so a new module cannot be silently
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
# `make test` needs only node and runs the COMMITTED module, so a local edit to
# wasm/glue.c or the vendored C is invisible to every local test until this
# target reruns. CI rebuilds and byte-diffs, which catches a stale artifact.
# wasm32-wasi for the libc headers. The module's ONE import is random_get,
# pulled in by the prebuilt libc init (crt) for its stack guard and not
# removable by our flags; the wall allow-lists exactly it, nothing else.
ZIG := $(HOME)/toolchain/zig/zig
C_CORE_SRC := $(addprefix ocaml/c_core/vendor/Tessarium_Low_,\
  Feistel.c Grid.c Codec.c Api.c Blake2s.c Core.c)
sync-wasm:
	$(ZIG) cc -target wasm32-wasi -O2 -Wl,--no-entry -mexec-model=reactor \
	  -Wl,--strip-all \
	  -I ocaml/c_core/vendor -D_DEFAULT_SOURCE \
	  -o wasm/core.wasm $(C_CORE_SRC) wasm/glue.c
	@echo "wasm/core.wasm rebuilt"

# The KDF's browser build: the vendored Argon2 reference C (the same files the
# server's FFI links) compiled by the same pinned zig. Committed like
# core.wasm; CI rebuilds and byte-diffs. ARGON2_NO_THREADS: p=1 is baked into
# the glue and thread.c is not vendored.
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
# compiles it into the server binary. dune does not depend on ui/dist directly:
# that would put ui/node_modules in its view.
ui:
	cd ui && pnpm install --frozen-lockfile && pnpm run build
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
# no browser and no package install. It holds the prose to the code: the
# message length is transcribed BY HAND into the Low* module, so nothing else
# catches a document still describing the shape a constant had before it moved
# -- which is what the project rename left behind in two files.
#
# check-deps.sh holds dune-project to the dune files, which nothing else can. A
# dependency only ever satisfied transitively builds fine on the machine that
# already has it and fails on a fresh `opam install . --deps-only`; CI cannot
# see the difference because its switch comes from cache. It is opam-dune-lint
# under a stable name, installed by tools/setup.sh on a workstation and by a
# workflow step on the runner, not from tessarium.opam, because it exists to
# check that file.
#
# check-basemap-target.sh is the build checking itself: `make run` has to open
# the app on a machine with no network, and has to notice a download that only
# half finished. Both are properties of a recipe rather than of code, so it
# runs that recipe against a stubbed fetcher, compiler and server.
#
# check-dev-setup.sh is the same shape one step out: `pnpm run dev` has to work
# on a machine that has just cloned this, and the three things it used to
# assume -- ui/node_modules, the vendored F* support library, the wasm the
# browser's worker loads -- are properties of two shell scripts. They run
# against stubs that record how they were called.
#
# CI runs THIS target rather than the list, so a check added here is a check CI
# runs.
test-core:
	tools/check-suites.sh
	node tools/check-doc-constants.mjs
	node tools/check-versions.mjs
	tools/check-deps.sh
	tools/check-basemap-target.sh
	tools/check-dev-setup.sh
	dune build @fmt

# Lint, types, message catalogues and the browser payload budgets. Fast, needs
# no server, and catches what the browser test cannot see: a message a locale
# is missing, a placeholder a translator dropped, an accessibility rule broken,
# a bundle that quietly grew by a megabyte. Needs `dune build` first --
# payload.mjs measures the bundle where dune writes it -- and `pnpm install` in
# ui/, which `make ui` does.
test-static:
	@cd ui && pnpm run check

# The browser test needs both halves running, so it starts the server it is
# about to drive rather than assuming one is up. No --ui: this exercises the UI
# compiled into the binary, which is what ships.
#
# Every one of them is pinned at a loopback upstream, the fixture server
# included. Unpinned, --basemap-source defaults to the newest Protomaps daily
# build and --basemap-assets to a GitHub tarball, so one estimate or download
# posted to the wrong port would put this suite at the mercy of two services
# nobody here runs. The fixture server is never asked for either, and is
# pinned anyway: the default it was carrying was a trap set for whoever next
# adds a check against port $(FIXTURE_PORT). ui/test/harness.mjs holds it.
#
# Several instances. The one under test starts with an EMPTY basemap directory
# and downloads its tiles, in-app, from the fixture server, which serves a
# generated archive -- so the e2e drives the whole region downloader against
# this project's own Range implementation, with no external network.
#
# The e2e runs in a subshell: the EXIT trap reads the .pid files relative to
# the repo root, and a bare `cd ui` would leave the trap there. Its kills would
# fail, and the leaked servers would outlive the test holding any pipe on our
# output open forever.
#
# Depends on `ui`: the servers below serve the EMBEDDED bundle, so without the
# refresh they would exercise whatever UI was last built into the binary, and a
# UI regression would pass against the previous good bundle.
#
# The browser is installed here rather than by the person running this. It is
# pinned by ui/package.json like any other dependency, and it is the one
# resource `tools/bootstrap.sh` leaves out -- 150 MB nobody who only wants the
# app running should pay for. Warm, the check costs a second.
test-ui: ui
	@cd ui && pnpm exec playwright install chromium
	@dune build ocaml/server/bin/main.exe ocaml/tools/gen_basemap_fixture.exe
	@rm -rf _build/e2e-fixture _build/e2e-basemap _build/e2e-multipart \
	  _build/e2e-mismatch _build/e2e-cancel \
	  && mkdir -p _build/e2e-basemap _build/e2e-multipart _build/e2e-mismatch \
	  _build/e2e-cancel
	@./_build/default/ocaml/tools/gen_basemap_fixture.exe _build/e2e-fixture
	@cp _build/e2e-fixture/map-shallow.pmtiles _build/e2e-mismatch/map.pmtiles
	@./_build/default/ocaml/server/bin/main.exe \
	  --port $(FIXTURE_PORT) --basemap _build/e2e-fixture --no-open \
	  --basemap-source http://127.0.0.1:$(FIXTURE_PORT)/basemap/map.pmtiles \
	  --basemap-assets http://127.0.0.1:$(FIXTURE_PORT)/basemap/assets.tar.gz & \
	  echo $$! > .fixture.pid; \
	  ./_build/default/ocaml/server/bin/main.exe \
	  --port $(E2E_PORT) --basemap _build/e2e-basemap --no-open \
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
	    curl -sf -o /dev/null http://127.0.0.1:$(E2E_PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(FIXTURE_PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(MULTIPART_PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(MISMATCH_PORT)/healthz \
	    && curl -sf -o /dev/null http://127.0.0.1:$(CANCEL_PORT)/healthz \
	    && break; sleep 0.25; \
	  done; \
	  ( cd ui && E2E_PROXY_PORT=$(PROXY_PORT) \
	      E2E_FIXTURE=http://127.0.0.1:$(FIXTURE_PORT) \
	      node test/e2e.mjs http://127.0.0.1:$(E2E_PORT) \
	      http://127.0.0.1:$(MULTIPART_PORT) http://127.0.0.1:$(MISMATCH_PORT) \
	      http://127.0.0.1:$(CANCEL_PORT) )

# The whole stack, for development: the server, with Vite in front of it for
# hot reload. `pnpm run dev` in ui/ is only the UI half -- Vite proxies /api,
# the basemap and both wasm modules to the server, so on its own it renders a
# gate that cannot open. tools/dev.sh starts both and stops both.
#
# No --ui here: the binary serves the UI it was built with. Pass --ui to
# override it with a directory, which is what `pnpm run dev` wants.
dev:
	tools/dev.sh

# The same world overview, glyphs and sprites the packages ship, so a checkout
# does not open on the one state an installed copy is never in.
#
# A STAMP rather than basemap/world.pmtiles itself, because the overview is not
# the whole payload: tools/fetch-basemap.sh writes it BEFORE fetching the fonts
# and sprites, so a fetch that died on the tarball left a file that satisfied
# the old file target forever -- every later `make run` skipped the recipe and
# served a map whose glyphs 404, drawing as unlabelled shapes with nothing
# saying why. The stamp is written only once both halves are on disk, so a
# half-finished fetch is retried rather than mistaken for a finished one. The
# retry is cheap: the script skips whichever half it already has.
#
# Tolerant of a failed fetch, and of TESSARIUM_NO_BASEMAP=1, which skips it
# outright -- for working offline, or for looking at the empty state on
# purpose. This is offline-first software: a machine with no network gets the
# documented empty map and its download banner, not a build failure. That rule
# lives here, and tools/dev.sh calls this target rather than restating it.
# Outside the checkout, at the path tools/basemap-dir.sh decides and the
# installed launchers already use. Downloaded maps are user data: a gitignored
# directory inside the tree is deleted by anything that cleans build output,
# and a re-clone took a 666 MB region that way with nothing said about it.
# BASEMAP_DIR=... overrides it for one command, TESSARIUM_BASEMAP for a shell.
BASEMAP_DIR ?= $(shell tools/basemap-dir.sh)
# The depth the packages ship, asked of the script that fetches it. The stamp
# is named after it, so raising the shipped depth retires every stamp written
# at the old one and the deeper planet is fetched once, everywhere, without
# anyone having to know to delete a file.
WORLD_ZOOM := $(shell tools/fetch-basemap.sh --print-world-zoom)
BASEMAP_STAMP := $(BASEMAP_DIR)/.fetched-z$(WORLD_ZOOM)
# What "a complete map" means, written once and used twice: to decide whether
# there is anything to fetch, and whether the fetch may be recorded. Two
# spellings of that condition is how the two could ever disagree.
#
# Deep enough, not merely present: a store filled before the shipped depth
# rose holds a flatter planet than an installed copy draws, and presence alone
# would keep it. The helper says nothing and fails when there is no archive to
# read, which is why the default is a zoom no archive can have.
BASEMAP_HAVE := [ -d "$(BASEMAP_DIR)/fonts" ] && [ -d "$(BASEMAP_DIR)/sprites" ] \
  && [ "$$(tools/archive-max-zoom.sh "$(BASEMAP_DIR)/world.pmtiles" \
       2>/dev/null || echo -1)" -ge "$(WORLD_ZOOM)" ]
$(BASEMAP_STAMP):
	@mkdir -p "$(BASEMAP_DIR)"
	@# A checkout that predates the move keeps its maps in the tree. Moved
	@# rather than copied or ignored: copying doubles gigabytes, and leaving
	@# them puts real downloads back in the path of the next `git clean`.
	@# Only while the store has no complete map of its own, so a real store
	@# is never merged into by this.
	@# Parenthesised: BASEMAP_HAVE is an && chain, and a bare `!` in front of
	@# one negates its FIRST test only -- which read as "no world overview
	@# yet" and was true of a complete store, so nothing ever moved.
	@if [ -f basemap/world.pmtiles ] && ! ( $(BASEMAP_HAVE) ); then \
	  echo "basemap: moving your maps out of the checkout into $(BASEMAP_DIR)"; \
	  (cd basemap && tar cf - .) | (cd "$(BASEMAP_DIR)" && tar xf -) \
	    && rm -rf basemap \
	    && echo "basemap: moved; the checkout no longer holds map data"; \
	fi
	@if $(BASEMAP_HAVE); then \
	  echo "basemap: already here ($(BASEMAP_DIR))"; \
	elif [ "$${TESSARIUM_NO_BASEMAP:-}" = "1" ]; then \
	  echo "basemap: TESSARIUM_NO_BASEMAP=1 -- starting with an empty map"; \
	else \
	  echo "basemap: fetching the overview the packages ship (~43 MB)"; \
	  tools/fetch-basemap.sh -z "" -o "$(BASEMAP_DIR)" \
	    || echo "basemap: fetch failed -- carrying on without one" >&2; \
	fi
	@# `.fetched` is the stamp from before stamps carried a depth. It is
	@# removed once its successor is written, so a store does not collect one
	@# file per depth it has ever held.
	@if $(BASEMAP_HAVE); then \
	  touch "$@" && rm -f "$(BASEMAP_DIR)/.fetched"; \
	else \
	  echo "basemap: no complete map yet -- this will try again next time" >&2; \
	fi

# The name to ask for it by. Phony, in front of the stamp, so `make basemap`
# reads as an instruction rather than a path, and tools/bootstrap.sh has one
# thing to call.
basemap: $(BASEMAP_STAMP)

# Where the stamp is, for `tools/bootstrap.sh --check` to report on it without
# spelling the path a second time. The rule above is deliberate about what a
# half-finished fetch means; a hand-written copy of "basemap/.fetched"
# elsewhere is the start of disagreeing with it.
print-basemap-stamp:
	@echo $(BASEMAP_STAMP)

# The same, for the directory itself: tools/dev.sh has to hand it to the
# server, and a second spelling of the path is how the two start disagreeing
# about where a download went.
print-basemap-dir:
	@echo $(BASEMAP_DIR)

run: build $(BASEMAP_STAMP)
	./_build/default/ocaml/server/bin/main.exe --port $(PORT) \
	  --basemap "$(BASEMAP_DIR)"

package: build
	tools/package.sh

package-deb: build
	tools/package-deb.sh

package-appimage: build
	tools/package-appimage.sh

package-rpm: build
	tools/package-rpm.sh

# Deliberately not part of `make test`: it needs packages built, and building
# them is slower than the whole test suite. Depends on both formats rather than
# whichever happens to be present, so a machine without rpmbuild is told to
# install it instead of quietly testing half of this.
test-install: package-deb package-rpm
	tools/test-install.sh

clean:
	dune clean
	$(MAKE) -C fstar clean
	rm -rf ui/dist ui/node_modules ocaml/server/ui_dist dist
