# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Status

**Implemented and green end to end.** [Makefile](Makefile) resolves a Rust version, downloads `rustc`, `cargo` and `rust-std` for `aarch64-unknown-linux-musl`, verifies them twice, assembles what ships and packs it. Verified on macOS/arm64 against 1.98.1: **725 MiB staged**, `bin/rustc`, `bin/cargo` and `bin/rustdoc` all AArch64 on the musl loader, `librustc_driver` and `libstd` in place.

**That is a layout proof, not a behavioural one**, and here the gap is real: nothing has *run* `rustc` on aarch64. A card also needs a linker before Rust can produce a binary — `cc` from `../llvm` — so "Rust works on the device" stays a claim until a board says otherwise.

What does not exist yet: a published release, and therefore a consumer. Nothing in `../rootfs` fetches this yet, and **725 MiB does not fit** on the current 512 MiB image; see the size section below before wiring it up.

## Commands

```sh
gmake help                  # every target, with the variables that steer them
gmake sources               # download the components and verify them
gmake stage-check           # assemble what ships and read it back
gmake dist                  # dist/sepiaos-rust-<version>-aarch64-musl.tar.xz
gmake stage-info            # what is in the tree and which files are the big ones
gmake RUST_VERSION= version-update   # move onto the current stable
gmake -s print-DIST_ASSET   # read any variable's value
```

The full cycle is one 156 MiB download, a copy, and several minutes of `xz -9`. There is no toolchain to fetch and nothing to compile, so `gmake stage-check` from a clean tree is a couple of minutes, nearly all of it network.

## What This Repository Is For

SepiaOS is an operating system for Raspberry Pi that reuses the kernel and firmware from Raspberry Pi OS; everything above the kernel is custom. Targets: Pi Zero 2 W, Pi 3, Pi 4, Pi 5, CM4, CM5.

The repositories are checked out side by side and opened together via [../SepiaOS.code-workspace](../SepiaOS.code-workspace). Each pushes to `git@github.com:Sepia-OS/<name>.git`:

| | |
|---|---|
| [../boot](../boot) | the FAT boot partition. The clearest model of the house style — and the other repository that repackages somebody else's binaries. |
| [../musl](../musl) | musl libc, published as a sysroot. What this toolchain runs against. |
| [../rootfs](../rootfs) | the ext4 root filesystem and the bootable image. It assembles what the others publish. |
| [../llvm](../llvm) | clang/lld cross-built to run *on* the Pi. Rust needs its `cc` to link. |
| [../make](../make) | GNU `make`, the same way. |
| [../e2fsprogs](../e2fsprogs) | the filesystem tools. |
| [../wifi](../wifi) | libnl and wpa_supplicant. |
| [../spm](../spm) | the SepiaOS package manager, in Rust. The eventual reason this exists. |
| `.` (this repo) | `rustc` and `cargo` for the card. |

## Decisions Already Taken

Each of these was open when the Makefile was written, and each is settled with evidence. Do not re-open them without new evidence.

- **This repackages upstream rather than building rustc.** `aarch64-unknown-linux-musl` is a Tier 2 target *with host tools*, so upstream publishes `rustc`, `cargo` and `rust-std` built to run on it — checked, not assumed: all three exist at `static.rust-lang.org/dist/`, 115 + 11 + 30 MiB for 1.98.1. Cross-building with `x.py` needs a host Rust, a C++ cross-toolchain and its own LLVM, takes hours per run, and would sit against GitHub's six-hour job limit — to produce the same programs from the same sources by a less tested route. `../boot` makes the same call about the Pi firmware.
- **Nothing is compiled and no cross-toolchain is downloaded.** This is the only repository in the family that needs neither, and it is worth keeping that way: the assertions use `od` on the ELF header rather than `readelf`, which is why `WITH_STRIP` is off by default and needs `CROSS_COMPILE` when it is on.
- **The version is pinned, not resolved.** `RUST_VERSION=` empty resolves the current stable from upstream's channel manifest, but the default is a pin, because a release asset has to say which version it is.
- **Three components, not four.** `rust-docs` is 60 MiB of HTML no card will read, and `rust-src` is only needed to rebuild `core` for a different target.
- **`install.sh` is not run.** It is a host installer that writes uninstall manifests into the destination — which here is about to become somebody else's root filesystem. The component trees are copied, and the `components` file is *read* rather than assumed, so a package that grows a second component still works.

## Non-Obvious Constraints

All established by running the build, and each one silently produces a broken or confusing result if violated:

- **`bin/rustc` is a 72 KiB shim.** It finds its sysroot by walking up from its own path and loads `librustc_driver-*.so` — 280 MiB — out of `lib/`. A staged tree with `bin/rustc` and nothing else passes a naive check and fails at the first invocation on the card, which is why `assert_stage_layout` names the driver and the `rustlib` tree as well.
- **`DIST_ASSET` is expanded by make, before any shell in the recipe runs.** The first version read the version as `$$RUST_VER` from the sourced env file and produced an asset called `sepiaos-rust--aarch64-musl.tar.xz` — no error, just a hole where the version should be. `RUST_VER` is a make variable now: the pin when there is one, and `sed` over the env file when there is not.
- **The plain-text licences live at the *package* root**, beside `components` and `install.sh` — not in `share/doc/rust/`, which holds only the HTML renderings. Looking in `share/doc` found nothing and the assertion stopped the build, which is the assertion doing its job. `cargo` alone adds `LICENSE-THIRD-PARTY`, so the copy globs over every package rather than one.
- **Upstream's `.sha256` is not the pin.** It travels with the file it describes, so it catches a truncated download and nothing else. `checksums/rust-<version>.sha256` is written here on first fetch and committed, and *that* is this repository saying "1.98.1 is these bytes". Both are checked on every fetch.
- **The `rustc` and `cargo` binaries are dynamically linked against musl**, so the card's libc from `../musl` has to satisfy them. The asset must never contain a libc of its own; `assert_stage_layout` refuses one.
- **Rust alone cannot link a program.** `rustc` shells out to `cc` for the final link, which on a SepiaOS card is clang from `../llvm`. A card with this package and no `llvm` compiles to object files and stops. Worth saying in any release notes.

