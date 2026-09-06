# SepiaOS - the Rust toolchain for the target
#
# Fetches the official Rust toolchain built for aarch64-unknown-linux-musl,
# verifies it against upstream's own digests, strips it to what a SepiaOS card
# wants, and republishes it as one asset - so the Pi carries rustc and cargo
# beside the clang from ../llvm and the make from ../make.
#
#   make sources        download and verify the components
#   make stage          assemble what ships
#   make stage-check    prove it is aarch64 and complete
#   make help           every target
#
# WHY THIS IS A DOWNLOAD AND NOT A BUILD
#
# aarch64-unknown-linux-musl is a Tier 2 Rust target *with host tools*, so
# upstream publishes rustc, cargo and the standard library built to run on it:
# 156 MiB of tarballs that are exactly the thing this repository would spend
# four hours producing. Cross-building rustc with x.py needs a host Rust, a C++
# cross-toolchain and its own LLVM, takes hours per run, and would sit against
# GitHub's six-hour job limit in CI - to arrive at the same programs, built
# from the same sources, by a less tested route.
#
# ../boot makes the same call about the Raspberry Pi firmware: upstream builds
# it, this project verifies and repackages it. What this repository adds is the
# verification, the pruning, and a release the rest of SepiaOS can pin.
#
# No cross-toolchain is downloaded here, and nothing is compiled. That is the
# whole point, and it is why this is the only repository in the family that
# needs neither a compiler nor 600 MiB of toolchain to produce its asset.

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

# Make 3.81 (still /usr/bin/make on macOS) compares timestamps only to the
# second and silently reuses stale outputs after a fast edit.
ifeq ($(filter 4.% 5.%,$(MAKE_VERSION)),)
$(error GNU Make >= 4.0 required, found $(MAKE_VERSION). On macOS: brew install make, then run gmake)
endif

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

# --retry-all-errors is load-bearing rather than decoration: ../llvm measured
# four consecutive single-shot fetches of an upstream tarball failing, two with
# a TLS handshake error, which plain --retry does not class as transient and
# therefore will not retry. These are 115 MiB downloads.
CURL   := curl --fail --silent --show-error --location \
                --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors
SHA256 := $(shell command -v sha256sum >/dev/null 2>&1 && echo "sha256sum" || echo "shasum -a 256")

DL_DIR    := downloads
BUILD_DIR := build
DIST_DIR  := dist
CHECKSUMS := checksums

