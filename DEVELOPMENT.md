# Rust Development Workflow on NixOS

This repository uses three distinct execution paths:

1. **Interactive development** inside a hardened rootless Podman devcontainer.
2. **Direct/local builds** through `nix build`.
3. **CI builds and checks** through the same Nix build definitions.

The main goals are:

- isolate Cargo build scripts, proc macros, native build tools, and AI agents from the host;
- keep Git credentials and other host secrets outside the development container;
- use Nix for reproducible, authoritative builds;
- keep the interactive development loop fast.

---

## Architecture

```text
                         repository
                              │
              ┌───────────────┼────────────────┐
              │               │                │
              ▼               ▼                ▼
        DEVELOPMENT           CI          DIRECT BUILD
              │               │                │
       devcontainer        nix build         nix build
              │               │                │
       cargo check/test    sandboxed        sandboxed
       AI agents           clean build      clean build
```

The devcontainer is for interactive work and isolation.

Nix is the authoritative build system.

---

## Repository layout

A typical repository looks like this:

```text
my-project/
├── .devcontainer/
│   └── devcontainer.json
├── flake.nix
├── flake.lock
├── Cargo.toml
├── Cargo.lock
├── src/
└── tests/
```

The source repository itself lives normally on the host, for example:

```text
/home/user/projects/my-project
```

The devcontainer bind-mounts that checkout into the container, usually at:

```text
/workspace/my-project
```

---

# 1. Interactive development

The repository is cloned and managed normally on the NixOS host:

```bash
git clone <repository>
cd my-project
```

Then the editor opens the project through the devcontainer.

Conceptually:

```text
NixOS host

/home/user/projects/my-project
              │
              │ read/write bind mount
              ▼

rootless Podman container

/workspace/my-project
```

Inside the container, run development commands such as:

```bash
cargo check
cargo test
cargo run
cargo clippy
```

Rust Analyzer and AI coding agents also run inside the container.

The container should be treated as the place where potentially hostile project code executes.

This includes:

- Cargo `build.rs` scripts;
- procedural macros;
- native build systems invoked by crates;
- test executables;
- project scripts;
- AI agents that may autonomously execute commands.

## Git operations

Git credentials should remain on the host.

Prefer doing authenticated operations from the host:

```bash
git pull
git push
```

Do not mount host secrets into the development container unless there is a specific reason to do so.

In particular, avoid exposing:

```text
~/.ssh
~/.gnupg
~/.aws
~/.kube
SSH_AUTH_SOCK
Docker or Podman sockets
host Nix daemon socket
```

The container can still run unauthenticated Git commands against the bind-mounted repository:

```bash
git status
git diff
git log
```

---

## Recommended storage layout

Use a bind mount for source code but separate Podman volumes for build caches.

```text
HOST

/home/user/projects/my-project
              │
              │ bind mount
              ▼

CONTAINER

/workspace/my-project
       │
       ├── source code
       ├── Cargo.toml
       ├── Cargo.lock
       └── .git

       +

Podman volume: Cargo cache
Podman volume: target/
```

A practical layout is:

```text
source tree:
    bind-mounted host repository

Cargo registry/cache:
    Podman volume

target/:
    Podman volume
```

This provides several benefits:

- source changes are immediately visible on the host;
- editor integration remains simple;
- `target/` does not clutter the host checkout;
- Cargo caches survive container recreation;
- the host `~/.cargo` directory is not exposed;
- downloaded crates and build artifacts remain container-managed.

---

## Security limitation of the bind mount

The container has write access to the repository itself.

That means hostile code can modify files such as:

```text
src/
Cargo.toml
flake.nix
scripts/
.git/config
.git/hooks/
.envrc
```

This creates a possible delayed host-side attack.

For example:

```text
malicious build.rs
        │
        ▼
writes .git/hooks/post-commit
        │
        ▼
container exits
        │
        ▼
user later runs a Git operation on host
        │
        ▼
malicious hook executes on host
```

Therefore, after running untrusted code or an autonomous AI agent, review repository changes before executing project-controlled scripts directly on the host.

The devcontainer protects the rest of the host filesystem, but the bind-mounted repository itself is deliberately writable.

---

# 2. Direct local build

The authoritative local build does **not** use the devcontainer.

From the NixOS host:

```bash
nix build
```

The project `flake.nix` should define the Rust package, for example using:

```nix
pkgs.rustPlatform.buildRustPackage {
  pname = "my-project";
  version = "0.1.0";

  src = ./.;

  cargoLock.lockFile = ./Cargo.lock;
}
```

Conceptually:

```text
host repository
      │
      │ source becomes Nix build input
      ▼
Nix store
      │
      ▼
Nix build sandbox
      │
      ├── cargo build
      ├── build.rs
      ├── proc macros
      ├── native build tools
      └── tests/build steps
      │
      ▼
/nix/store/...-my-project
```

This is independent of the devcontainer.

Running:

```bash
nix build
```

does **not** mean:

```text
enter devcontainer
run cargo
```

Instead, Nix constructs a clean build environment and executes the declared build in its sandbox.

For this project, that is the preferred mechanism for reproducible and security-sensitive builds.

---

## Why direct `nix build` is stronger than development builds

During interactive development:

```text
devcontainer
    ↓
cargo check / cargo test
```

The container protects the host, but project code can still access whatever exists inside that container.

During an authoritative Nix build:

```text
nix build
    ↓
Nix sandbox
```

the build gets a much narrower environment.

The intent is that project build code cannot freely access:

```text
host ~/.ssh
host ~/.config
other host files
the normal network
the writable source checkout
```

