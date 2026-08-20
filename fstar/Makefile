# Verification and OCaml extraction for the Tessarium core.
#
# `make verify`  proves every module, caching .checked files
# `make extract` regenerates ../ocaml/extracted from the proved source
#
# Extracted OCaml is a build artifact. Never hand-edit it; changes belong in
# the F* source or they are silently overwritten at the next extraction.

FSTAR ?= fstar.exe
OUT   := ../ocaml/extracted
ROOT  := Tessarium.Api.fst

# Warning 321 fires because the binary release keeps ulib's checked files in
# ulib.checked/ rather than beside the sources. It is cosmetic.
#
# --report_assumes error is the zero-admits rule, enforced by F* itself. An
# `admit` verifies silently and nothing else in the build fails on one, so the
# absence of proof holes has to be checked rather than assumed. Grepping the
# source for the word was the obvious alternative and is wrong: it fires on the
# word "assume" in a comment, and misses an escape hatch reached through an
# abbreviation.
FSTAR_FLAGS := --warn_error -321 --report_assumes error

.PHONY: all verify extract fstarlib check-extraction low-verify low-extract clean

all: verify

.depend: $(wildcard *.fst *.fsti)
	$(FSTAR) $(FSTAR_FLAGS) --dep full $(ROOT) --output_deps_to $@

include .depend

# F* refuses to cache a module unless every dependency, interfaces included, is
# already cached. Letting make drive the order from .depend avoids getting that
# wrong by hand.
%.checked:
	$(FSTAR) $(FSTAR_FLAGS) --cache_checked_modules $<
	@touch -c $@

verify: $(ALL_CHECKED_FILES)

# One module per invocation. `--extract` walks what F* calls a "possibly-partial
# dependency graph": a module that has an interface is loaded from that
# interface alone, so its implementation is never elaborated and silently does
# not come out. Tessarium.Table.Data is exactly that case, and it is the
# module holding the band table.
MODULES := $(basename $(wildcard Tessarium.*.fst))

extract: verify
	@mkdir -p $(OUT)
	@for m in $(MODULES); do \
	  echo "  extract $$m"; \
	  $(FSTAR) $(FSTAR_FLAGS) --codegen OCaml --odir $(OUT) \
	    --extract_module $$m $$m.fst > /dev/null || exit 1; \
	done

# F*'s own OCaml support modules, built from source with our switch rather than
# linked from its shipped objects. OCaml 5.3 compresses .cmi with zstd when the
# compiler has it; F*'s binaries were built with a zstd-enabled compiler and
# ours is not, so its .cmi files read as corrupt despite identical versions.
# Vendored into the build rather than the repository: they are upstream's, and
# reproducible from the pinned F* release.
FSTAR_ROOT   := $(dir $(shell command -v $(FSTAR)))..
SUPPORT_MODS := Prims FStar_Pervasives_Native FStar_Pervasives FStar_List_Tot_Base \
                FStar_Seq_Base FStar_Seq_Properties FStar_ImmutableArray_Base FStar_UInt8

fstarlib:
	@mkdir -p ../ocaml/fstarlib
	@for m in $(SUPPORT_MODS); do \
	  f=$$(find $(FSTAR_ROOT)/lib/fstar/ulib/ml $(FSTAR_ROOT)/lib/fstar/lib -name "$$m.ml" | head -1); \
	  test -n "$$f" || { echo "missing support module $$m"; exit 1; }; \
	  cp "$$f" ../ocaml/fstarlib/; \
	done
	@printf '%s\n' \
	  '(* Shim for the sliver of Batteries that F*'"'"'s support modules use.' \
	  '   Depending on batteries proper drags OCaml threads into the' \
	  '   js_of_ocaml bundle, where caml_thread_initialize does not exist. *)' \
	  'include List' \
	  'let split_at n l =' \
	  '  let rec go i acc = function' \
	  '    | rest when i = 0 -> (List.rev acc, rest)' \
	  '    | x :: tl -> go (i - 1) (x :: acc) tl' \
	  '    | [] -> invalid_arg "split_at"' \
	  '  in go n [] l' \
	  'let subset cmp a b = List.for_all (fun x -> List.exists (fun y -> cmp x y = 0) b) a' \
	  > ../ocaml/fstarlib/batList.ml
	@echo "  vendored $(words $(SUPPORT_MODS)) F* support modules + BatList shim"

