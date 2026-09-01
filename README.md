# Rust development with Nix and Podman

This repository explores **devshells with isolation**: Nix still declares and pins the Rust development tools, but instead of exposing them directly through `nix develop`, it packages them into an OCI devcontainer run by rootless Podman (or an equivalently hardened runtime). Cargo build scripts, procedural macros, tests, and AI agents then execute inside the container boundary, while sandboxed `nix build` remains the authoritative build path.

This example keeps interactive Rust development separate from authoritative builds:

```text
Interactive work                     Authoritative build
----------------                     -------------------
Zed / AI agents                      nix build
        ↓                                  ↓
rootless Podman devcontainer         Nix build sandbox
        ↓                                  ↓
cargo check/test/run                 packaged Rust binary
```

The separation is intentional. The devcontainer is a practical boundary for editing and fast iteration. Nix provides the cleaner, reproducible build used for final verification and, eventually, CI.

## Why use both?

Rust packages can execute more than the final application. Cargo may run `build.rs` scripts, procedural macros, native build tools, and test binaries. AI coding agents can also execute project commands and modify files.

Running that activity in a rootless container limits what it can reach on the host. The stronger Nix build path then rebuilds the application from declared inputs in a sandbox, without depending on the mutable development environment.

The intended rule is:

```text
edit, experiment, Cargo, and AI agents  → devcontainer
final local verification                → nix build
CI                                      → the same Nix definitions
```

## Repository outputs

The flake exposes two packages:

| Command | Output |
|---|---|
| `nix build` | The Rust application |
| `nix build .#devImage` | The OCI development image |

The container does not contain Nix. Nix runs on the host and copies the required package closures into the OCI image.

OCI images are not tied to Podman. Docker can load and run this image too. This example uses rootless Podman because its daemonless model and `keep-id` user mapping fit the intended security boundary. Docker has rootless and user-namespace features, but they are configured differently and should not be assumed to provide identical isolation by default.

## Why build the devcontainer with Nix?

The container boundary provides the isolation; building the image with Nix makes the development environment declarative and reproducible.

The same pinned nixpkgs revision supplies Rust, Cargo, the native toolchain, Codex, and the utilities required by Zed. This provides:

- a toolchain and userspace pinned by `flake.lock`;
- an explicit, reviewable list of installed programs;
- reproducible image construction without mutable startup installation;
- one Nix definition for both the development image and authoritative application build;
- the ability to add project-specific native dependencies deliberately.

The image is intentionally minimal but practical rather than tiny. It contains the tools required for this workflow, but avoids becoming a general-purpose Linux environment by default.

A carefully maintained generic Rust image pinned by digest can also be a reasonable base. The Nix-built image is useful here because the repository already uses Nix and benefits from keeping its development and authoritative build inputs under the same versioned configuration.

## Build the development image

On the NixOS host:

```bash
nix build .#devImage
podman load < result
```

With Docker, the equivalent image-loading command is:

```bash
docker load < result
```

This loads the image as:

```text
localhost/rust-dev:latest
```

Open the repository through Zed's Dev Containers support. The host checkout is mounted at:

```text
/workspaces/nix-container-test
```

The basename is computed dynamically, so a differently named checkout appears under `/workspaces/<checkout-name>`.

Inside the container, the normal development loop is:

```bash
cargo check
cargo test
cargo run
cargo clippy
```

Codex is installed from the pinned nixpkgs revision:

```bash
codex --version
```

## Build the application with Nix

Run the authoritative build on the host:

```bash
nix build
./result/bin/workspace
```

For the current example, the program prints:

```text
Hello, world!
```

`pkgs.rustPlatform.buildRustPackage` builds the crate using `Cargo.lock`. Cargo build-time code runs in the Nix build environment rather than in the interactive devcontainer.

### Why the Nix build is authoritative

With sandboxing enabled on Linux, an ordinary Nix build sees its declared inputs instead of the normal host filesystem. Build scripts, procedural macros, native build tools, and tests therefore cannot normally access host SSH keys, user configuration, unrelated files, or the writable source checkout.

Nix also gives ordinary build derivations private process, mount, network, IPC, and hostname namespaces. They cannot use the normal outbound network, and they write their result to a fresh Nix store path. Together with `Cargo.lock` and the nixpkgs revision in `flake.lock`, this makes undeclared dependencies and environment-dependent behavior more likely to fail visibly instead of silently influencing the result.

This is why the Nix build is the final verification path even though the devcontainer is already isolated: the container is intentionally stateful, networked, and able to modify the repository, while the authoritative build receives a narrower environment.

These guarantees depend on sandboxing being enabled. Verify the host configuration with:

```bash
nix config show sandbox
```

It should report `true`. Fixed-output derivations used to fetch content with an expected hash are a deliberate exception: they may access the network, while ordinary build derivations may not.

## What the devcontainer isolates

In this example, the container runs with:

- rootless Podman;
- a user namespace mapping the host user to container user `dev`;
- all Linux capabilities dropped;
- `no-new-privileges` enabled;
- PID and memory limits;
- a bounded `tmpfs` at `/tmp`;
- no Docker, Podman, or Nix daemon socket;
- no host SSH, GPG, cloud, or Cargo configuration mounts.

The OCI image is portable, but this exact runtime hardening is not automatically portable. In particular, `--userns=keep-id:uid=1000,gid=1000` is part of the Podman setup. A Docker deployment must configure rootless operation, user mapping, and equivalent restrictions deliberately.

The image declares `dev` as UID/GID 1000. Podman's `keep-id` mapping translates that identity to the actual host user, so the host UID is not baked into the image.

The configured memory values are examples for the current machine. Adjust them in `.devcontainer/devcontainer.json` if the host has substantially less RAM.

## Storage layout

The source checkout remains a read/write host bind mount:

```text
host checkout
    ↕
/workspaces/<checkout-name>
```

Cargo state is kept in Podman volumes instead of exposing the host's Cargo directory:

```text
/home/dev/.cargo                     Cargo registry and tools
/home/dev/.cache/cargo-target/target build artifacts
```

This preserves useful caches when the container is recreated and keeps `target/` out of the host checkout.

## Important security boundaries

The repository itself is deliberately writable. Untrusted code in the container can therefore change source files and security-sensitive project files such as:

```text
.git/config
.git/hooks/*
.envrc
flake.nix
project scripts
```

Review changes before running project-controlled commands on the host:

```bash
git status
git diff
```

Keep authenticated Git operations on the host where practical. Do not mount SSH keys or forward an SSH agent into the container merely for convenience.

Codex and Cargo currently run as the same `dev` user. Any Codex authentication stored under `/home/dev` could therefore be read by malicious build or test code. This repository intentionally does not mount host Codex credentials or persist `/home/dev/.codex`; choose an authentication strategy deliberately before changing that.

## Rebuilding after image changes

After changing the image definition in `flake.nix`:

```bash
nix build .#devImage
podman load < result
```

Then recreate the devcontainer so Zed starts it from the newly loaded image. Rebuilding alone does not replace an already-running container.

## Current limitations and next improvements

- HTTPS certificate discovery still needs verification; `cacert` is installed, but `SSL_CERT_FILE` is not yet set explicitly.
- Codex credential persistence has intentionally not been configured.
- The flake does not yet define dedicated formatting, Clippy, or test entries under `checks` for CI.
- The writable repository and persistent Podman volumes can consume host disk space; no filesystem quota is configured here.

These are separate policy decisions. They should be added only after considering what new host data or privileges they expose.
