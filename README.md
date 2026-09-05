# rust-toolchain

This repository builds and provides the `rust` package for SepiaOS.

The result is `rustc`, `cargo` and the Rust standard library for
**aarch64-unknown-linux-musl**, running **on** the Pi — the Rust equivalent of
the clang from [llvm](https://github.com/Sepia-OS/llvm) and the GNU make from
[make](https://github.com/Sepia-OS/make). A card that carries it can build Rust
programs for itself.

## Why this is a download and not a build

`aarch64-unknown-linux-musl` is a Tier 2 Rust target **with host tools**, so
upstream already publishes `rustc`, `cargo` and the standard library *built to
run on it*: 156 MiB of tarballs that are exactly the thing this repository
would otherwise spend hours producing.

Cross-building `rustc` with `x.py` needs a host Rust, a C++ cross-toolchain and
its own LLVM, takes hours per run, and would sit against GitHub's six-hour job
limit in CI — to arrive at the same programs, from the same sources, by a less
tested route. [boot](https://github.com/Sepia-OS/boot) makes the same call
about the Raspberry Pi firmware: upstream builds it, this project verifies and
repackages it.

What this repository adds is the verification, the pruning, and a release the
rest of SepiaOS can pin. **Nothing is compiled here**, and no cross-toolchain
is downloaded — the only repository in the family that needs neither.

## Prerequisites

`gmake` (GNU Make ≥ 4.0), `curl`, `tar` and `xz`. That is the whole list.

```sh
brew install make xz                    # macOS
sudo apt install make curl xz-utils     # Debian / Ubuntu
```

> **On macOS, run `gmake`, not `make`.** `/usr/bin/make` is GNU Make 3.81,
> which compares file timestamps only to the whole second and will silently
> reuse a stale output after a fast edit. The Makefile refuses to run on it.

## Quick start

```sh
gmake sources       # download the components and verify them
gmake stage-check   # assemble what ships and read it back
gmake dist          # pack it as a release asset
```

Run `gmake help` for the full list.

## Targets

| Target | What it does |
|---|---|
| `help` | targets and variables (the default goal) |
| `version` | resolve which Rust version this build ships |
| `version-update` | re-resolve the current stable |
| `sources` | download `rustc`, `cargo` and `rust-std`, check them against upstream's digests and the committed pin |
| `verify-downloads` | check the components against the committed digests |
| `stage` | unpack the components, assemble the tree, prune what the card does not want |
| `stage-check` | assert aarch64, the musl loader, and that the pieces `rustc` needs at runtime are all present |
| `dist` | pack the staged tree into `dist/` with `SHA256SUMS` |
| `*-info` | which version, from where, how big |
| `clean` / `distclean` | drop `build/` / also drop `downloads/` and `dist/` |

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `RUST_VERSION` | `1.98.1` | upstream release to ship; empty resolves the current stable |
| `PREFIX` | `/usr` | where the toolchain lands on the device |
| `WITH_RUSTDOC` | `1` | ship `rustdoc` (15 MiB) |
| `WITH_RUST_LLD` | `1` | ship `rust-lld` (147 MiB) |
| `WITH_DOCS` | `0` | ship `share/doc` (16 MiB of HTML) |
| `WITH_MANPAGES` | `0` | ship `share/man` |
| `WITH_STRIP` | `0` | strip the staged files; needs `CROSS_COMPILE` |
| `DIST_TAG` | *(empty)* | release tag to name the asset after |

## What ships

```
usr/bin/rustc                      a 72 KiB shim that loads the driver below
usr/bin/cargo
usr/bin/rustdoc
usr/lib/librustc_driver-*.so       280 MiB: the compiler, with LLVM inside it
usr/lib/rustlib/aarch64-unknown-linux-musl/lib/    the standard library
usr/lib/rustlib/aarch64-unknown-linux-musl/bin/    rust-lld and the gcc-ld shims
usr/share/licenses/rust/           COPYRIGHT, LICENSE-{APACHE,MIT,THIRD-PARTY}
```

`bin/rustc` is a shim: it finds its sysroot by walking up from its own path and
loads `librustc_driver` out of it. That is why the driver and the `rustlib`
tree are asserted too — a tree with `bin/rustc` alone passes a naive check and
fails at the first invocation on the card.

**Dropped**: `share/doc` (16 MiB of HTML, including a 14.7 MiB
`COPYRIGHT.html`), `share/man`, and the `rust-gdb` / `rust-gdbgui` /
`rust-lldb` wrapper scripts — none of gdb, gdbgui or lldb is on a SepiaOS card,
and a command that can only fail is worth less than no command. The plain-text
licences are kept whatever `WITH_DOCS` says.

## The size, which is the interesting part

**725 MiB unpacked.** That is the number that matters, because it is what has
to fit on the card — and the SepiaOS image is 512 MiB with a 448 MiB root
partition. Shipping this means a much larger image, and that is `rootfs`'s
decision rather than this repository's. `dist-info` prints both the compressed
and the unpacked size for exactly that reason.

The two largest single savings, both measured:

| | |
|---|---|
| `WITH_RUST_LLD=0` | −163 MiB. The card already has `ld.lld` from `llvm`, so this ships a second copy of LLD. It is kept by default because `rustc` reaches for it under `-Clinker-flavor=*-lld`, and a toolchain that fails at link time on a card that is hard to debug is a poor trade for a flag nobody set. |
| `WITH_STRIP=1` | −98 MiB (`librustc_driver` 280→204, `rust-lld` 147→125). Off by default because it is the one thing here that needs a cross-toolchain, and this repository otherwise downloads none. Set `CROSS_COMPILE` to a prefix you already have. |

## Verification

The components are checked **twice**: against the `.sha256` upstream publishes
beside each tarball, which catches a truncated download, and against
`checksums/rust-<version>.sha256` committed here, which is this repository
saying *1.98.1 is these bytes*. The first travels with the file and is worth
what the transport is worth; the second is the pin.

A local build produces `dist/sepiaos-rust-<version>-aarch64-musl.tar.xz` and
its `SHA256SUMS`, which is what `rootfs` unpacks into the root filesystem —
siblings consume each other's published releases, never each other's build
trees.

```sh
sha256sum -c SHA256SUMS
tar -C / -xf sepiaos-rust-1.98.1-aarch64-musl.tar.xz
```

The toolchain is dynamically linked against musl, so it runs against the libc
[musl](https://github.com/Sepia-OS/musl) puts on the card. It needs a linker to
produce a binary, which is `cc` from [llvm](https://github.com/Sepia-OS/llvm) —
Rust on a card without that compiles to object files and stops.