## The Size, Which Is the Whole Problem

**725 MiB unpacked**, against a SepiaOS image of 512 MiB with a 448 MiB root partition. This does not fit, and no amount of pruning here makes it fit — `../rootfs` will need a much larger `IMAGE_SIZE_MIB` before it can carry Rust, which is that repository's decision.

The measured breakdown, and the two levers:

| | |
|---|---|
| `lib/librustc_driver-*.so` | 280 MiB — the compiler, with LLVM statically inside it |
| `lib/rustlib/<target>/bin/` | 163 MiB — `rust-lld` (147 MiB) and the `gcc-ld` shims |
| `lib/rustlib/<target>/lib/` | 147 MiB — the standard library, including a 61 MiB `libcore` `.rmeta` |
| `bin/cargo` | 44 MiB |
| `bin/rustdoc` | 15 MiB |

- **`WITH_RUST_LLD=0` saves 163 MiB**, and the card already has `ld.lld` from `../llvm`, so this ships a second copy of LLD. Kept by default anyway: `rustc` reaches for it under `-Clinker-flavor=*-lld`, and a toolchain that fails at link time on a card that is hard to debug is a poor trade for a flag nobody set.
- **`WITH_STRIP=1` saves 98 MiB** — `librustc_driver` 280→204, `rust-lld` 147→125, both measured. Off by default because it is the one thing here that needs a cross-toolchain.

## Conventions Inherited

Verified across `../boot`, `../rootfs`, `../llvm`, `../make`, `../e2fsprogs`, `../musl` and `../wifi`, and followed here:

- **`gmake`, not `make`.** Hard error below GNU Make 4.0.
- **Nothing needs root**, on macOS or Linux.
- **Directory split:** `downloads/` (immutable upstream artifacts, survive `clean`), `build/` (everything generated), `dist/`, `checksums/`.
- **A variable override touches no file, so Make cannot see it.** Hence the `FORCE` + `cmp -s` signature stamps; every `WITH_*` flag is in `STAGE_SIG`.
- **Target naming:** an aggregate goal, plus `<thing>-info` and `<thing>-check`. Every aggregate goal ends with a `READY` line whether or not anything was rebuilt.
- **The `help` target's grep pattern allows digits and underscores.**
- **`print-%` exposes any variable to CI**, which makes the names it is called with a CI contract: `DIST_ASSET`, `RUST_VER`, `RUST_VERSION`, `RUST_TARGET`.
- **`.SHELLFLAGS := -eu -o pipefail`.**
- **ELF files are recognised by their magic, not by `file`** — `file` is absent from `debian:trixie-slim` and the two implementations word their answers differently.
- **The `.gitignore` deliberately omits the stock toptal C/C++ sections.** Its `*.d` pattern also matches *directories* named `*.d`, which is how `../rootfs` silently failed to commit `overlay/etc/init.d`. They were removed from the generated file this repository started with; keep them out.
- **Apache 2.0** for this repository; Rust is dual MIT/Apache-2.0 and its `COPYRIGHT` and licence texts ship inside the release asset.
- **`README.md` is the specification and stays in sync.** Changing a target, a variable or a default means updating it in the same change.

## CI and Releases

Both files are the `../musl` pair with the names changed; `../boot/docs/CI.md` is the full reasoning:

- **`ci.yml` builds on every commit on every branch and every PR against `main`**, in `debian:trixie-slim`. The package list is the shortest in the family: `make git curl ca-certificates xz-utils`, and no compiler at all.
- **The artifact is not uploaded from CI.** Every other repository uploads its asset from every branch because they are between 348 KB and 60 MiB; this one is a few hundred MiB and would be uploaded on every push to no purpose. The release workflow uploads it; CI proves it can be built.
- **Build tools go in *before* `actions/checkout`.** Without `git` in the container, checkout silently degrades to a tarball download.
- **`make stage` is the goal that pulls everything in.** `../musl`'s first release build failed because no product goal reached the toolchain download; there is no toolchain here, but the same rule holds — the release workflow calls one goal and it must be enough.
- **Releases are never automatic.** Manual `workflow_dispatch` takes a version; a `gate` job validates it, resolves `main`'s head **once**, refuses a commit with no green CI run for that exact commit, and branches `main` to `rel-<version>`; `build` runs on that branch; `rollback` deletes it if the build fails.
- **`inputs.version` reaches bash through `env:`, never `${{ }}` interpolation into a script line.** Validate against `^[0-9][0-9A-Za-z.+-]*$`.
- **The release body is an interface** the moment anything consumes this: state the version as `| rust | \`1.98.1\` |`, the way every sibling states its own.
- Only the publishing job gets `contents: write`; `GITHUB_TOKEN` is the only credential needed.

## Build Environment

The user develops on **macOS** (`darwin`) with the repositories under `~/Projects/RaspberryPi/SepiaOS/`.

- **`gmake` (`brew install make`)**, not `/usr/bin/make`.
- Required tools: `gmake`, `curl`, `tar`, `xz`. That is the whole list — no compiler, no toolchain, no `jq`.
- Unlike every sibling, the asset **is** byte-identical whatever the build host: nothing here is compiled, so macOS and Linux produce the same tree from the same upstream tarballs. Only the `tar`/`xz` framing could differ.