This makes `nix build` the preferred path for final verification.

---

# 3. CI

CI should use the same Nix definitions as the local authoritative build.

A typical CI workflow should primarily run:

```bash
nix flake check
nix build
```

Conceptually:

```text
Git commit
    │
    ▼
CI runner
    │
    ├── nix flake check
    │
    └── nix build
            │
            ▼
        Nix sandbox
```

Do not make the devcontainer the primary CI build mechanism unless there is a specific reason to do so.

This:

```text
CI
 ↓
build devcontainer
 ↓
start container
 ↓
cargo test
```

adds an unnecessary layer when Nix already provides the authoritative build environment:

```text
CI
 ↓
Nix
 ↓
sandboxed Cargo build
```

---

## Checks

The flake can expose checks for:

- formatting;
- Clippy;
- unit tests;
- integration tests;
- generated-code validation;
- other static analysis.

These can be wired into:

```bash
nix flake check
```

The goal is for local verification and CI to execute the same build and validation definitions.

---

# Development vs direct build vs CI

| Property | Development | Direct build | CI |
|---|---|---|---|
| Primary command | `cargo check`, `cargo test`, etc. | `nix build` | `nix build`, `nix flake check` |
| Runs in | Devcontainer | Nix sandbox | Nix sandbox |
| Source | Bind-mounted host checkout | Nix build input | CI checkout → Nix input |
| Interactive | Yes | No | No |
| AI agents | Yes | No | Usually no |
| Fast iteration | Excellent | Lower priority | Not important |
| Persistent build cache | Yes | Nix-managed | CI/Nix-managed |
| Reproducibility | Moderate/high | High | High |
| Host isolation | Rootless container | Nix sandbox | Nix sandbox |
| Network | Usually available | Normally unavailable during build | Normally unavailable during build |

---

# Typical daily workflow

## Start development

On the host:

```bash
cd ~/projects/my-project
zed .
```

The editor opens or attaches to the devcontainer.

Inside the container:

```bash
cargo check
cargo test
cargo run
```

AI agents also run inside the container.

## Inspect changes

Either inside the container or on the host:

```bash
git status
git diff
```

Be particularly careful after executing unknown project code or allowing an autonomous agent to make changes.

## Authoritative verification

On the host:

```bash
nix flake check
nix build
```

This executes the project build through Nix rather than running Cargo directly on the host.

## Publish

After reviewing the result, authenticated Git operations can remain on the host:

```bash
git commit
git push
```

No GitHub or SSH credentials need to be available inside the devcontainer.

---

# Two levels of reproducibility

The development and authoritative build environments deliberately optimize for different things.

## Development environment

Optimize for iteration speed:

```text
devcontainer
   │
   ├── persistent Cargo cache
   ├── persistent target/
   └── cargo check/test
```

A completely clean environment for every command would make interactive development unnecessarily slow.

## Authoritative build

Optimize for reproducibility and isolation:

```text
nix build
   │
   ├── declared inputs
   ├── Cargo.lock
   ├── clean build environment
   └── sandboxed execution
```

This separation is intentional.

---

# Devcontainer image

The development image itself is built by Nix.

Conceptually:

```text
flake.lock
    │
    ▼
pinned nixpkgs
    │
    ▼
Nix builds OCI image
    │
    ├── rustc
    ├── cargo
    ├── rust-analyzer
    ├── git
    ├── shell tools
    └── native build tools
    │
    ▼
rootless Podman
```

Nix does not need to run inside the container.

The OCI image contains the required Nix store paths as normal image filesystem contents.

For example:

```text
container /
└── nix/
    └── store/
        ├── ...-rustc-...
        ├── ...-cargo-...
        ├── ...-glibc-...
        └── ...
```

These paths are packaged into the OCI layers when Nix builds the image. They are not bind-mounted from the host `/nix/store`.

---

# Security model

The intended trust boundaries are:

```text
                 NixOS host
                     │
              host credentials
                     │
             ───── boundary ─────
                     │
            rootless devcontainer
                     │
              ┌──────┴──────┐
              │             │
          AI agents      Cargo builds
                            │
                        build.rs
                        proc macros
                        test code
```

The devcontainer primarily protects the host from interactive project execution.

The authoritative Nix build provides a separate, narrower sandbox for final builds.

The practical rule is:

```text
interactive / potentially untrusted execution
    → hardened rootless devcontainer

authoritative local build
    → nix build

CI
    → nix build / nix flake check
```

---

# Things that should not be mounted into the devcontainer

Avoid exposing:

```text
/var/run/docker.sock
/run/podman/podman.sock

~/.ssh
~/.gnupg
~/.aws
~/.config/gcloud
~/.kube

SSH_AUTH_SOCK

host ~/.cargo

host Nix daemon socket
```

Only explicitly expose resources that the development environment truly needs.

---

# Summary

This repository uses the devcontainer and Nix for different purposes:

**Devcontainer**

- interactive Rust development;
- Rust Analyzer;
- Cargo iteration;
- tests;
- AI agents;
- isolation from the host.

**Nix build**

- authoritative build;
- reproducibility;
- clean dependency environment;
- stronger build-time sandboxing.

**CI**

- reuses the same Nix build and check definitions;
- should not depend on the interactive devcontainer.

The resulting workflow is:

```text
edit + experiment + agents
        │
        ▼
hardened rootless devcontainer
        │
        ▼
review changes
        │
        ▼
nix flake check
nix build
        │
        ▼
commit / push
        │
        ▼
CI repeats Nix checks/build
```
