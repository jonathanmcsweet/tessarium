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

.PHONY: all verify extract fstarlib clean

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

clean:
	rm -f *.checked .depend
	rm -rf $(OUT)
