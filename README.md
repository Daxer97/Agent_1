# agent_1 — HERMES-AGENT infrastructure

Declarative infrastructure for the **agent_1** multi-provider agentic
platform, deployed as five roles across four NixOS guests on a single Proxmox
VE node.

The repository is the deployment: the flake is the single point of truth for
every guest, every service and every threshold. Nothing is configured by hand
after provisioning, and the resolved lock file is what makes the
reproducibility of a deployment a measurable property rather than a claim.

---

## Table of contents

- [What this platform is](#what-this-platform-is)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Compile-time variables](#compile-time-variables)
- [Runtime variables](#runtime-variables)
- [Operating notes](#operating-notes)

---

## What this platform is

agent_1 integrates an agentic runtime — containerised with Nix — with a single
inference gateway and a self-hosted semantic memory backend. The aim is the
best quality-to-cost ratio on complex agentic workloads: technical design
documentation, trade-off analysis, automated pre-analysis. Avoiding lock-in to
a single model is a design goal, not a side effect.

The load-bearing architectural choice is that the agentic loop is driven by an
inexpensive, robust model, while multi-model deliberation is invoked only on
the sub-tasks where the cost of being wrong exceeds the cost of a few extra
completions. The decision to invoke it is left to the gateway's own gate,
which keeps a custom routing layer out of the architecture entirely: panel
selection, judging, recursion protection, pricing and accounting all stay with
the gateway.

The platform exposes two execution planes.

**Interactive.** A user authenticates at the ingress, reaches a multi-user web
interface, and talks to the runtime through an OpenAI-compatible API server.
One profile per user, one memory bank per profile.

**Programmatic.** Unattended workloads — scheduled jobs, pipeline steps, batch
processing — embed the same agentic loop as a library instead of going through
the API server. They run on dedicated service profiles, in a container of
their own built from the same flake.

The two planes share no profile, no memory bank, no inference credential and
no concurrency budget. They do share one internal component, the egress
broker, and it is what keeps them distinct by token and by upstream
credential.

---

## Architecture

### Execution planes and inference path

<p align="center">
  <img src="docs/architecture.svg" width="900" alt="Three network zones stacked vertically. The user reaches the edge zone over HTTPS; the reverse proxy injects a per-profile bearer and forwards to the API server in the application zone. The interactive and programmatic planes each present a distinct internal token to the egress broker, which holds the only real gateway credential and is the only component that talks to the external inference gateway. The data zone holds the observability stack, the secret store and the memory backend; memory extraction calls are routed back through the broker so that they appear in the cost figures.">
</p>

The diagram adapts to a light or dark reading environment on its own. What it
asserts by absence is as much the point as what it draws: no path reaches the
data zone from the user network, no path reaches the inference gateway except
through the broker, and nothing connects the two execution planes to each
other.

### Roles and guests

| Role | Zone | Components | Consolidation |
| --- | --- | --- | --- |
| `ingress` | edge + application | Reverse proxy, identity provider, chat interface | Dual-homed. The only guest reachable from the user network. |
| `agent` | application | Agent runtime, API server, programmatic runtime, triggers, egress broker | **Never consolidated.** The only host running model-generated code. |
| `memory` | data | Memory backend, inspection console, relational store with vector index | Dedicated storage device. |
| `secrets` | data | Secret store | Owns its guest. Blocking at boot. |
| `observability` | data | Collector, metrics, logs, trace backend, evaluation platform, dashboards | Aliased onto `secrets` by default; separable by changing one parameter. |

Consolidation is a parameter (`aliasOf`), not a variant of the configuration.
Two constraints survive any choice: the agentic guest hosts nothing else, and
the secret store never shares an out-of-memory event with the observability
stack.

### Network segmentation

Three zones on distinct VLANs, with a default-deny policy in both directions.
Inbound rules are written against the **source range**, never against the
interface: routing between zones is performed by the device upstream, so
inter-zone traffic leaves the bridge and comes back to it, and a rule written
per interface does not intercept it.

Outbound rules on the agentic guest distinguish processes **by user**, not by
host. The broker and the agentic containers live on the same guest; a rule
written against the guest address would admit both, and the restriction would
become a convention rather than a control.

### The invariant everything else rests on

No policy allows an agentic identity to read an inference credential.

The reasoning is short. Code execution is available to the agent, and the
container is what contains it — that protects the host, not what is inside the
container. A gateway key present in the process environment can be read by the
agent itself, or by a skill compromised through prompt injection, with a
single call. The broker moves the credential across a process boundary and
hands the runtime an internal token instead: revocable, scoped, and worthless
anywhere else.

This is verified as a **negative test that runs before any application is
deployed**. Verifying it afterwards means verifying it at the point where
dismantling it has become expensive.

### Memory model

Retrieval fuses four channels — vector similarity, full-text, graph traversal
and temporal windows — using a rank-based algorithmic strategy, which keeps a
CPU-bound reranking model off the recall path on guests without an
accelerator.

What is injected before a turn is *consolidated observations*, not raw facts:
denser per token and not redundant.

The cost profile of memory is asymmetric, and the asymmetry drives one of the
platform's measurements. Recall costs CPU and I/O only. Retention and
consolidation extract facts through an inference call, and that channel scales
with total turns rather than with the number of users. It is therefore a
structural second spending channel, and it is routed through the broker
precisely so that it is visible in the cost figures.

### Telemetry and the artefacts that hold content

Exactly three artefacts hold conversational content: the trajectory files, the
trace pipeline, and the evaluation platform. The enumeration is closed, and it
is the enumeration that is watched. The property is not "content exists
nowhere" — it never was — but "content exists only where it is declared to
exist, and nowhere else".

Implementationally this is a choice of pipeline. The scrubbing processor stays
on the log pipeline in full and is not applied to the trace pipeline, whose
only destination is the evaluation platform. The constraint that follows is
not negotiable: **the trace pipeline admits no exporter other than the
evaluation platform.** An additional trace backend requires a separate
pipeline with scrubbing enabled. Adding one to the existing pipeline creates a
fourth artefact holding content without declaring it, and produces no error at
all.

---

## Repository layout

```
.
├── flake.nix                    single point of truth; builds every guest
├── flake.lock                   resolved inputs — generated, see below
├── parameters.example.nix       site parameter template (copy to parameters.nix)
├── parameters.nix               the values of this installation, versioned
├── .sops.yaml                   per-host encryption rules for the bootstrap secrets
├── .env.example                 runtime variables, documented by secret-store path
│
├── hosts/                       one file per role; thin, imports modules
│   ├── ingress.nix              proxy, identity provider, chat interface
│   ├── agent.nix                agentic containers, broker, triggers
│   ├── memory.nix               memory backend and relational store
│   ├── secrets.nix              secret store (and observability, when aliased)
│   └── observability.nix        used only when observability owns a guest
│
├── modules/
│   ├── options.nix              the parameter schema — every option, typed
│   ├── common.nix               configuration shared by all guests
│   ├── disk-layout.nix          root partition table and boot path, via disko
│   ├── network-zones.nix        three-zone segmentation, default deny
│   ├── secret-store.nix         secret store server
│   ├── secrets-agent.nix        agent rendering policies into environment files
│   ├── egress-broker.nix        the service holding the inference credential
│   ├── hermes-agent.nix         the two agentic containers
│   ├── hermes-profiles.nix      idempotent profile provisioning; identity map
│   ├── hermes-svc-workloads.nix unattended workloads and their concurrency cap
│   ├── memory-stack.nix         relational store and memory backend
│   ├── authelia.nix             identity provider, declaratively configured
│   ├── ingress.nix              reverse proxy, forward-auth, chat interface
│   ├── instrumentation.nix      agentic-loop instrumentation, per plane
│   ├── observability.nix        collector, metrics, logs, rules, dashboards
│   ├── observability-eval.nix   trace backend and evaluation platform
│   └── pve-provision.nix        node-side guest provisioning, generated
│
├── policies/
│   └── default.nix              secret-store policies, rendered from parameters
│
├── pkgs/
│   └── egress-broker/           source of the broker, built through uv2nix
│
├── secrets/                     sops-encrypted bootstrap credentials, one per host
│
├── docs/
│   └── architecture.svg         the diagram above; theme-aware, no external assets
│
└── config/                      versioned data artefacts, not machine configuration
    ├── authelia/users.example.yml   shape of the user population, not read
    └── phoenix/datasets/        the versioned evaluation set
```

### Two deliberate departures from the source design

**Host files are named by role, not by host name.** The guest host names are
parameters; a file named after a parameter's value couples the tree to one
installation. The flake maps roles to host names from the inventory, so
renaming a guest is a one-line change in `parameters.nix`.

**Policy documents and service configuration are generated, not stored as
pre-substituted text.** The design describes them as files carrying
placeholders replaced during provisioning. Here the identity-provider
configuration, the collector configuration, the alert rules, the datasource
definitions, the instrumentation documents, the secret-store policies and the
node provisioning script are all rendered from the typed options. The mount
point, the ports and the addresses are written once; a rename cannot leave a
stale copy behind. Where a document is genuinely data rather than
configuration — the evaluation dataset — it stays a versioned file under
`config/`. The one artefact that looks like it belongs there and does not is
the user population: it holds password digests, so it travels encrypted with
the bootstrap credentials instead, and `config/authelia/users.example.yml`
documents its shape without being read by anything.

---

## Prerequisites

### Proxmox VE node

| Requirement | Why it is required |
| --- | --- |
| Full virtualisation (VT-x / AMD-V) enabled | The guests are virtual machines, not system containers. A container nested inside a system container shares the node kernel, so an escape reaches the hypervisor. The virtual machine restores a hardware boundary underneath the container boundary. |
| VLAN-aware bridge | The three-zone segmentation is carried on 802.1Q VLANs. |
| Free capacity ≥ the sum of the guest profiles | Verify before consuming it, not while provisioning. |
| Storage pool for the memory guest on a separate device | A vector index on slow storage produces a retrieval failure that gets attributed to the memory backend. |
| `qcow2` format on any directory-backed pool | With `raw`, per-phase snapshots are unavailable and the installation loses its rollback points. |
| Free VMID range | Verify with `qm list` and `pct list` before the first creation. |
| Outbound reachability of the inference gateway, the image registries and the binary cache | Without egress the installation cannot proceed past the first phase. |

### Two artefacts to generate before the first build

Neither is committed here, because both are the output of resolving inputs
against a network, and both must be produced once and then versioned. Until
they exist the flake does not build.

```sh
nix flake lock                 # resolves every input; produces flake.lock
nix develop -c uv lock --directory pkgs/egress-broker   # produces uv.lock
git add flake.lock pkgs/egress-broker/uv.lock
```

`flake.lock` is not a build artefact but a deliverable: it is what makes the
reproducibility of a deployment measurable, and it is the object to tag when
an environment is accepted.

### Workstation

- Nix with flakes enabled (`experimental-features = nix-command flakes`)
- `sops`, `age` and `ssh-to-age` — provided by `nix develop`
- `nixos-anywhere`, or another declared provisioning method
- SSH access to the node and to the management range

### One consequence worth knowing before you start

Outbound traffic is denied by default on every guest, and on the agentic guest
the exceptions are granted per user. A rebuild running locally as root
therefore cannot reach the binary cache. Build on a build host and push the
closures:

```sh
nixos-rebuild switch --flake .#<host> --target-host root@<address> --build-host localhost
```

This is the option consistent with the design rather than a workaround: a
guest running untrusted code has no need of a build toolchain.

---

## Installation

Ten phases. Each ends with a snapshot, which is the rollback point of the one
that follows. Commands run from the repository root unless stated otherwise.

### F-01 — Environment verification

Installs nothing. It establishes that the assumptions the sizing rests on are
true, before any node capacity is consumed.

```sh
pveversion -v                                   # hypervisor version
lscpu | head -20                                # cores available
grep -Eoc "(vmx|svm)" /proc/cpuinfo             # full virtualisation: must be > 0
free -g                                         # memory, the binding constraint
pvesm status                                    # storage pools and free space
pveperf                                         # fsync rate on the memory pool
cat /sys/class/net/<bridge>/bridge/vlan_filtering   # expected: 1
qm list ; pct list                              # VMIDs already in use
```

Record the results and carry them into `parameters.nix`. The fsync rate on the
pool destined for the memory guest must clear the declared floor; if it does
not, revise the sizing now rather than diagnosing a retrieval failure later.
Once the parameters are filled in, that measurement is also a command:

```sh
nix run .#provision-guests -- fsync          # pveperf on the memory pool, against the declared floor
```

Most of the list above is re-asserted by `preflight` in F-02, against the
parameters rather than against a reading. That is deliberate and it is not
redundant: a value carried by hand into a parameter is true when it is taken,
and these are the assertions that keep it true at the moment the node is
written to. What `preflight` cannot replace is this phase's judgement — the
figures recorded here are what the sizing was *decided* from.

Confirm egress:

```sh
curl -sS -o /dev/null -w "%{http_code}\n" https://openrouter.ai/api/v1/models
curl -sS -o /dev/null -w "%{http_code}\n" https://ghcr.io/v2/
curl -sS -o /dev/null -w "%{http_code}\n" https://cache.nixos.org/nix-cache-info
```

An authentication error from the gateway is a pass: it proves reachability.

### F-02 — Guests and network topology

Fill in the parameters, then let the flake generate the provisioning commands:

`sops`, `age` and `ssh-to-age` are not expected to be installed: they are what
the development shell is for, and every command below that uses one has to run
inside it.

```sh
nix develop                                  # sops, age, ssh-to-age on PATH

mkdir -p ~/.config/sops/age                  # age-keygen does not create it
[ -f ~/.config/sops/age/keys.txt ] ||        # it refuses to overwrite, and should
  age-keygen -o ~/.config/sops/age/keys.txt
ADMIN=$(age-keygen -y ~/.config/sops/age/keys.txt)

# The administrative SSH key, which is a different key from the age identity
# above: that one decrypts the credentials, this one is hermes.nix.adminKeys,
# and it is the only way into the guests and into the installation image.
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519

# Both markers are exact, so neither substitution needs an editor — which is
# what a pasted block needs, since an editor started from one reads the rest
# of the paste as its own input and the commands after it never run.
sed -i "s|PLACEHOLDER_ADMIN_SSH_PUBLIC_KEY|$(cat ~/.ssh/id_ed25519.pub)|" parameters.nix
sed -i "s|PLACEHOLDER_AGE_KEY_ADMIN|$ADMIN|" .sops.yaml

"${EDITOR:-vi}" parameters.nix               # then read the rest of it through

# One file per guest, encrypted to the operator alone. The shape is in
# secrets/README.md. --config is what makes this possible today: the rules in
# .sops.yaml name host keys that do not exist yet, and sops refuses to encrypt
# for a recipient it cannot parse.
for h in hrm-edge hrm-app hrm-mem hrm-sec; do
  "${EDITOR:-vi}" secrets/$h.yaml
  # sops reports an empty file as "File cannot be completely empty" without
  # saying which, and an unencrypted one is indistinguishable from a filled
  # one at a glance.
  if [ ! -s secrets/$h.yaml ]; then
    echo "secrets/$h.yaml is empty — its shape is in secrets/README.md" >&2
    continue
  fi
  sops --config /dev/null --age "$ADMIN" --encrypt --in-place secrets/$h.yaml
done
git add secrets/*.yaml                       # untracked is invisible to the flake

nix flake check                              # fails while a placeholder survives

# The gate above stays red until the last placeholder is resolved, and two of
# them belong to phases that have not run. It does not block this one: the
# image and the guests are built from the parameters that are filled in, and
# the only placeholder either of them refuses is adminKeys, by assertion.
nix build .#installer-iso                    # on the node, once: see below
install -m 0644 result/iso/hermes-installer.iso \
  "$(pvesm path local:iso/hermes-installer.iso)"

nix run .#provision-guests -- preflight      # run on the node: reads, writes nothing
nix run .#provision-guests -- create         # creates, then boots each one on the image
nix run .#provision-guests -- verify         # each guest, field by field, against the inventory
nix run .#provision-guests -- status
```

`preflight` is what `create` runs first, and it is worth running on its own
while the parameters are still being edited. It compares the declaration with
the node and stops the run before a single volume is allocated:

| Checked | Reported as | Because |
| --- | --- | --- |
| Every pool the inventory names is declared, active, and accepts `content=images` | error | `qm create` refuses all three with the same wording, naming the guest that happened to be next in the start order rather than the line that has to change. |
| The format of each root volume is one its pool can hold | error | `qcow2` on a block-backed pool (`lvm`, `lvmthin`, `zfspool`, `rbd`) is refused; `raw` on a directory pool is accepted and silently costs the per-phase snapshots. |
| A directory pool resolves to a device of its own, and declares `is_mountpoint` | error for the memory pool, warning elsewhere | A pool whose device is not mounted is a directory on the root filesystem. It accepts every write, and the separation the sizing rests on is gone with nothing reported. |
| Free space against the volumes declared on each pool | warning | Thin pools accept the allocation and fail when the volumes are written, not when they are created. |
| Each VMID is free, or holds the guest of that name | error | A VMID in use by a container, or by a guest this inventory did not create, is never written to. |
| The bridge exists, and carries VLAN filtering | error / warning | `qm create` does not validate the bridge: the guest is created and comes up attached to nothing, which is diagnosed one layer above where it is. |
| Node CPUs and available memory against the guests | error / warning | Proxmox refuses to start a guest with more virtual CPUs than the node has, and ballooning is disabled by design, so the memory assignment is fixed. |
| The installation image is on the iso pool, and the pool carries `content=iso` | error | `create` boots each guest it creates on that image. Without it, `create` would allocate every volume and stop at the first guest it cannot start. |
| The backup target is declared, active and carries `content=backup` | warning | Not needed to create a guest. It is the first of the three checks F-10 rests on, and cheaper to learn here. |

An error stops `create`; a warning does not, because it states something about
the node that the operator is the one placed to judge.

`create` leaves a guest that already exists untouched, and compares it with the
inventory instead of assuming it — skipping is only safe if something checks
that what is there is what was declared. `verify` is that comparison on its
own: cores, memory, ballooning, start order and delay, `onboot`, protection,
the guest agent, the bridge and VLAN tag of every interface, the hardware
address of the primary one, and the pool, size and format of every volume. It reads what `qm config` reports rather than the
arguments that produced it, because Proxmox normalises both the volume
identifiers and the numbers. It corrects nothing — a difference is resolved by
`qm set` on a stopped guest, or by destroying it and letting `create` build it
again — and it is the command to run after any change made by hand.

The bootstrap credential files come before the check, not after it, and this is
the one ordering in the procedure that is not obvious from the error. The
secret store agent resolves `secrets/<host>.yaml` while the configuration is
being evaluated, not while it is being activated, so a guest whose file is
absent stops the evaluation of every output — long before the placeholder gate
that this phase is nominally waiting on gets the chance to report anything.

The guests themselves are not blocked by any of this. `provision-guests` is
built from the parameters and not from a guest's activation, so it evaluates
with no credential files present at all: if the ordering above is inconvenient,
create the guests first and come back to the check.

Six failures in this phase are worth telling apart, because each one names
something other than what is actually missing, or names it without saying
where it has to be corrected:

| What is reported | What it means |
| --- | --- |
| `storage '<id>' does not exist` | Reported by `qm create`, and it is about the node rather than about the flake: the pool the inventory names is not declared in `/etc/pve/storage.cfg`. Declare it — see the storage prerequisite below — and run `create` again. Guests already created are left untouched, so the run resumes rather than restarting. `preflight` reports the same thing before anything has been allocated. |
| `VMID <id> exists on this node as '<name>'` | Reported by `preflight`: the VMID is taken by a guest this inventory did not create, and nothing will be written to it. Free the VMID on the node, or move the guest to a free one in `parameters.nix`. |
| `Path 'secrets/<host>.yaml' does not exist in Git repository` | The file has not been created. |
| `getting status of '/nix/store/...-source/secrets/<host>.yaml'` | It exists in the working tree but was never `git add`ed. A flake is evaluated from the tracked tree; an untracked file is not there as far as the evaluation is concerned. |
| `age-keygen: error: failed to open output file` | The directory above the key does not exist. `age-keygen` writes a file, it does not build a path. |
| `failed to parse input, unknown recipient type: "<an age-key marker>"` | sops read `.sops.yaml` and found a marker where a recipient belongs. It is reported for whichever marker it meets first, so filling in only the administrator's does not resolve it — the rule for each guest names that guest's key too. This is what `--config /dev/null` above steps around, and why it is there. |

At this point the files can only be encrypted to the operator's own key: the
guests do not exist yet, so neither do their host keys. That is expected, and
the second half of this phase registers them and re-encrypts with
`sops updatekeys`.

Four guests are created, not five: the observability role is aliased onto the
secret store guest. The start order is a property of each machine, not a note
in a procedure.

#### Storage prerequisite

Every pool named in `parameters.nix` — `site.storage.default`,
`site.storage.memory`, and the pool of each additional volume — has to be
declared on the node, active, and carrying `content=images` **before** the
first `qm create`. The memory guest is the one that usually needs work: it is
the only guest on a dedicated pool, and the identifier the flake uses is not
necessarily the one the pool was created with.

If you intend to rename a storage identifier, do it **before** the first guest
is created. While no volume refers to the pool the rename is one line; after
that the cost moves to every reference in the flake and in every management
command.

```sh
pvesm status                                    # what the node has today
awk '/^dir: <current-id>/,/^$/' /etc/pve/storage.cfg   # its path and contents

# Nothing has been allocated on it yet, so re-declaring it under the new
# identifier loses no data — the directory is untouched. Match the type and
# the content list to what the pool actually is.
pvesm remove <current-id>
pvesm add dir <new-id> --path <path> --content images

pvesm status --content images                   # <new-id>: listed and active
```

The pool holding the memory guest is directory-backed on purpose, because its
root volume is declared `qcow2` and a block-backed pool (`lvm`, `lvmthin`,
`zfspool`, `rbd`) holds raw volumes only — with raw, the per-phase snapshots
are unavailable and the installation procedure loses its rollback points.
`preflight` refuses that combination rather than letting `qm create` discover
it.

#### The installation image

`nixos-anywhere` neither creates a machine nor boots one: it connects over SSH
to a Linux already running on the target and takes it from there. A guest with
empty volumes and no media has nothing to answer with, and the failure is
reported as `No route to host` — which names the network instead of the absent
installer.

The stock minimal image cannot be that Linux either, or not without a console:
it comes up with no authorised key and no address, and these zones carry no
DHCP server. So the image is built from the inventory instead, once, and it
serves every guest:

```sh
nix build .#installer-iso                    # on the node
install -m 0644 result/iso/hermes-installer.iso \
  "$(pvesm path local:iso/hermes-installer.iso)"
```

It carries the administrative keys of `hermes.nix.adminKeys` and a table of
every guest's address keyed by hardware address — which is why those addresses
are declared, derived from the VMID, rather than left to Proxmox to generate.
A guest that boots it recognises itself, configures the address it will keep
once installed, and admits the operator's key. Nothing is typed into a console,
and `preflight` refuses to create anything while the image is missing.

`create` attaches it, starts each guest it created, and waits for port 22 to
answer. What it leaves behind is not four virtual machines: it is four
machines that can be installed onto.

Rebuilding the image later — after a change to any parameter it carries, which
is the addresses, the hardware addresses, the resolver and the administrative
keys — means stopping the guests that have it attached first. QEMU holds the
file open while a guest is running, and overwriting it in place corrupts what
that guest is reading:

```sh
qm stop <vmid>                               # every guest still on the image
nix build .#installer-iso
install -m 0644 result/iso/hermes-installer.iso \
  "$(pvesm path local:iso/hermes-installer.iso)"
nix run .#provision-guests -- bootstrap      # starts them again and waits
```

#### Installing

```sh
nix shell github:nix-community/nixos-anywhere \
  -c nix run .#provision-guests -- install
```

In start order, stopping at the first failure — a guest installed before the
secret store is a guest whose services start without their credentials. It is
`nixos-anywhere --flake .#<host> root@<declared address>` per guest, from the
repository, with the host key of the image neither recorded nor trusted: it is
generated at every boot and belongs to a machine that has no identity yet. The
identity that matters is the one registered below, from the installed system.

With no argument it installs the guests that are not installed yet, naming the
ones it leaves alone. A guest reports its own name once it is installed and the
image's until then, which is the one fact that separates the two without
reading a disk. Naming a guest — `install hrm-app` — installs that one whatever
state it is in. The distinction is not a convenience: the installation begins
by wiping the partition table, so an unqualified second run would destroy every
guest the first run had installed.

**A guest never answers a ping, at any point after it is installed.** The
firewall drops ICMP echo (`allowPing = false`) and drops rather than rejects
(`rejectPackets = false`), because a rejection confirms that the host exists —
which is what the reachability test from the user network is meant to
disprove. Reachability is tested with SSH, and SSH is admitted from the
management range alone:

```sh
ssh root@<address> true && echo reachable
```

A guest that answers neither is either not running or not booting, and the
console is where that is visible.

A guest whose closure does not build stops the run before it is touched, and
the message names the derivation rather than the guest. `nix log <drv>` is
where the cause is: the last lines of a failed build are printed by the
builder, and for a configuration file that is validated at build time those
last lines are the file, not the complaint about it.

**The activation of a newly installed guest reports a decryption failure, and
it is not one.**

```
sops-install-secrets: failed to decrypt '/nix/store/…-<host>.yaml'
Activation script snippet 'setupSecrets' failed (1)
```

The credential file is encrypted to the operator alone, and the age identity of
the guest is derived from its SSH host key — which does not exist while the
installer is writing the filesystem, because it is generated by sshd the first
time it starts. The installation finishes, GRUB is written, the guest reboots.
Registering the key is the next section, and it is what makes that message stop.

`Could not resolve host` during the installation is a third: the guest routes
but does not resolve. The image carries `hermes.network.nameservers`, so this
means either that the resolver is unreachable from that zone — the guests reach
it through the zone gateway, which is not the path the node uses — or that the
image predates the parameter. Read it from the guest itself:

```sh
ssh root@<address> "cat /etc/resolv.conf; getent hosts cache.nixos.org"
```

Two further failures are worth telling apart. `No route to host` means nothing
answers at that address — the guest is not running, did not boot the image, or
came up without an address, which happens when the hardware address of `net0`
is not the declared one (`verify` reports that). `Connection refused` is the
opposite: something is there and the port is closed, which on this node is
worth checking against the Proxmox firewall, since every interface is created
with `firewall=1` and a default-deny input policy stops SSH before the guest
sees it (`pve-firewall status`).

Reinstalling one is `bootstrap` and `install` with the guest named:

```sh
nix run .#provision-guests -- bootstrap hrm-edge
nix shell github:nix-community/nixos-anywhere \
  -c nix run .#provision-guests -- install hrm-edge
```

Naming it is what makes the difference in both. `bootstrap` normally leaves
the disk first in the boot order and the image second, which is what a guest
that is already installed should do; naming one puts the image first and
restarts it, because a guest being reinstalled has a bootloader on its disk
and would otherwise boot the system that is being replaced — including a
system that does not boot. `install` skips guests that are installed unless
they are named.

Once every guest is installed:

```sh
nix run .#provision-guests -- eject
```

The media is removed and the boot order reduced to the disk. It is left
attached until then on purpose: while the guest boots from its own disk the
media costs nothing, and it is the way back if an installation has to be
repeated. `eject` clears the protection flag for the length of the removal and
restores it — Proxmox refuses to remove a drive from a protected guest, which
is what protection is for.

#### Registering the host keys

Inside the development shell again, for `ssh-to-age` and `sops`:

```sh
ssh root@<address> "cat /etc/ssh/ssh_host_ed25519_key.pub" | ssh-to-age
"${EDITOR:-vi}" .sops.yaml                   # register the key for that guest
sops updatekeys secrets/<host>.yaml
git add .sops.yaml secrets/<host>.yaml

# Built here and pushed: the guests deny outbound traffic and have no build
# path of their own.
nixos-rebuild switch --flake .#<host> --target-host root@<address>
ssh root@<address> "ls -l /run/secrets/"
```

The decryption test is the rebuild, and it is not a formality: it is the same
activation that failed during the installation, failing for the reason that
made it fail — the file was encrypted to the operator alone and the guest's
key was not yet a recipient. Once it is, the secrets appear under
`/run/secrets`. If they do not, `sops-install-secrets` names the file and the
key it could not use, in the output of the rebuild.

It is not `sops -d` on the guest. `sops` is not installed there and never
needs to be: what reaches a guest is its closure, the credential file inside
it is a store path, and the component that decrypts it is the activation. The
repository is not on the guest either.

The other half of the property — that a guest cannot decrypt another guest's
file — is a property of the files, so it is checked where the files are. Each
must name exactly two recipients, the operator and the one guest it belongs
to:

```sh
grep -c 'recipient:' secrets/*.yaml          # 2 each, once every key is registered
grep -H 'recipient:' secrets/*.yaml          # and the second one is that guest's
```

A file naming a third is a file two guests can read, which defeats the
separation of policies before any policy is consulted — and it does so
silently, because the deployment succeeds either way.

Snapshot:

```sh
nix run .#provision-guests -- snapshot poc-f02
```

`snapshot` refuses to run while any guest is missing, and names the ones that
are: a snapshot of some of the guests is not a rollback point for the phase —
rolling back to it lands on a node in a state that never existed.

### F-03 — Secret store, policies and bootstrap credential

This phase builds the load-bearing link of the security chain, and it runs
before any application is deployed because it contains the test that makes the
central invariant verifiable instead of asserted.

Three machines are involved, and which command runs where is not a matter of
convenience. The store listens on 8200, and the firewall of its guest admits
that port from the application and data zones only — the management range,
which is where the node is, reaches port 22 and nothing else. So `bao` is run
on the guest that holds the store, or on a guest inside those zones; it is
never run from the node.

| Runs on | What |
| --- | --- |
| The node, in the repository | `nix build`, `nix eval`, and anything that reads a file of this repository |
| `hrm-sec`, over SSH | every `bao` command against the store |
| `hrm-app`, over SSH | the gate, which is the point of the phase |

#### The values of this deployment

They are parameters, so they are read rather than typed. On the node:

```sh
SEC_ADDR=$(nix eval --raw .#nixosConfigurations.hrm-sec.config.hermes.secretStore.address)
MOUNT=$(nix eval --raw .#nixosConfigurations.hrm-sec.config.hermes.secretStore.mount)
AUDIT=$(nix eval --raw .#nixosConfigurations.hrm-sec.config.hermes.secretStore.auditPath)
SHARES=$(nix eval .#nixosConfigurations.hrm-sec.config.hermes.secretStore.keyShares)
THRESHOLD=$(nix eval .#nixosConfigurations.hrm-sec.config.hermes.secretStore.keyThreshold)
DB_USER=$(nix eval --raw .#nixosConfigurations.hrm-mem.config.hermes.memory.postgres.user)
```

With the parameters as they stand, that is `10.102.0.14`, mount `hermes`,
audit path `/var/log/openbao`, three shares of which two are needed, and the
database role `hindsight`.

#### The listener's certificate

TLS is mandatory on the store, and the certificate is not placed by hand: the
module runs openbao under a **dynamic user**, which exists only while the unit
does, and its state directory is private to that account. There is no
`openbao` user to own a file, and no path outside the unit that it could read.

So the store issues its own on first start, self-signed, with the address of
the store in the subject alternative name — that is what every client
connects to. Nothing is required of the operator except to take a copy of the
public half, which is published where it can be read:

```sh
scp root@"$SEC_ADDR":/run/openbao/cert.pem ./openbao-cert.pem
```

That file is what verifies the listener: `BAO_CACERT` below, and later the
agents of the other guests. Replacing the certificate with one from an
internal authority is a matter of stopping the unit and writing the pair into
`/var/lib/openbao/tls`; the store keeps whatever it finds there.

#### Initialising the store

On `hrm-sec`. `bao` is the CLI of the service and is not necessarily on the
administrative PATH; the first line finds it in the closure of the unit that
is already running it:

```sh
command -v bao || export PATH="$(dirname "$(ls /nix/store/*-openbao-*/bin/bao | head -1)"):$PATH"

export BAO_ADDR="https://<secrets-address>:8200"
export BAO_CACERT=/run/openbao/cert.pem

bao operator init -key-shares=<shares> -key-threshold=<threshold>
bao operator unseal                          # repeat until the threshold is met
export BAO_TOKEN=<the root token init printed>

bao secrets enable -path=<mount> kv-v2
bao auth enable approle

for role in broker hermes memory ingress eval; do
  bao write "auth/approle/role/$role" \
    token_policies="$role" token_ttl=1h token_max_ttl=24h \
    secret_id_ttl=0 bind_secret_id=true
done

bao audit enable file file_path=<audit-path>/openbao-audit.log
```

`init` prints the unseal shares and the root token once and never again. The
shares do not stay on this guest — holding them there is equivalent to not
having them — and the root token is exported for the rest of this phase only.

The policies are built where the flake is and written where the store is.
`bao policy write` reads from standard input, which is what joins the two.
From the node:

```sh
POLICIES=$(nix build .#baoPolicies --print-out-paths)
for policy in broker hermes memory ingress eval; do
  ssh root@"$SEC_ADDR" "BAO_ADDR=https://$SEC_ADDR:8200 \
    BAO_CACERT=/run/openbao/cert.pem BAO_TOKEN=$BAO_TOKEN \
    bao policy write $policy -" < "$POLICIES/$policy.hcl"
done
```

Populate every path, on `hrm-sec`. Values arrive on stdin, never as command
arguments — arguments are visible in the process table — so each `@-` waits
for the value and is closed with Ctrl-D:

```sh
bao kv put <mount>/inference/interactive   key=@-
bao kv put <mount>/inference/programmatic  key=@-
bao kv put <mount>/inference/extraction    key=@-
bao kv put <mount>/memory/tenant_key       key=@-
bao kv put <mount>/memory/cp_key           key=@-
bao kv put <mount>/db/hindsight            username=<db-user> password=@-
bao kv put <mount>/skills/github_token     token=@-

gen() { openssl rand -base64 32; }
bao kv put <mount>/authelia/jwt_secret          value="$(gen)"
bao kv put <mount>/authelia/session_secret      value="$(gen)"
bao kv put <mount>/authelia/storage_key         value="$(gen)"
bao kv put <mount>/ui/webui_secret              value="$(gen)"
bao kv put <mount>/observability/phoenix_secret value="$(gen)"
bao kv put <mount>/eval/token                   value="$(gen)"
bao kv put <mount>/broker/tokens \
  interactive="$(gen)" programmatic="$(gen)" \
  extraction="$(gen)" eval="$(gen)"
```

Verify **completeness by difference**, not path by path:

The list is read from the guest and compared against the file on the node,
which is the only place both exist. From the node:

```sh
ssh root@"$SEC_ADDR" "BAO_ADDR=https://$SEC_ADDR:8200 \
  BAO_CACERT=/run/openbao/cert.pem BAO_TOKEN=$BAO_TOKEN \
  bao kv list -format=json $MOUNT/" | jq -r '.[]' | sort > /tmp/actual.txt
diff -u "$POLICIES/expected-paths.txt" /tmp/actual.txt && echo "COMPLETE"
```

The distinction matters. A path declared and never populated does not produce
a configuration error — it produces the failure of whichever step reads it,
and when that step is the negative test below, the failure reads as evidence
that the invariant holds.

**Gate.** On `hrm-app`, with the credential that guest holds — which is the
whole point: the test is performed by the identity under test, not on its
behalf.

```sh
export BAO_ADDR="https://<secrets-address>:8200"
export BAO_CACERT=<the copy of the store's certificate>   # see above

bao write auth/approle/login \
  role_id="$(cat /run/secrets/openbao/hermes/role_id)" \
  secret_id="$(cat /run/secrets/openbao/hermes/secret_id)"
export BAO_TOKEN=<the token that login returned>

bao kv get <mount>/inference/interactive ; echo "exit=$?"   # must FAIL, 403
bao kv get <mount>/broker/tokens     >/dev/null && echo "tokens OK"
bao kv get <mount>/memory/tenant_key >/dev/null && echo "tenant OK"
```

The refusal is then read in the audit trail, and that reading happens from the
node: `hrm-app` cannot open an SSH session to `hrm-sec` — port 22 there is
admitted from the management range alone, which is what the segmentation is
for.

```sh
ssh root@"$SEC_ADDR" "grep -c permission_denied $AUDIT/openbao-audit.log"
```

Anything other than a refusal on the first read is a blocking defect. Do not
continue: every subsequent step would build on a control that does not exist.

### F-04 — Memory platform

This phase contains the most expensive decision in the project to revisit.

**Gate, before anything is written.** Validate the embedding model against the
language of the corpus. The commonly recommended model is trained
predominantly on English text; if the working corpus is not English, the
quality of the semantic channel is affected on an axis that channel fusion
does not compensate for.

For each candidate, on a temporary bank: start the backend with that model,
load the evaluation set, **wait for consolidation**, then measure. Measuring
before consolidation gives a systematically pessimistic result. Record the
outcome in the secret store rather than in a spreadsheet, and delete the
temporary bank.

If no candidate clears the threshold, stop. Continuing means choosing between
a failed acceptance criterion and a migration with a full re-embedding —
after the first retention it is no longer a decision.

```sh
nixos-rebuild switch --flake .#<memory-host>
systemctl status podman-hermes-pg podman-hindsight --no-pager
curl -sS http://<memory-address>:8888/health
```

**Gate.** Authentication exists in the backend but ships disabled. Prove it is
on:

```sh
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://<memory-address>:8888/v1/<tenant>/banks                    # expect 401

curl -sS -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $KEY" \
  http://<memory-address>:8888/v1/<tenant>/banks                    # expect 200
```

A success in the first case means the tenant extension is not loaded. Note
that the key authenticates and does not authorise: whoever holds it reaches
every bank, and separation between profiles rests on the bank identifier and
on the segmentation.

### F-05 — Egress broker

```sh
nixos-rebuild switch --flake .#<agent-host>
systemctl status egress-broker --no-pager

curl -sS http://<broker-host>:8081/healthz
curl -sS http://<broker-host>:8081/v1/models -H "Authorization: Bearer $TOKEN" | head -c 400
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://<broker-host>:8081/v1/models -H "Authorization: Bearer invented"   # expect 401
```

Confirm the model identifiers against the catalogue returned **through the
broker**, not against a direct call. Then verify that the spending cap
actually refuses: set the hard cap deliberately low, drive spend past it, and
check for a rejection carrying a retry hint. A cap that does not intervene is
an intention, not a boundary.

Check that the unattributed-cost counter stays at zero. If it grows, the cap
keeps working but becomes blind.

### F-06 — Interactive agentic plane

```sh
nixos-rebuild switch --flake .#<agent-host>
systemctl status container@hermes-core container@hermes-svc --no-pager
systemctl status hermes-provision-profiles --no-pager

ss -lntp | grep 8000                          # bound to loopback, not the wildcard
nixos-rebuild switch --flake .#<agent-host>   # idempotence: no change on the second run
```

Confirm one bank per profile, with distinct and non-intersecting identifiers.
A single bank shared by several profiles means the bank template is wrong, or
a profile resolves to the empty string and the static fallback has engaged —
stop there.

**Gate.** Run from inside the agentic loop, with the same tool a compromised
execution would have, not from outside with a service inspector:

```sh
python -c "import os; print({k: v[:6]+'...' for k, v in os.environ.items() \
  if any(s in k.upper() for s in ('KEY','TOKEN','SECRET'))})"

grep -rIl "sk-or-" /proc/self/environ /run/secrets /var/lib/hermes 2>/dev/null \
  || echo "no occurrence"

curl -sS --max-time 10 -o /dev/null -w "%{http_code}\n" \
  https://openrouter.ai/api/v1/models || echo "blocked"
```

Only the internal broker token may appear. Direct egress to the gateway must
be blocked: the agentic user is not among those admitted. If the real key
appears, the containment is not implemented — that is a blocking defect, not
an observation.

### F-07 — Ingress, identity and interface

```sh
nixos-rebuild switch --flake .#<ingress-host>
curl -sSI https://<public-fqdn>/ | head -5           # expect a redirect to the portal

systemctl stop authelia-main
curl -sS -o /dev/null -w "%{http_code}\n" https://<public-fqdn>/   # expect 5xx
systemctl start authelia-main
```

With the identity provider stopped the answer must be a failure, not a
success. A success means the verification path is bypassable.

**Gate.** The trusted-header model is only as good as the guarantee that the
proxy is the sole path:

```sh
# forged identity header from the client
curl -sS https://<public-fqdn>/ -H "Remote-Email: <other-user>" \
  -o /dev/null -w "%{http_code}\n"

# downstream services from the user network: must not be routable
for port in 8000 8888 8200; do
  timeout 5 bash -c "echo > /dev/tcp/<agent-address>/$port" 2>/dev/null \
    && echo "$port REACHABLE — DEFECT" || echo "$port not routable"
done

# chat interface, bypassing the proxy
timeout 5 bash -c "echo > /dev/tcp/<ingress-edge-address>/8080" 2>/dev/null \
  && echo "REACHABLE — DEFECT" || echo "refused (loopback bind)"
```

No impersonation may succeed, and the downstream ports must be *unroutable*
rather than refused at the application: the request must not arrive.

### F-08 — Programmatic plane

```sh
systemctl list-timers | grep hermes-svc
systemctl start hermes-svc-<workload>
journalctl -u hermes-svc-<workload> -n 50 --no-pager
```

**Gate — five isolation checks.** Distinct profile; distinct and
non-intersecting bank; distinct inference workspace, visible as separate plane
labels on the cost metric; the interactive concurrency cap not consumed by the
batch plane; and interactive latency under batch load within the ratified
delta.

The fifth is the one that matters most. If the first four pass and the fifth
fails, the isolation objective is violated in fact while satisfying its formal
checks — and the countermeasures are the connection share reserved for the
interactive plane together with the workload concurrency cap.

### F-09 — Observability

Bring up the evaluation platform first. Starting the collection stack against
a backend that does not exist makes the exporter fail silently.

```sh
nixos-rebuild switch --flake .#<observability-host>
systemctl status phoenix --no-pager
stat -c "%a %U:%G" /run/secrets/phoenix.env       # expect 400, owned by the service
systemctl show phoenix -p MemoryMax -p MemoryHigh -p MemoryAccounting
```

Then verify end-to-end correlation. **The test turn must contain a
delegation**: a simple turn passes the step without exercising the check that
matters. Confirm that the delegation span carries the depth and children
attributes. If they are absent, stop — continuing does not make the cost
measurement approximate, it makes it invalid, because a turn that fanned out
to nine workers becomes indistinguishable from a simple one.

**Gate — closed enumeration of the artefacts holding content.** This is no
longer a test of absence but a test of membership, and the criterion is
inverted: finding content is not itself a failure, it depends on where. Send a
turn containing an improbable known phrase, then confirm it is absent from the
shared backends, present in the evaluation platform, and that the trace
pipeline has exactly one exporter. More than one exporter is a violation even
when the shared backends are clean.

Finally, create the evaluation dataset and run the first experiment. The
evaluators call the broker, never the gateway. Repeat the run unchanged: the
outcome must be stable, and evaluation spend must appear as its own labelled
channel, excluded from the cost-per-task figure.

### F-10 — Measurement

The last phase installs nothing. It produces the numbers that decide whether
the deployment is accepted, and two of those numbers are the only results this
exercise generates rather than consumes: the concurrency ceiling of the
agentic guest and the memory footprint per instance.

Measure cost per task across **every** attributable spending channel — the
main loop, delegation, deliberation and memory extraction. Measured without
the extraction channel the result looks better and is not the quantity the
objective asks for. Evaluation spend is excluded, and that exclusion is
prescribed rather than an oversight: extraction is spend *of* the task,
evaluation is spend *on* it.

Measure semantic recall only after consolidation has run.

Then exercise the restore path end to end. Copies are written to a path local
to the guest that owns the data and encrypted at rest; collection towards the
backup target is the node's responsibility. No data-zone guest mounts the
backup storage — that would open a flow from the data zone to the management
segment which the segmentation does not have. Restore in the binding order,
then confirm that a fact predating the backup is retrievable.

> Destroying the environment and rebuilding it from the flake is the
> strongest demonstration of reproducibility available, and it is worth doing
> even when everything works. It is the only test passed by doing exactly what
> would be done in a disaster.

---

## Compile-time variables

These are declared in `parameters.nix` and resolved when the configuration is
built. They end up in the Nix store, which is readable by every user of the
system: **no secret belongs here.** Runtime secrets are documented in
[`.env.example`](.env.example).

The `Default` column follows one rule throughout. A parameter encoding an
architectural decision carries a default, and that default records what was
decided. A parameter encoding a fact about a specific installation carries
none — shown as **—** — because an undefined parameter is reported by name at
evaluation time, which is better than a plausible value that happens to be
wrong.

### Review gate

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.parametersReviewed` | boolean | Acknowledgement that every parameter has been checked against the site it describes. The configuration refuses to evaluate while it is false. Types cannot distinguish a plausible address from the right one; this is where somebody states that they checked. | — |

### Node and storage

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.site.storage.default` | string | Storage pool backing the guests that have no dedicated device. | — |
| `hermes.site.storage.memory` | string | Storage pool dedicated to the memory guest. Must be a physically separate device. | — |
| `hermes.site.storage.fsyncMinimum` | integer | Lowest acceptable fsync rate on the pool hosting the vector index, in operations per second. | `200` |
| `hermes.site.storage.iso` | string | Pool holding the installation image. Must carry `content=iso`. | `local` |
| `hermes.site.installerImage` | string | File name of the installation image on that pool. Two places have to agree on it: the image this flake builds and the media the provisioning script attaches. | `hermes-installer.iso` |
| `hermes.site.backupTarget` | string | Storage receiving guest-level backups. | — |
| `hermes.site.backupMountPoint` | path | Mount point of the backup storage on the node. | — |
| `hermes.site.numa` | boolean | Expose a NUMA topology to the guests. Enable only on a node with more than one node. | `false` |

### Network

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.network.timeZone` | string | Time zone of the guests. | — |
| `hermes.network.nameservers` | list of IPv4 | Resolvers configured on the guests. | — |
| `hermes.network.ntpServers` | list of string | Time sources. Correlated telemetry across guests depends on them. | — |
| `hermes.network.bridge` | string | VLAN-aware bridge the guest interfaces attach to. | — |
| `hermes.network.managementCidr` | CIDR | The only range from which administrative access is accepted. | — |
| `hermes.network.zones.edge.vlanId` | integer, 1–4094 | VLAN carrying the user-facing zone. | — |
| `hermes.network.zones.edge.cidr` | CIDR | Range of the user-facing zone. | — |
| `hermes.network.zones.app.vlanId` | integer, 1–4094 | VLAN carrying the application zone. | — |
| `hermes.network.zones.app.cidr` | CIDR | Range of the application zone. | — |
| `hermes.network.zones.data.vlanId` | integer, 1–4094 | VLAN carrying the data zone. | — |
| `hermes.network.zones.data.cidr` | CIDR | Range of the data zone. Not routable from the user network. | — |
| `hermes.network.perimeterFirewall` | string | Device applying the perimeter policy, and therefore the only place the outbound restriction to the gateway *by name* can be expressed. | — |
| `hermes.network.egressPolicy` | `direct` \| `proxy` | Whether outbound traffic reaches the gateway directly or through a proxy. | `direct` |
| `hermes.network.containerHostAddress` | IPv4 | Host side of the private network shared with the agentic containers. | — |
| `hermes.network.containerInteractiveAddress` | IPv4 | Address of the interactive-plane container. | — |
| `hermes.network.containerProgrammaticAddress` | IPv4 | Address of the programmatic-plane container. | — |

### Guests

Declared per role under `hermes.guests.<role>`, where `<role>` is one of
`ingress`, `agent`, `memory`, `secrets`, `observability`.

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hostName` | string | Host name of the guest, and the name of its NixOS configuration. | role name |
| `vmid` | integer | Proxmox VMID. Must be free on the node before provisioning. | — |
| `cores` | integer | Virtual CPUs. Proxmox refuses to start a guest whose count exceeds the physical cores. | — |
| `memoryMb` | integer | Fixed memory assignment. Ballooning is disabled. | — |
| `diskGb` | integer | Size of the root volume. | — |
| `storage` | string | Storage pool backing the root volume. | — |
| `diskFormat` | `raw` \| `qcow2` | Image format. On a directory-backed pool `qcow2` is mandatory: with `raw` there are no per-phase snapshots and the installation loses its rollback points. | `raw` |
| `extraDisks` | list of volume | Additional volumes, each with `sizeGb`, `storage` and `mountPoint`. | `[ ]` |
| `zone` | `edge` \| `app` \| `data` | Primary network zone. | — |
| `address` | IPv4 | Address of the primary interface. | — |
| `macAddress` | MAC | Hardware address of the primary interface, locally administered and derived from the VMID. It is what lets one installation image serve every guest: the image carries a table keyed by it, and these zones have no DHCP server to hand a machine its address before it is installed. | derived |
| `extraInterfaces` | list of interface | Additional interfaces, each with `zone` and `address`. Only the ingress guest is dual-homed. | `[ ]` |
| `bootOrder` | integer, 1–5 | Start order. Binding rather than conventional: a service started before the secret store does not find its credentials. | — |
| `bootDelay` | integer | Seconds before the next guest in the order is released. | `30` |
| `cpuLimit` | float or null | Node CPU share, where `1.0` is a full core. Set on the agentic guest so a delegation fan-out cannot saturate the node. | `null` |
| `aliasOf` | string or null | Role hosting this one. An aliased guest is not created. The agentic role is never a valid target. | `null` |

### Build and provisioning

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.nix.stateVersion` | string | NixOS state version of the guests. Never raised as a side effect of an unrelated change. | — |
| `hermes.nix.substituters` | list of string | Binary caches consulted during a rebuild. | — |
| `hermes.nix.buildHost` | string or null | Host performing the builds. The agentic guest denies outbound traffic and has no working local build path. | `null` |
| `hermes.nix.provisioningMethod` | `iso` \| `nixos-anywhere` \| `template-clone` | Method used for the first installation of a guest. | `nixos-anywhere` |
| `hermes.nix.adminKeys` | list of string | SSH public keys admitted as root, on the guests and on the installation image alike. Password authentication is disabled on both, so this is the only way in — including for the step that reads a guest's host key back to encrypt its credentials to it. | — |
| `hermes.nix.rootDevice` | string | Block device carrying the root volume inside the guest. Follows the attachment in `pve-provision.nix` — the root volume is `scsi0`, the additional ones follow as `sdb` onwards. | `/dev/sda` |
| `hermes.nix.sopsAgeKeyPath` | path | Private key from which the age identity is derived. Deriving it from the host key means there is no extra key to distribute. | `/etc/ssh/ssh_host_ed25519_key` |

### Secret store

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.secretStore.address` | IPv4 | Address of the store as reached by the other guests. | — |
| `hermes.secretStore.port` | port | API port. Always TLS, including on the internal network. | `8200` |
| `hermes.secretStore.clusterPort` | port | Cluster port. | `8201` |
| `hermes.secretStore.mount` | string | Mount point of the key-value engine holding the operational secrets. | — |
| `hermes.secretStore.unsealMethod` | `shamir-manual` \| `auto-unseal` | How the store is unsealed after a restart. With the manual method a reboot needs a human, which is a legitimate choice and one worth knowing in advance. | `shamir-manual` |
| `hermes.secretStore.keyShares` | integer | Unseal key shares produced at initialisation. | `3` |
| `hermes.secretStore.keyThreshold` | integer | Shares required to unseal. | `2` |
| `hermes.secretStore.auditPath` | path | Directory holding the audit device — the documentary evidence that the policy separation is enforced. | — |
| `hermes.secretStore.tokenTtl` | duration | Lifetime of a token issued to a machine identity. | `1h` |
| `hermes.secretStore.tokenMaxTtl` | duration | Upper bound on token renewal. | `24h` |
| `hermes.secretStore.renderInterval` | duration | Interval at which the agent re-renders static secrets. | `5m` |
| `hermes.secretStore.cacheTtl` | duration | How long a guest survives a sealed store on its local cache. | `30m` |
| `hermes.secretStore.retries` | integer | Connection attempts before the agent gives up on a render cycle. | `3` |
| `hermes.secretStore.runtimeSecretsPath` | path | Directory the rendered environment files are written to. A tmpfs: values never reach the disk or the Nix store. | `/run/secrets` |

### Egress broker

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.broker.listenAddress` | IPv4 | Address the broker binds to. | — |
| `hermes.broker.host` | IPv4 | Address of the broker as seen by its clients. | — |
| `hermes.broker.port` | port | Port of the broker. | `8081` |
| `hermes.broker.upstream` | string | Base address of the inference gateway. The only component allowed to reach it. | `https://openrouter.ai/api/v1` |
| `hermes.broker.uid` | integer | System user of the broker. The outbound rules distinguish processes by user, because the broker and the agentic containers share a guest. | — |
| `hermes.broker.maxConnections` | integer | Concurrent connections towards the gateway. | `32` |
| `hermes.broker.reserveInteractive` | float, 0–1 | Share of the connection budget reserved for the interactive plane. | — |
| `hermes.broker.budgetSoft` | float | Spend threshold, per plane and profile, that raises an alert. | — |
| `hermes.broker.budgetHard` | float | Spend threshold that rejects further requests. Enforcement lags by one request, because the real cost is read back from the gateway rather than estimated. | — |
| `hermes.broker.budgetWindowSeconds` | integer | Length of the rolling spend window. | `86400` |
| `hermes.broker.timeout` | duration | Upper bound on a single gateway request. | `600s` |
| `hermes.broker.replicas` | integer | Local instances. A single instance is a single point of failure for both planes. | `1` |

### Memory platform

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.memory.postgres.image` | image reference | Digest-pinned image of the relational store. The type rejects a tag: a tag is a moving reference. | — |
| `hermes.memory.postgres.user` | string | Database role used by the memory backend. | — |
| `hermes.memory.postgres.database` | string | Database holding the knowledge store. | — |
| `hermes.memory.postgres.schema` | string | Schema holding the knowledge store. Never the default schema. | — |
| `hermes.memory.postgres.dataPath` | path | Persistent volume of the store. | — |
| `hermes.memory.postgres.uid` | integer | Owner of the persistent volume. | — |
| `hermes.memory.postgres.vectorExtension` | string | Extension providing the vector index and nearest-neighbour search. | — |
| `hermes.memory.hindsight.image` | image reference | Digest-pinned image of the memory backend. | — |
| `hermes.memory.hindsight.apiPort` | port | Port serving retention, retrieval and synthesis. | `8888` |
| `hermes.memory.hindsight.controlPlanePort` | port | Port serving the inspection console. | `9999` |
| `hermes.memory.hindsight.tenant` | string | Tenant the banks belong to. | — |
| `hermes.memory.hindsight.workerId` | string | Stable worker identity. Without it the worker adopts the container host name and an operation in flight stays parked under an identifier nobody claims again. | — |
| `hermes.memory.hindsight.bankTemplate` | string | Template deriving a bank from a profile. **This is the tenancy boundary**: the backend key has no per-bank scope, so a mistake here collapses several users onto one bank with no visible error. | `hermes-{profile}` |
| `hermes.memory.hindsight.recallBudget` | `low` \| `mid` \| `high` | Retrieval effort spent before each turn. | — |
| `hermes.memory.hindsight.recallMaxTokens` | integer | Upper bound on the injected context. | — |
| `hermes.memory.hindsight.retainEveryNTurns` | integer | Turn interval between retention operations. | `1` |
| `hermes.memory.hindsight.retainMaxConcurrent` | integer | Concurrent extraction operations. | — |
| `hermes.memory.hindsight.llmMaxConcurrent` | integer | Concurrent inference calls issued by the backend. | — |
| `hermes.memory.hindsight.llmRetries` | integer | Retries on a failed extraction call. | `3` |
| `hermes.memory.hindsight.llmTimeout` | integer | Timeout of an extraction call, in seconds. | `120` |
| `hermes.memory.hindsight.textLanguage` | string | Dictionary used by the full-text channel. | — |
| `hermes.memory.hindsight.strictSchema` | boolean | Reject facts that do not match the declared schema. | `false` |
| `hermes.memory.hindsight.reranker` | string | Fusion strategy over the four channels. The rank-based strategy is algorithmic and keeps a CPU-bound model off the recall path. | `rrf` |
| `hermes.memory.hindsight.memoryMode` | `off` \| `hybrid` | Memory mode of the interactive profiles. | `hybrid` |
| `hermes.memory.embedding.provider` | `local` \| `remote` | Where embeddings are computed. Local keeps content inside the perimeter. | `local` |
| `hermes.memory.embedding.model` | string | Embedding model. **Irreversible after the first retention.** Validate against the language of the corpus first. | — |
| `hermes.memory.embedding.dimensions` | integer | Vector dimensionality. Irreversible together with the model. | — |
| `hermes.memory.embedding.candidates` | list of string | Models compared during the validation that precedes the freeze. | `[ ]` |
| `hermes.memory.retention.session` | duration | Retention of the session level. | — |
| `hermes.memory.retention.semantic` | duration | Retention of the semantic level. | — |
| `hermes.memory.tlsInternal` | boolean | Require TLS on the application-to-data path. | `true` |

### Agent runtime

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.agent.sourceRevision` | string | Pinned revision of the runtime fork this project versions. Never a moving reference. | — |
| `hermes.agent.uid` | integer | System user of the runtime, matched by the outbound rules. | — |
| `hermes.agent.statePath` | path | Persistent volume of the interactive plane. | — |
| `hermes.agent.servicePath` | path | Persistent volume of the programmatic plane. | — |
| `hermes.agent.api.bindAddress` | IPv4 | Address the API server binds to. Never the wildcard address: the proxy is the only admitted path. | — |
| `hermes.agent.api.port` | port | Port of the API server. | `8000` |
| `hermes.agent.api.profilePrefix` | string | Path prefix under which a profile is served, resolved at the ingress and never taken from the request body. | — |
| `hermes.agent.api.maxConcurrent` | integer | Concurrent runs admitted on the interactive plane. | — |
| `hermes.agent.profilePrefixUser` | string | Prefix of user profile names. | — |
| `hermes.agent.profilePrefixService` | string | Prefix of service profile names. | `svc` |
| `hermes.agent.maxSpawnDepth` | integer, 0–2 | Delegation levels below the root agent, counted as spawn levels rather than tree nodes. | `2` |
| `hermes.agent.maxConcurrentChildren` | integer | Subordinates a single agent may run at once. | — |
| `hermes.agent.maxIterations` | integer | Iteration cap of an interactive run. | — |
| `hermes.agent.skillsTapRepository` | string or null | Additional skill registry. Null limits the catalogue to the sources built into the runtime. | `null` |
| `hermes.agent.timeouts.inference` | duration | Upper bound on a call from the agent to the broker. | `300s` |
| `hermes.agent.timeouts.recall` | duration | Upper bound on a retrieval. Exceeding it degrades the turn rather than failing it. | `2s` |
| `hermes.agent.retries.broker` | integer | Retries on a failed broker call. | `2` |
| `hermes.agent.retries.memory` | integer | Retries on a failed retrieval. | `1` |
| `hermes.agent.circuitBreaker.brokerThreshold` | integer | Consecutive failures that open the circuit towards the broker. | `5` |
| `hermes.agent.circuitBreaker.brokerReset` | duration | Delay before the circuit is probed again. | `60s` |
| `hermes.agent.circuitBreaker.memoryThreshold` | integer | Consecutive failures that open the circuit towards the memory backend. | `3` |

### Models

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.models.main` | model slug | Model driving the agentic loop. | — |
| `hermes.models.deliberation` | model slug | Multi-model deliberation alias. Selectivity is left to the gateway's own gate; no custom routing layer is introduced. | `openrouter/fusion` |
| `hermes.models.delegation` | model slug | Model used by the delegation slot. | — |
| `hermes.models.auxiliaryDefault` | model slug | Model backing the auxiliary slots: compression, titles, query rewriting. | — |
| `hermes.models.memoryRetain` | model slug | Model extracting facts during retention. | — |
| `hermes.models.memoryReflect` | model slug | Model performing cross-memory synthesis. | — |
| `hermes.models.memoryConsolidation` | model slug | Model consolidating facts into observations. | — |
| `hermes.models.evaluation` | model slug | Model backing the evaluators. | — |
| `hermes.models.temperatureMain` | float, 0–2 | Sampling temperature of the main slot. | — |
| `hermes.models.reasoning.main` | boolean | Reasoning on the main slot. Its tokens are billed as output and count towards the cost target. | — |
| `hermes.models.reasoning.mainEffort` | `low` … `max` | Reasoning effort of the main slot. | `low` |
| `hermes.models.reasoning.delegation` | boolean | Reasoning on the delegation slot. | `false` |
| `hermes.models.reasoning.auxiliary` | boolean | Reasoning on the auxiliary slots. | `false` |
| `hermes.models.reasoning.memory` | boolean | Reasoning on the memory extraction slots. | `false` |
| `hermes.models.gateway.zeroDataRetention` | boolean | Request the gateway's zero-retention mode. | `true` |
| `hermes.models.gateway.referer` | string | Calling application address reported to the gateway. | — |
| `hermes.models.gateway.appTitle` | string | Calling application name reported to the gateway. | — |
| `hermes.models.gateway.timeout` | duration | Upper bound on a gateway call. | `600s` |
| `hermes.models.gateway.retries` | integer | Retries on a failed gateway call. | `3` |

### Identity

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.identity.users` | list of `{ identity, profile }` | Explicit identity-to-profile map. An enumeration, never a transformation: an enumeration fails visibly on an unknown identity, while a normalisation can collapse two identities onto one profile — and one memory bank — silently. | `[ ]` |
| `hermes.identity.operators` | list of string | Identities allowed to reach the operator consoles. | `[ ]` |
| `hermes.identity.groups.users` | string | Group granting access to the chat interface. | — |
| `hermes.identity.groups.operators` | string | Group granting access to the operator consoles. | — |
| `hermes.identity.port` | port | Port of the identity provider, bound to loopback. | `9091` |
| `hermes.identity.metricsPort` | port | Port exposing the identity provider metrics. | `9959` |
| `hermes.identity.subjectClaim` | `email` \| `username` | Claim carrying the identity used for profile resolution. | `email` |
| `hermes.identity.session.expiration` | duration | Absolute lifetime of a session. | — |
| `hermes.identity.session.inactivity` | duration | Idle time after which a session closes. | — |
| `hermes.identity.session.rememberMe` | duration | Lifetime of a persistent session. Zero disables it. | `0` |
| `hermes.identity.regulation.maxRetries` | integer | Failed attempts before a ban. | `3` |
| `hermes.identity.regulation.findTime` | duration | Window over which failures are counted. | `2m` |
| `hermes.identity.regulation.banTime` | duration | Duration of the ban. | `15m` |
| `hermes.identity.logLevel` | enum | Log level of the identity provider. | `info` |

### Ingress

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.ingress.publicFqdn` | string | Name under which the chat interface is published. | — |
| `hermes.ingress.controlPlaneFqdn` | string | Name under which the memory inspection console is published. | — |
| `hermes.ingress.cookieDomain` | string | Parent domain the session cookie is issued for. | — |
| `hermes.ingress.tls.source` | `acme` \| `internal-ca` \| `manual` | Origin of the certificate material. | — |
| `hermes.ingress.tls.certificate` | path | Path of the certificate chain. | — |
| `hermes.ingress.tls.key` | path | Path of the private key. | — |
| `hermes.ingress.tls.minimumVersion` | `TLSv1.2` \| `TLSv1.3` | Lowest protocol version accepted. | `TLSv1.3` |
| `hermes.ingress.corsAllowedOrigins` | string | Explicit origin allow-list. An assertion rejects a wildcard: a wildcard is not an allow-list. | — |
| `hermes.ingress.rateLimit.auth` | string | Request rate admitted on the authentication routes. | `10r/m` |
| `hermes.ingress.rateLimit.burst` | integer | Burst tolerated above that rate. | `5` |
| `hermes.ingress.timeouts.clientConnect` | duration | Upper bound on establishing a client connection. | `10s` |
| `hermes.ingress.timeouts.clientRead` | duration | Upper bound on a client read. Long enough to carry a streamed answer. | `600s` |
| `hermes.ingress.timeouts.proxyConnect` | duration | Upper bound on establishing an upstream connection. | `10s` |
| `hermes.ingress.timeouts.proxyRead` | duration | Upper bound on an upstream read. | `600s` |
| `hermes.ingress.webui.image` | image reference | Digest-pinned image of the chat interface. | — |
| `hermes.ingress.webui.port` | port | Loopback port of the chat interface. It is never published. | `8080` |
| `hermes.ingress.webui.dataPath` | path | Persistent volume of the chat interface. | — |
| `hermes.ingress.identityMapPath` | path | File holding the identity-to-profile map consumed by the proxy, generated from the same declaration that provisions the profiles. | `/etc/hermes/identity-map.conf` |

### Programmatic plane

Workloads are declared under `hermes.programmatic.workloads.<name>`.

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `schedule` | string | Calendar expression triggering the workload. | — |
| `jitter` | duration | Randomised delay applied to the trigger. | `5m` |
| `timeout` | duration | Upper bound on a single run. | — |
| `outputPath` | path | Directory the produced artefact is written to. | — |
| `toolsets` | list of string | Toolsets granted, **declared by inclusion**. A list of exclusions only protects against the capabilities somebody thought of excluding. | — |
| `maxIterations` | integer | Iteration cap. In an unattended job this is a spending cap before it is a correctness cap. | — |
| `memoryMode` | `off` \| `hybrid` | Persistent memory. Enabled only when state must survive between runs, and then on a service bank disjoint from every user bank. | `off` |
| `hermes.programmatic.maxConcurrentWorkloads` | integer | Workloads admitted to run at the same time. | `1` |
| `hermes.programmatic.cpuWeight` | integer | Relative CPU weight of the batch slice. | `50` |
| `hermes.programmatic.memoryHigh` | string | Soft memory ceiling of the batch slice. | — |

### Observability

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.observability.collectorGrpcPort` | port | Port receiving telemetry over gRPC. | `4317` |
| `hermes.observability.collectorHttpPort` | port | Port receiving telemetry over HTTP. | `4318` |
| `hermes.observability.collectorConfigPath` | path | Path of the rendered collector configuration. | `/etc/otel/collector.yaml` |
| `hermes.observability.metricsPort` | port | Port of the metrics backend. | `9090` |
| `hermes.observability.logsPort` | port | Port of the log backend. | `3100` |
| `hermes.observability.dashboardPort` | port | Port of the dashboard interface. | `3000` |
| `hermes.observability.address` | IPv4 | Address telemetry is sent to. A parameter of its own so that consolidating the role does not rewrite every producer. | — |
| `hermes.observability.dataPath` | path | Mount point of the volume holding observability state. | — |
| `hermes.observability.scrapeInterval` | duration | Interval between metric collections. | `15s` |
| `hermes.observability.logLevel` | enum | Log level of the platform services. A debug level left on is the most frequent cause of content reaching a shared backend, and the least visible. | `info` |
| `hermes.observability.retention.observability` | integer | Retention of metrics and logs, in days. | — |
| `hermes.observability.retention.audit` | duration | Retention of the audit trail. Always longer than the observability retention. | — |
| `hermes.observability.retention.trajectory` | duration | Retention of the trajectory files. | — |
| `hermes.observability.instrumentation.revision` | string | Pinned revision of the instrumentation. It must expose the declared trace semantics: a revision predating them passes the deployment phase and invalidates the cost measurement. | — |
| `hermes.observability.instrumentation.eventsPath` | path | Directory holding the event stream. Metrics and identifiers only. | — |
| `hermes.observability.instrumentation.trajectoryPath` | path | Directory holding the trajectory files. Contains content: restricted permissions, no shared-backend exporter. | — |
| `hermes.observability.instrumentation.traceSemantics` | string | Trace semantics declared by the instrumentation and expected by the trace backend. | `openinference` |
| `hermes.observability.instrumentation.hideInputs` | boolean | Suppress prompt attributes. Suppressing them removes the evaluators' input. | `false` |
| `hermes.observability.instrumentation.hideOutputs` | boolean | Suppress completion attributes. | `false` |
| `hermes.observability.evaluation.image` | image reference | Digest-pinned image of the evaluation platform. It is carried as an image because it has no package in nixpkgs. Resolve the digest with `skopeo inspect docker://arizephoenix/phoenix:<tag>`. | — |
| `hermes.observability.evaluation.bindAddress` | IPv4 | Address the evaluation platform binds to. Neither the wildcard address nor loopback: it is reached through the proxy. | — |
| `hermes.observability.evaluation.port` | port | Port serving the evaluation console and telemetry over HTTP. | `6006` |
| `hermes.observability.evaluation.grpcPort` | port | Port receiving telemetry over gRPC. Deliberately not the conventional one — an assertion rejects a collision with the collector. | — |
| `hermes.observability.evaluation.fqdn` | string | Name under which the evaluation console is published. | — |
| `hermes.observability.evaluation.workingDirectory` | path | State directory. Restricted permissions, because of what it holds. | — |
| `hermes.observability.evaluation.databaseUrl` | string | Connection string of the evaluation platform store. | — |
| `hermes.observability.evaluation.projectName` | string | Project the traces are filed under. | — |
| `hermes.observability.evaluation.retentionDays` | integer | Retention of the evaluation platform. Aligned with the trajectory retention, not the observability one: it is an artefact that contains content. | — |
| `hermes.observability.evaluation.enableNativeAuth` | boolean | Use the platform's own authentication. Disabled: there is one identity provider. | `false` |
| `hermes.observability.evaluation.memoryHigh` | string | Soft memory ceiling. It does not add memory; it decides which process is reclaimed first. | — |
| `hermes.observability.evaluation.memoryMax` | string | Hard memory ceiling. | — |
| `hermes.observability.evaluation.secretStoreMemoryMin` | string | Memory floor guaranteed to the secret store on a consolidated guest. Losing the vault costs more than losing observability. | — |
| `hermes.observability.evaluation.dataset` | string | Name of the versioned evaluation dataset. | — |
| `hermes.observability.evaluation.evaluators` | list of string | Evaluators executed by an experiment. | — |
| `hermes.observability.evaluation.temperature` | float | Sampling temperature of the evaluators. Zero is required: a non-deterministic evaluation does not detect drift, it imitates it. | `0.0` |
| `hermes.observability.evaluation.concurrency` | integer | Concurrent evaluator calls, bounded by the capacity the interactive plane does not reserve. | — |
| `hermes.observability.alerts.window` | duration | Evaluation window of the platform rules. | `5m` |
| `hermes.observability.alerts.memoryWindow` | duration | Evaluation window of the memory rules, longer because the signal is slower. | `15m` |
| `hermes.observability.alerts.latencyP95` | duration | Interactive latency at the ninety-fifth percentile above which an alert is raised. | — |
| `hermes.observability.alerts.recallP95` | duration | Retrieval latency at the ninety-fifth percentile above which an alert is raised. | — |
| `hermes.observability.alerts.recallCoverageMin` | float, 0–1 | Lowest admitted share of turns served with memory context. Retrieval degradation is silent by construction; this rule is where it becomes visible. | — |
| `hermes.observability.alerts.retainQueue` | integer | Extraction queue depth above which an alert is raised. | — |
| `hermes.observability.alerts.costDaily` | float | Daily spend, across attributable channels, above which an alert is raised. | — |
| `hermes.observability.alerts.errorRate` | float | Errors per minute above which an alert is raised. | — |
| `hermes.observability.alerts.workloadDuration` | duration | Unattended run duration above which an alert is raised. | — |
| `hermes.observability.alerts.workloadFailures` | float | Failed unattended runs over the window above which an alert is raised. | — |
| `hermes.observability.alerts.deliberationRatioMax` | float, 0–1 | Share of turns triggering deliberation above which an alert is raised. | `0.10` |

### Backup

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.backup.stagingPath` | path | Path local to the guest owning the data, where copies are written before collection. No data-zone guest mounts the backup storage: that would open a flow the segmentation does not have. | — |
| `hermes.backup.ageRecipient` | string | Public key encrypting the copies at rest. Distinct from the key protecting the bootstrap credential, and held outside the node. | — |
| `hermes.backup.encryption` | `none` \| `at-rest` \| `in-transit` \| `both` | Protection applied to the copies. | `at-rest` |
| `hermes.backup.schedules` | attribute set of string | Calendar expressions of the backup jobs, keyed by artefact. | `{ }` |
| `hermes.backup.restoreTestFrequency` | duration | Interval between restore exercises. An unverified backup is not a backup. | — |
| `hermes.backup.nfs.server` | string or null | Appliance exporting the backup storage. | `null` |
| `hermes.backup.nfs.exportPath` | string or null | Exported path mounted by the node. | `null` |
| `hermes.backup.nfs.mountOptions` | list of string | Mount options. A soft mount turns a network timeout into a truncated backup that exits successfully, discovered only at restore time. | `[ ]` |

### Objectives and thresholds

| Variable | Type | Description | Default |
| --- | --- | --- | --- |
| `hermes.objectives.latencyP95` | duration | Target interactive latency at the ninety-fifth percentile. | — |
| `hermes.objectives.latencyDeliberationP95` | duration | Target latency for a turn that deliberates. | — |
| `hermes.objectives.turnsPerMinute` | integer | Throughput the platform is expected to sustain. | — |
| `hermes.objectives.degradeMax` | float, 0–1 | Highest admitted degradation under load before the ceiling is considered reached. | — |
| `hermes.objectives.soakDuration` | duration | Duration of the endurance run. | — |
| `hermes.objectives.bankSize` | integer | Size of the memory bank used by the representative sample. | — |
| `hermes.objectives.sampleWindow` | duration | Window over which the acceptance measurements are read. | — |
| `hermes.objectives.crossPlaneDelta` | float, 0–1 | Highest admitted increase of interactive latency while the programmatic plane is under load. The four structural checks can all pass while this one fails. | — |
| `hermes.objectives.recoveryPointObjective` | duration | Highest admitted data loss after a recovery. | — |
| `hermes.objectives.recoveryTimeObjective` | duration | Highest admitted time to restore the service. | — |
| `hermes.objectives.meanTimeToRecovery` | duration | Target repair time for a platform component. | — |
| `hermes.objectives.meanTimeToRecoveryEvaluation` | duration | Target repair time for the evaluation platform, off the hot path and therefore longer. | — |
| `hermes.objectives.rotationPeriod` | duration | Default rotation period of the operational secrets. | — |

---

## Runtime variables

Every runtime variable is a secret. They are held by the secret store,
rendered by its agent into a tmpfs, and read from there through
`EnvironmentFile`. None of them belongs in `parameters.nix`, and none of them
is ever written into this repository.

[`.env.example`](.env.example) documents each one: which service receives it,
which environment file it is rendered into, and which secret-store path holds
it. What you write next to a name there is the **path**, never the value.

The one exception is the bootstrap credential with which each guest proves its
identity to the store. It cannot come from the store, because it is what opens
it. It is encrypted with `sops`, versioned under `secrets/`, and decrypted at
system activation.

---

## Operating notes

### Two rebuilds must produce no change

Idempotence is a property to verify, not to assume. A second
`nixos-rebuild switch` that reports changes means something is being
configured outside the flake.

### Never create a profile by hand

A manually created profile works, and is still a defect. Profile creation,
bank creation and bearer generation are one idempotent unit, and the risk it
exists to mitigate — a workload running inside a user profile — is not
detectable by looking at a working system.

### Rotating a gateway credential requires no rebuild

The broker reads its credentials from the runtime directory and reloads them
on signal. This is the direct operational benefit of keeping the credential
outside the agentic perimeter, and it is worth using rather than working
around.

### The variable somebody will eventually "fix"

The agentic runtime has an environment variable named after the
OpenAI-compatible convention, and it does not contain a gateway key: it
contains the internal broker token. The name suggests otherwise, and an
operator acting in good faith may try to repair it. The test at F-06 catches
it once; what protects it over time is the policy, which makes the real key
unreadable from that guest even to somebody who wants to put it there.

### Adding a trace backend

There is one supported way: a **separate** pipeline with scrubbing enabled.
Adding an exporter to the existing trace pipeline creates a fourth artefact
holding conversational content without declaring it, and produces no error.
The alert that watches for this is the only thing that would notice.
