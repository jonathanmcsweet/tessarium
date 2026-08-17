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
FSTAR_FLAGS := --warn_error -321

.PHONY: all verify extract clean

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

clean:
	rm -f *.checked .depend
	rm -rf $(OUT)
