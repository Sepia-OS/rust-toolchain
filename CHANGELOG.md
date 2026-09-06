# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases are named after the **upstream Rust version** they package: `v1.98.1`
is Rust 1.98.1 for `aarch64-unknown-linux-musl`, repackaged to run on the
Raspberry Pi.

## [Unreleased]

## [1.98.1] - 2026-09-06

### Added

- The whole build: resolve a Rust version, download `rustc`, `cargo` and
  `rust-std` for `aarch64-unknown-linux-musl`, verify them **twice** — against
  the `.sha256` upstream publishes beside each tarball and against the digest
  committed in `checksums/` — assemble what ships and pack it.
- This repackages upstream rather than building `rustc`, because
  `aarch64-unknown-linux-musl` is a Tier 2 target *with host tools*: those
  programs exist as an official download, and an `x.py` bootstrap would take
  hours to arrive at the same thing by a less tested route.
- Nothing is compiled and no cross-toolchain is downloaded — the only
  repository in the family that needs neither.
- `stage-check`, which asserts `bin/rustc` and `bin/cargo` are AArch64 on the
  musl loader and that `librustc_driver` and `libstd` are present: `bin/rustc`
  is a 72 KiB shim that loads the driver out of the sysroot beside it, so a
  tree with the programs alone passes a naive check and fails at the first
  invocation on the card.
- `WITH_RUST_LLD`, `WITH_RUSTDOC`, `WITH_DOCS`, `WITH_MANPAGES` and
  `WITH_STRIP`, with the measured cost of each in the README — the asset is
  725 MiB unpacked, which is more than every other package on the card
  together.
- CI on every commit and branch, a manual release workflow, and a weekly
  `update.yml` that checks upstream stable against the pin and opens a branch
  and a pull request when it has moved.
- `make bump VERSION=…`, which moves the pin *and* records the new version's
  digests — a bump without the digest leaves the new version unpinned.

### Fixed

- The first push left the **entire Makefile out of the repository**: the
  generated `.gitignore` was made for `…,premake-gmake`, whose section ignores
  `Makefile`. CI failed with `No rule to make target 'sources'` — a checkout
  with nothing in it to run. That section is gone, and the reason is recorded.
- The first asset was named `sepiaos-rust--aarch64-musl.tar.xz`: `DIST_ASSET`
  is expanded by make before any shell in the recipe runs, so reading the
  version as `$$RUST_VER` produced a hole where the version should be.

[Unreleased]: https://github.com/Sepia-OS/rust-toolchain/compare/v1.98.1...HEAD
[1.98.1]: https://github.com/Sepia-OS/rust-toolchain/releases/tag/v1.98.1