JOBS ?= $(shell sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# Overriding a variable on the command line changes what gets built but touches
# no file, so Make cannot see it. Each expensive tree therefore carries a
# signature of the settings that determine its contents, rewritten only when it
# actually changes so that it works as an ordinary prerequisite.
.PHONY: FORCE
FORCE:

# $(1) stamp path, $(2) signature
define config_stamp_rule
$(1): FORCE
	@mkdir -p $$(@D)
	@printf '%s\n' '$(2)' | cmp -s - $$@ || printf '%s\n' '$(2)' > $$@
endef

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The upstream release to ship. Empty means "whatever `stable` currently is",
# resolved once from upstream's own channel manifest and then cached in
# build/version.env - the same shape ../rootfs uses for the boot release.
# `make version-update` moves it.
#
# Pinning is the default because a release asset has to say which version it
# is, and because "the toolchain changed under us" is not something to discover
# from a card.
RUST_VERSION ?= 1.98.1
RUST_BASE    := https://static.rust-lang.org/dist

# The version as a *make* variable, which is what names the asset and what
# `make -s print-DIST_ASSET` has to answer with. When RUST_VERSION is pinned it
# is that; when it is empty it is read back out of the resolved env file, which
# by then exists because everything that uses it depends on it.
#
# Reading it as $$RUST_VER in the recipe instead does not work, and failed
# quietly: DIST_ASSET is expanded by make before the shell ever runs, so the
# first asset came out named sepiaos-rust--aarch64-musl.tar.xz.
RUST_VER = $(or $(RUST_VERSION),$(shell sed -n "s/^RUST_VER='\(.*\)'/\1/p" $(VERSION_ENV) 2>/dev/null))

# The one target that matters here. It is the *host* triple of the toolchain
# being fetched - these are the programs that run on the Pi - and it is also
# the target they compile for by default, because a native toolchain's host and
# target are the same thing.
RUST_TARGET := aarch64-unknown-linux-musl

# Three of upstream's components, and deliberately not the fourth. rustc, cargo
# and the standard library are what compiles a program; rust-docs is 60 MiB of
# HTML that no card is going to read, and the source component (rust-src) is
# only needed to rebuild core for a different target.
COMPONENTS := rustc cargo rust-std

# Where the toolchain lands on the device. rustc finds its own sysroot by
# walking up from the executable, so /usr/bin/rustc looks in /usr/lib/rustlib -
# which is exactly where these components install.
PREFIX ?= /usr

# 22 MiB of HTML and man pages that a headless card has no reader for. Both are
# in the upstream components; both are dropped unless asked for.
WITH_DOCS     ?= 0
WITH_MANPAGES ?= 0

# ---------------------------------------------------------------------------
# Step 1 - resolve the version
#
# Only consulted when RUST_VERSION is empty. The channel manifest is TOML and
# the answer is the `version` of the `[pkg.rust]` section - not the first
# `version` in the file, which belongs to whichever package sorts first (0.99.0
# for one of the tools, as it happens, which is exactly the kind of number that
# would sail through a looser grep).
# ---------------------------------------------------------------------------

VERSION_ENV := $(BUILD_DIR)/version.env
VERSION_CFG := $(BUILD_DIR)/.version-config
VERSION_SIG  = $(RUST_VERSION)|$(RUST_BASE)|env1
$(eval $(call config_stamp_rule,$(VERSION_CFG),$(VERSION_SIG)))

$(VERSION_ENV): $(VERSION_CFG)
	@mkdir -p $(@D)
	@if [ -n '$(RUST_VERSION)' ]; then \
	   v='$(RUST_VERSION)'; \
	   echo "  VERSION  rust $$v (pinned)"; \
	 else \
	   echo "  RESOLVE  rust stable ($(RUST_BASE)/channel-rust-stable.toml)"; \
	   v=$$($(CURL) "$(RUST_BASE)/channel-rust-stable.toml" \
	        | awk '/^\[pkg\.rust\]/{f=1} f&&/^version[[:space:]]*=/{print; exit}' \
	        | sed -n 's/^version[[:space:]]*=[[:space:]]*"\([0-9][0-9A-Za-z.-]*\).*/\1/p'); \
	   [ -n "$$v" ] || { \
	     echo "Could not read the stable version from the channel manifest." >&2; \
	     echo "Pin one with RUST_VERSION=." >&2; exit 1; }; \
	   echo "  VERSION  rust $$v (current stable)"; \
	 fi; \
	 [[ "$$v" =~ ^[0-9][0-9A-Za-z.-]*$$ ]] || { echo "Refusing rust version '$$v'." >&2; exit 1; }; \
	 printf "RUST_VER='%s'\n" "$$v" > $@.part
	@mv -f $@.part $@

.PHONY: version
version: $(VERSION_ENV) ## Resolve which Rust version this build ships
	@source $(VERSION_ENV); echo "  READY    rust $$RUST_VER"

.PHONY: version-update
version-update: ## Re-resolve the current stable version
	@rm -f $(VERSION_ENV)
	@$(MAKE) --no-print-directory version

# Moving the pin is a commit, which is the whole point of pinning - so it is a
# target rather than something a person does with an editor and then forgets
# the second half of. The second half is the digest: a bump that changes
# RUST_VERSION without recording checksums/rust-<new>.sha256 leaves the new
# version unpinned until somebody happens to build it, and the file it needs is
# written by `sources` on first fetch.
#
# The Makefile is rewritten through a temporary file rather than `sed -i`,
# which BSD and GNU spell differently. The sub-make then re-reads the edited
# file, which is how `sources` fetches the *new* version rather than the one
# this invocation started with.
#
# .github/workflows/update.yml is the only automated caller: it runs this,
# commits both files and opens a pull request. Nothing here publishes anything.
.PHONY: bump
bump: ## Move the pin to VERSION= and record that version's digests
	@[ -n '$(VERSION)' ] || { echo "Usage: make bump VERSION=1.99.0" >&2; exit 1; }
	@[[ '$(VERSION)' =~ ^[0-9][0-9A-Za-z.-]*$$ ]] \
	  || { echo "Refusing version '$(VERSION)': not a plain version number." >&2; exit 1; }
	@grep -q '^RUST_VERSION ?= ' Makefile \
	  || { echo "  FAIL     no 'RUST_VERSION ?= ' line in the Makefile to move" >&2; exit 1; }
	@old=$$(sed -n 's/^RUST_VERSION ?= //p' Makefile); \
	 if [ "$$old" = '$(VERSION)' ]; then \
	   echo "  READY    RUST_VERSION is already $(VERSION)"; exit 0; \
	 fi; \
	 sed 's/^RUST_VERSION ?= .*/RUST_VERSION ?= $(VERSION)/' Makefile > Makefile.bump; \
	 mv -f Makefile.bump Makefile; \
	 echo "  BUMP     RUST_VERSION $$old -> $(VERSION)"
	@$(MAKE) --no-print-directory sources
	@echo "  READY    pinned to $(VERSION); commit the Makefile and checksums/"

# ---------------------------------------------------------------------------
# Step 2 - the components
#
# Upstream publishes a `.sha256` beside every tarball, so - unlike ../make and
# ../llvm, which have to record their own - these are checked against the
# producer's own digest on every fetch. The file is `<hex>  <filename>` in the
# format sha256sum reads, and it is downloaded fresh each time rather than
# committed: a digest that travels with the file it describes is worth exactly
# as much as the transport, which is why the *version* is pinned here and the
# digest is only there to catch a truncated download.
#
# checksums/ therefore records what was actually fetched, on first fetch, and
# is committed. That is the pin that means something: it is this repository
# saying "1.98.1 is these bytes", and it is what makes a later fetch of the
# same version reproducible rather than merely well-formed.
# ---------------------------------------------------------------------------

DL_RUST := $(DL_DIR)/rust
SRC_DIR := $(BUILD_DIR)/src

.PHONY: sources
sources: $(VERSION_ENV) ## Download and verify rustc, cargo and the standard library
	@source $(VERSION_ENV); $(call fetch_components,$$RUST_VER)
	@source $(VERSION_ENV); \
	 printf '  READY    rust %s: %s\n' "$$RUST_VER" \
	   "$$(du -sh $(DL_RUST)/$$RUST_VER | cut -f1)"

# $(1) version
define fetch_components
	set -e; v=$(1); d=$(DL_RUST)/$$v; mkdir -p "$$d" $(CHECKSUMS); \
	m=$(abspath $(CHECKSUMS))/rust-$$v.sha256; \
	for c in $(COMPONENTS); do \
	  t=$$c-$$v-$(RUST_TARGET).tar.xz; \
	  if [ ! -f "$$d/$$t" ]; then \
	    echo "  FETCH    $$t"; \
	    $(CURL) -o "$$d/$$t.part" "$(RUST_BASE)/$$t" || { \
	      echo "  FAIL     could not fetch $$t - is $$v published for $(RUST_TARGET)?" >&2; \
	      exit 1; }; \
	    mv -f "$$d/$$t.part" "$$d/$$t"; \
	  fi; \
	  if [ ! -f "$$d/$$t.sha256" ]; then \
	    $(CURL) -o "$$d/$$t.sha256.part" "$(RUST_BASE)/$$t.sha256"; \
	    mv -f "$$d/$$t.sha256.part" "$$d/$$t.sha256"; \
	  fi; \
	  echo "  VERIFY   $$t (upstream digest)"; \
	  ( cd "$$d" && $(SHA256) --check --quiet "$$t.sha256" ) || { \
	    echo "  FAIL     $$t does not match upstream's own digest; delete $$d and retry" >&2; \
	    exit 1; }; \
	done; \
	if [ -f "$$m" ]; then \
	  echo "  VERIFY   against $(CHECKSUMS)/rust-$$v.sha256"; \
	  ( cd "$$d" && $(SHA256) --check --quiet "$$m" ) || { \
	    echo "  FAIL     the components do not match the committed pin for $$v" >&2; exit 1; }; \
	else \
	  ( cd "$$d" && $(SHA256) *-$$v-$(RUST_TARGET).tar.xz ) > "$$m"; \
	  echo "  RECORD   $(CHECKSUMS)/rust-$$v.sha256 - first fetch of this version, commit it"; \
	fi
endef

.PHONY: sources-info
sources-info: $(VERSION_ENV) ## Show the downloaded components and their digests
	@source $(VERSION_ENV); \
	 echo "  version  $$RUST_VER"; \
	 echo "  target   $(RUST_TARGET)"; \
	 echo "  from     $(RUST_BASE)"; \
	 ls -lh $(DL_RUST)/$$RUST_VER/*.tar.xz | awk '{printf "  archive  %-52s %s\n", $$NF, $$5}'; \
	 sed 's/^/  sha256   /' $(CHECKSUMS)/rust-$$RUST_VER.sha256

.PHONY: verify-downloads
verify-downloads: $(VERSION_ENV) ## Check the components against the committed digests
	@source $(VERSION_ENV); m=$(abspath $(CHECKSUMS))/rust-$$RUST_VER.sha256; \
	 test -f "$$m" || { echo "No $(CHECKSUMS)/rust-$$RUST_VER.sha256; run 'make sources' first." >&2; exit 1; }; \
	 ( cd $(DL_RUST)/$$RUST_VER && $(SHA256) --check --quiet "$$m" ); \
	 echo "  OK       $(CHECKSUMS)/rust-$$RUST_VER.sha256"

# ---------------------------------------------------------------------------
# Step 3 - stage what ships
#
# Each upstream tarball is a rustup package: a `components` file naming the
# component directories inside it, an `install.sh`, and each component holding
# the tree that goes under the prefix plus a `manifest.in` listing it.
#
# install.sh is deliberately not run. It is a host installer - it writes
# manifest files into the destination so that a later `--uninstall` can undo
# itself, and it would be recording that bookkeeping about a directory that is
# about to become somebody else's root filesystem. Copying the component tree
# is what every distribution packager does with these, and `components` is read
# rather than assumed so a package that grows a second component still works.
#
# What is dropped, and why:
#
#   share/doc     16 MiB of HTML, including a 14.7 MiB COPYRIGHT.html. A
#                 headless card has no reader for it. WITH_DOCS=1 keeps it -
#                 the licence text itself is kept either way, below.
#   share/man     no man reader on the card either. WITH_MANPAGES=1 keeps it.
#   rust-gdb,     three wrapper scripts for gdb, gdbgui and lldb, none of which
#   rust-gdbgui,  is on a SepiaOS card. Four kilobytes, and a command that can
#   rust-lldb     only fail is worth less than no command - the same call
#                 ../e2fsprogs makes about e2scrub.
#   rust-lld      147 MiB, and the card already has ld.lld from ../llvm. It is
#                 kept by default all the same: rustc reaches for it under
#                 -Clinker-flavor=*-lld and for targets that need a bundled
#                 linker, and a toolchain that fails at link time on a card
#                 that cannot easily be debugged is a bad trade for a flag
#                 nobody set. WITH_RUST_LLD=0 drops it and is the single
#                 biggest saving available here.
#
# Nothing is stripped by default, and that is a deliberate non-default: it
# would save 76 MiB on librustc_driver and 22 MiB on rust-lld - measured, not
# guessed - but it needs a cross `strip`, which means this repository would
# download a 132 MiB toolchain to produce an asset it otherwise compiles
# nothing for. WITH_STRIP=1 with CROSS_COMPILE pointing at one does it.
# ---------------------------------------------------------------------------

STAGE_DIR   := $(BUILD_DIR)/stage
STAGE_STAMP  = $(STAGE_DIR)/.staged
LICENSE_DIR  = $(STAGE_DIR)$(PREFIX)/share/licenses/rust

WITH_RUSTDOC  ?= 1
WITH_RUST_LLD ?= 1
WITH_STRIP    ?= 0

# Only ever used for WITH_STRIP=1; nothing else in this repository needs a
# compiler, a linker or a sysroot.
CROSS_COMPILE ?=
CROSS          = $(CROSS_COMPILE)

STAGE_CFG := $(STAGE_DIR)/.config
STAGE_SIG  = $(PREFIX)|$(WITH_DOCS)|$(WITH_MANPAGES)|$(WITH_RUSTDOC)|$(WITH_RUST_LLD)|$(WITH_STRIP)|$(COMPONENTS)
$(eval $(call config_stamp_rule,$(STAGE_CFG),$(STAGE_SIG)))

.PHONY: stage
stage: $(STAGE_STAMP) ## Unpack the components and assemble what ships
	@echo "  READY    staged $$(du -sh $(STAGE_DIR) | cut -f1) -> $(STAGE_DIR)"

$(STAGE_STAMP): $(VERSION_ENV) $(STAGE_CFG) Makefile
	@source $(VERSION_ENV); $(call fetch_components,$$RUST_VER)
	@source $(VERSION_ENV); \
	 echo "  UNPACK   $(words $(COMPONENTS)) components"; \
	 rm -rf $(SRC_DIR); mkdir -p $(SRC_DIR); \
	 for c in $(COMPONENTS); do \
	   tar -xf $(DL_RUST)/$$RUST_VER/$$c-$$RUST_VER-$(RUST_TARGET).tar.xz -C $(SRC_DIR); \
	 done
	@rm -rf $(STAGE_DIR)
	@mkdir -p $(STAGE_DIR)$(PREFIX) $(LICENSE_DIR)
	@printf '%s\n' '$(STAGE_SIG)' > $(STAGE_CFG)
	@$(call install_components)
	@$(call install_licences)
	@$(call prune_stage)
ifeq ($(WITH_STRIP),1)
	@$(call strip_stage)
endif
	@$(call assert_stage_layout)
	@touch $@

# `components` is one directory name per line. Everything in each of them goes
# under the prefix except manifest.in, which is rustup's own bookkeeping.
define install_components
	set -e; n=0; \
	for p in $(SRC_DIR)/*/; do \
	  [ -f "$$p/components" ] || { \
	    echo "  FAIL     $$p has no components file - is this a rustup package?" >&2; exit 1; }; \
	  while read -r c; do \
	    [ -n "$$c" ] || continue; \
	    [ -d "$$p/$$c" ] || { \
	      echo "  FAIL     $$p names component '$$c', which is not there" >&2; exit 1; }; \
	    ( cd "$$p/$$c" && find . -mindepth 1 -maxdepth 1 ! -name manifest.in \
	        -exec cp -R {} $(abspath $(STAGE_DIR))$(PREFIX)/ \; ); \
	    n=$$((n+1)); \
	  done < "$$p/components"; \
	done; \
	echo "  INSTALL  $$n components -> $(STAGE_DIR)$(PREFIX)"
endef

# The licence text is kept whatever WITH_DOCS says: this ships binaries of a
# dual MIT/Apache-2.0 project and its dependencies, and COPYRIGHT is where
# those are enumerated.
#
# They are taken from the *package* root - beside `components` and install.sh -
# and not from share/doc, which holds only the HTML renderings of them. The
# first version of this looked in share/doc/rust/, found nothing and stopped,
# which is the assertion doing its job. Each package carries the same
# COPYRIGHT and the same two licences, so later copies overwrite identical
# files; cargo alone adds LICENSE-THIRD-PARTY, which is why the glob is taken
# over every package rather than one.
define install_licences
	set -e; n=0; \
	for p in $(SRC_DIR)/*/; do \
	  for f in "$$p"COPYRIGHT "$$p"LICENSE-*; do \
	    [ -f "$$f" ] || continue; \
	    cp "$$f" $(LICENSE_DIR)/; n=$$((n+1)); \
	  done; \
	done; \
	[ "$$n" -gt 0 ] || { echo "  FAIL     no licence files in any component" >&2; exit 1; }; \
	echo "  LICENCE  $$(ls $(LICENSE_DIR) | tr '\n' ' ')"
endef

define prune_stage
	set -e; s=$(STAGE_DIR)$(PREFIX); \
	rm -f $$s/bin/rust-gdb $$s/bin/rust-gdbgui $$s/bin/rust-lldb; \
	$(if $(filter 1,$(WITH_DOCS)),:,rm -rf $$s/share/doc;) \
	$(if $(filter 1,$(WITH_MANPAGES)),:,rm -rf $$s/share/man;) \
	$(if $(filter 1,$(WITH_RUSTDOC)),:,rm -f $$s/bin/rustdoc;) \
	$(if $(filter 1,$(WITH_RUST_LLD)),:,rm -rf $$s/lib/rustlib/$(RUST_TARGET)/bin;) \
	find $$s -type d -empty -delete; \
	echo "  PRUNE    docs=$(WITH_DOCS) manpages=$(WITH_MANPAGES) rustdoc=$(WITH_RUSTDOC) rust-lld=$(WITH_RUST_LLD)"
endef

# ELF files only, found by magic rather than by name: `file` is absent from a
# slim Debian image and the two `file`s word their answers differently anyway.
# Symlinks are skipped by -type f, so nothing is stripped twice and no link is
# broken by the rename strip does internally.
define strip_stage
	set -e; \
	[ -n '$(CROSS_COMPILE)' ] || { \
	  echo "  FAIL     WITH_STRIP=1 needs CROSS_COMPILE=<prefix> - this repository" >&2; \
	  echo "           downloads no toolchain of its own" >&2; exit 1; }; \
	command -v $(CROSS)strip >/dev/null 2>&1 || { \
	  echo "  FAIL     no $(CROSS)strip" >&2; exit 1; }; \
	n=0; b=0; a=0; \
	while read -r f; do \
	  case "$$(od -An -N4 -tx1 "$$f" | tr -d ' ')" in 7f454c46) ;; *) continue;; esac; \
	  b=$$((b + $$(wc -c < "$$f"))); \
	  $(CROSS)strip "$$f" 2>/dev/null || true; \
	  a=$$((a + $$(wc -c < "$$f"))); \
	  n=$$((n+1)); \
	done < <(find $(STAGE_DIR) -type f); \
	echo "  STRIP    $$n files, $$((b / 1048576)) MiB -> $$((a / 1048576)) MiB"
endef

# What has to be true of the staged tree for it to be a Rust toolchain at all,
# asked of the tree rather than of the steps that filled it. ELF byte 18 is
# e_machine, little-endian, and 0xb7 is AArch64 - the same probe ../rootfs uses
# on the assets it consumes, and it needs no cross-toolchain.
#
# The rustc binary is a 72 KiB shim: it finds its sysroot by walking up from
# argv[0] and loads librustc_driver out of it, which is why the driver and the
# rustlib tree are named here as well. A tree with bin/rustc and nothing else
# would pass a naive check and fail at the first invocation on the card.
define assert_stage_layout
	set -e; s=$(STAGE_DIR)$(PREFIX); \
	for f in bin/rustc bin/cargo; do \
	  [ -x "$$s/$$f" ] || { echo "  FAIL     $$f is missing from the staged tree" >&2; exit 1; }; \
	  m=$$(od -An -tx1 -j 18 -N2 "$$s/$$f" | tr -d ' \n'); \
	  [ "$$m" = "b700" ] || { \
	    echo "  FAIL     $$f has ELF machine 0x$$m, expected b700 (AArch64)" >&2; exit 1; }; \
	  LC_ALL=C grep -aq 'ld-musl-aarch64.so.1' "$$s/$$f" \
	    || { echo "  FAIL     $$f does not ask for the musl loader" >&2; exit 1; }; \
	done; \
	ls $$s/lib/librustc_driver-*.so >/dev/null 2>&1 \
	  || { echo "  FAIL     no librustc_driver in lib/ - bin/rustc is only a shim and loads it" >&2; exit 1; }; \
	ls $$s/lib/rustlib/$(RUST_TARGET)/lib/libstd-*.rlib >/dev/null 2>&1 \
	  || { echo "  FAIL     no libstd for $(RUST_TARGET) - nothing could be compiled" >&2; exit 1; }; \
	[ -f $(LICENSE_DIR)/COPYRIGHT ] \
	  || { echo "  FAIL     COPYRIGHT is not staged; this ships binaries of a licensed project" >&2; exit 1; }; \
	c=$$(find $(STAGE_DIR) \( -name 'libc.so*' -o -name 'ld-musl-*' \) -print | head -1); \
	[ -z "$$c" ] || { \
	  echo "  FAIL     the tree carries a libc ($$c); the card's musl comes from Sepia-OS/musl" >&2; exit 1; }
endef

.PHONY: stage-check
stage-check: $(STAGE_STAMP) ## Verify the staged toolchain is aarch64 and complete
	@$(call assert_stage_layout)
	@echo "  OK       rustc, cargo, librustc_driver, libstd and the licence are in place"
	@echo "  READY    $$(du -sh $(STAGE_DIR) | cut -f1) staged for $(RUST_TARGET)"

.PHONY: stage-info
stage-info: $(STAGE_STAMP) ## Show what the staged tree contains and what it weighs
	@source $(VERSION_ENV); echo "  version  rust $$RUST_VER"
	@echo "  target   $(RUST_TARGET)"
	@echo "  stage    $(STAGE_DIR)"
	@echo "  size     $$(du -sh $(STAGE_DIR) | cut -f1)"
	@echo "  stripped $(if $(filter 1,$(WITH_STRIP)),yes,no)"
	@printf '  programs %s\n' "$$(ls $(STAGE_DIR)$(PREFIX)/bin | tr '\n' ' ')"
	@du -sh $(STAGE_DIR)$(PREFIX)/lib/rustlib/$(RUST_TARGET)/* 2>/dev/null \
	  | sed 's|$(STAGE_DIR)$(PREFIX)/|  rustlib  |'
	@find $(STAGE_DIR) -type f -size +20M \
	  | sed "s|$(STAGE_DIR)$(PREFIX)/|  large    |" | sort

# ---------------------------------------------------------------------------
# Step 4 - the release asset
#
# The staged tree, tarred and compressed: exactly what rootfs unpacks into the
# root filesystem. Sibling repositories consume each other's *published
# releases* rather than each other's build trees.
#
# This is by a wide margin the largest asset in the family - the toolchain is
# most of a gigabyte unpacked, against 196 MiB for ../llvm and 666 KB for
# ../musl. `dist-info` prints both numbers, because the compressed one is what
# a release page shows and the *unpacked* one is what has to fit on the card.
# ---------------------------------------------------------------------------

DIST_TAG   ?=
DIST_ASSET  = sepiaos-rust-$(RUST_VER)-aarch64-musl$(if $(DIST_TAG),-$(DIST_TAG)).tar.xz
DIST_SUMS  := SHA256SUMS

.PHONY: dist
dist: $(STAGE_STAMP) ## Pack the staged tree into dist/ as a release asset
	@mkdir -p $(DIST_DIR)
	@echo "  PACK     $(DIST_ASSET) (725 MiB through xz -9; this takes minutes)"
	@tar -C $(STAGE_DIR) --exclude=./.staged --exclude=./.config -cf - . \
	  | xz -9 -T0 -c > $(DIST_DIR)/$(DIST_ASSET).part
	@mv -f $(DIST_DIR)/$(DIST_ASSET).part $(DIST_DIR)/$(DIST_ASSET)
	@( cd $(DIST_DIR) && $(SHA256) $(DIST_ASSET) > $(DIST_SUMS) )
	@echo "  READY    $$(du -h $(DIST_DIR)/$(DIST_ASSET) | cut -f1) -> $(DIST_DIR)/$(DIST_ASSET)"

.PHONY: dist-info
dist-info: ## Show the packed asset, its digest and what it costs on the card
	@test -f $(DIST_DIR)/$(DIST_ASSET) \
	  || { echo "No $(DIST_DIR)/$(DIST_ASSET); run 'make dist' first." >&2; exit 1; }
	@echo "  asset    $(DIST_DIR)/$(DIST_ASSET)"
	@du -h $(DIST_DIR)/$(DIST_ASSET) | sed 's/^/  size     /' | cut -f1,2
	@sed 's/^/  sha256   /' $(DIST_DIR)/$(DIST_SUMS)
	@echo "  unpacked $$(du -sh $(STAGE_DIR) | cut -f1) - this is what has to fit on the card"
	@echo "  entries  $$(tar -tf $(DIST_DIR)/$(DIST_ASSET) | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Remove build output (keeps downloads)
	rm -rf $(BUILD_DIR)

.PHONY: distclean
distclean: clean ## Also remove the downloaded components
	rm -rf $(DL_DIR) $(DIST_DIR)

# Read one variable's value, for scripts and CI: make -s print-DIST_ASSET
print-%:
	@echo '$($*)'

.PHONY: help
help: ## Show this help
	@echo "SepiaOS Rust toolchain"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z0-9_-]+([ ]+[a-zA-Z0-9_-]+)*:.*?## ' $(MAKEFILE_LIST) \
	  | sed 's/:.*## /|/' \
	  | awk -F'|' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Variables:"
	@printf "  %-18s %s\n" \
	  "RUST_VERSION"     "upstream release to ship, empty for current stable (default $(RUST_VERSION))" \
	  "PREFIX"           "where the toolchain lands on the device (default $(PREFIX))" \
	  "WITH_RUSTDOC"     "ship rustdoc, 15 MiB (default $(WITH_RUSTDOC))" \
	  "WITH_RUST_LLD"    "ship rust-lld, 147 MiB (default $(WITH_RUST_LLD))" \
	  "WITH_DOCS"        "ship share/doc, 16 MiB of HTML (default $(WITH_DOCS))" \
	  "WITH_MANPAGES"    "ship share/man (default $(WITH_MANPAGES))" \
	  "WITH_STRIP"       "strip the staged files; needs CROSS_COMPILE (default $(WITH_STRIP))" \
	  "CROSS_COMPILE"    "tool prefix, only ever used by WITH_STRIP=1" \
	  "DIST_TAG"         "release tag to name the asset after" \
	  "JOBS"             "unused here; nothing is compiled"
	@echo
	@echo "Examples:"
	@echo "  make sources                         download and verify the components"
	@echo "  make stage-check                     assemble it and read it back"
	@echo "  make RUST_VERSION= version-update    ask upstream what stable is now"
	@echo "  make bump VERSION=1.99.0             move the pin and record its digests"
	@echo "  make WITH_RUST_LLD=0 stage           147 MiB smaller; the card has ld.lld"
	@echo "  make dist                            pack it as a release asset"