# Cross-examination of the extracted OCaml by F* itself: check/ holds
# answers computed by the EXTRACTED core, and this makes F*'s evaluator
# recompute every one from the proved source. Deliberately NOT --use_nbe:
# assert_norm under the default call-by-name normalizer skips the unused
# lemma bindings in the code's own bodies, where call-by-value NBE would
# EXECUTE those proofs -- and ulib's arithmetic lemmas recurse on the
# magnitude of their arguments, which at this domain's size is an
# out-of-memory, not a proof.
# One fstar.exe process per Check module, by measurement rather than
# taste: the normalizer retains everything it evaluates for the lifetime
# of one module's check, and the legs together exceed memory that each
# is nowhere near alone.
# Derived from the directory, not listed by hand: a fifth check module
# dropped into check/ but forgotten here would silently never run.
# Expected is excluded because it is data the others load, not a check.
CHECK_MODULES := $(filter-out Tessarium.Check.Expected,\
                 $(basename $(notdir $(wildcard check/Tessarium.Check.*.fst))))

# --include low: Check.RealRound recomputes the REAL round function from
# the proved machine source in low/.
check-extraction: verify
	@for m in $(CHECK_MODULES); do \
	  echo "  check $$m"; \
	  $(FSTAR) $(FSTAR_FLAGS) --include check --include low check/$$m.fst || exit 1; \
	done
	@echo "the extracted core agrees with the proved source"

# --------------------------------------------------------- the KaRaMeL leg
# The machine-integer core: proved equal to the spec (low/), then emitted
# as C by krml. low/out is a build artifact, regenerated on every run; the
# committed sources are only the .fst files. check/ is on the include
# path because the Check instantiation ties itself to the harness round
# function from there.

LOW_FLAGS := $(FSTAR_FLAGS) --include low --include check

# LOW_ORDER is dependency order, leaves first: the loop refreshes
# .checked bottom-up, because a stale dependency is re-verified inline
# but its cache is NOT rewritten -- alphabetical order left Core.checked
# one run behind after any Hmac edit. The wildcard guard keeps the
# derived-not-listed discipline: a module dropped into low/ but missing
# from LOW_ORDER fails the build instead of silently never verifying.
LOW_ORDER := Tessarium.Low.Feistel Tessarium.Low.Grid \
             Tessarium.Low.Codec Tessarium.Low.Api \
             Tessarium.Low.Hmac Tessarium.Low.Core Tessarium.Low.Check
LOW_MODULES := $(wildcard low/Tessarium.Low.*.fst)

low-verify: verify
	@for m in $(basename $(notdir $(LOW_MODULES))); do \
	  echo " $(LOW_ORDER) " | grep -q " $$m " \
	    || { echo "low/$$m.fst is missing from LOW_ORDER"; exit 1; }; \
	done
	@for m in $(LOW_ORDER); do \
	  $(FSTAR) $(LOW_FLAGS) --cache_checked_modules low/$$m.fst || exit 1; \
	done

# --extract narrows codegen to our namespace: elaborating ulib's machine-int
# internals for extraction trips --report_assumes error on THEIR admits,
# which are upstream's to hold, not ours to re-litigate.
# One module per invocation: F* extracts a single root file at a time
# (fly_deps), and there are now two leaves (Check, the harness
# instantiation, and Core, the production one). Derived from LOW_MODULES:
# a module dropped into low/ is extracted or the loop fails, never
# silently skipped. krml merges the per-module .krml files.
low-extract: low-verify
	@rm -rf low/out && mkdir -p low/out
	@for m in $(LOW_ORDER); do \
	  echo "  krml-extract $$m"; \
	  $(FSTAR) $(LOW_FLAGS) --odir low/out --codegen krml \
	    --extract_module $$m low/$$m.fst > /dev/null || exit 1; \
	done
	@# No pipe on krml: a make recipe's status is the LAST command of a
	@# pipeline, and krml's fatal-warning gate (a silently dropped
	@# definition, the spike's own recorded failure mode) lives in its
	@# exit code. Quiet on success, full log on failure.
	cd low/out && { krml *.krml -skip-compilation -tmpdir . > krml.log 2>&1 \
	  || { cat krml.log; exit 1; }; } && tail -1 krml.log

clean:
	rm -f *.checked low/*.checked check/*.checked .depend
	rm -rf $(OUT) low/out
