# Node-side provisioning helper.
#
# The guests are created from the same inventory the NixOS configurations are
# built from. Writing the creation commands by hand would introduce a second
# place where a VMID, a storage identifier or a start order can be wrong, and
# the two would disagree without either of them failing.
#
# The script is meant to run on the Proxmox node. It is generated here so that
# it cannot drift from the declaration.
#
# What it produces is a machine that can be installed onto, not a virtual
# machine that exists. The two are not the same thing, and the difference is
# where a procedure stops being reproducible: nixos-anywhere connects over SSH
# to a Linux already running on the target, and a guest with empty volumes and
# no media has nothing to answer with. So `create` also attaches the image
# this flake builds, starts the guest, and waits for it — the image carries
# the administrative keys and recognises each guest by the hardware address
# the inventory assigns it, which is why that address is declared rather than
# left to Proxmox.
#
# Three further properties matter as much as the commands themselves, and all
# three exist because the node holds state the flake cannot see:
#
#   * `create` refuses to start until the node matches what the inventory
#     assumes: the pools it names, the bridge it attaches to, the capacity it
#     was sized against. A storage identifier the node does not know is not a
#     defect of the guest that first refers to it — it stops that guest and
#     every guest after it, in the middle of a run that has already written.
#
#   * `create` is resumable. A guest that already exists is left untouched,
#     so a run interrupted halfway is finished by running it again rather
#     than by destroying what it managed to create. Re-issuing `qm set` for
#     an existing volume would allocate a second one and orphan the first.
#
#   * What already exists is verified rather than assumed. Skipping an
#     existing guest is only safe if something checks that it is the guest
#     the inventory describes, so `verify` compares each one field by field —
#     otherwise a guest created by hand, or by an earlier version of these
#     parameters, is silently accepted as correct for the rest of the
#     installation.
#
# The environment checks the README lists under F-01 are made here as well,
# and that is deliberate. A measurement carried by hand into a parameter is
# true when it is taken; these are the assertions that keep it true at the
# moment the node is written to.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;

  activeRoles = lib.filter
    (role: cfg.guests.${role}.aliasOf == null)
    (builtins.attrNames cfg.guests);

  byBootOrder = lib.sort
    (a: b: cfg.guests.${a}.bootOrder < cfg.guests.${b}.bootOrder)
    activeRoles;

  vlanOf = zone: toString cfg.network.zones.${zone}.vlanId;

  # Every volume the inventory declares, root and additional alike, so that
  # what a pool is asked to hold can be compared with what it has.
  volumes = lib.concatMap
    (role:
      let guest = cfg.guests.${role}; in
      [{ inherit (guest) storage; sizeGb = guest.diskGb; }]
      ++ map (disk: { inherit (disk) storage sizeGb; }) guest.extraDisks)
    byBootOrder;

  storageIds = lib.unique (map (volume: volume.storage) volumes);

  spaceOn = store: lib.foldl'
    (total: volume: total + (if volume.storage == store then volume.sizeGb else 0))
    0
    volumes;

  # Every pool the inventory refers to, paired with the format the volume is
  # created in. The root volume carries an explicit format; the additional
  # ones take the default of their pool, and are checked for existence only —
  # hence the '-'.
  storageChecks = lib.concatMapStrings
    (role:
      let
        guest = cfg.guests.${role};
        who = "${toString guest.vmid} ${guest.hostName}";
      in
      ''
        check_storage ${guest.storage} ${guest.diskFormat} "${who}, root volume"
      ''
      + lib.concatMapStrings
        (disk: ''
          check_storage ${disk.storage} - "${who}, volume on ${disk.mountPoint}"
        '')
        guest.extraDisks)
    byBootOrder;

  # The pool of the memory guest is held to the stronger rule: the design
  # rests on it being a device of its own, and a directory pool whose device
  # is not mounted is indistinguishable from one that is until the disk it
  # was meant to keep off fills up.
  poolChecks = lib.concatMapStrings
    (store: ''
      check_pool ${store} ${if store == cfg.site.storage.memory then "1" else "0"}
      check_space ${store} ${toString (spaceOn store)}
    '')
    storageIds;

  vmidChecks = lib.concatMapStrings
    (role: ''
      check_vmid ${toString cfg.guests.${role}.vmid} ${cfg.guests.${role}.hostName}
    '')
    byBootOrder;

  # What the node was sized against, in the two units the sizing is written
  # in. Memory is the binding constraint of this deployment and the figure is
  # meaningless without the one the node reports at the time of provisioning.
  totalCores = lib.foldl' (n: role: n + cfg.guests.${role}.cores) 0 byBootOrder;
  maxGuestCores = lib.foldl' (n: role: lib.max n cfg.guests.${role}.cores) 0 byBootOrder;
  totalMemoryMb = lib.foldl' (n: role: n + cfg.guests.${role}.memoryMb) 0 byBootOrder;

  createGuest = role:
    let
      guest = cfg.guests.${role};
      id = toString guest.vmid;
    in
    ''

      # --- ${guest.hostName}: VMID ${id}, start order ${toString guest.bootOrder} ---
      if vm_exists ${id}; then
        echo "${id} ${guest.hostName}: already present, left untouched."
      else
        create_guest \
          ${id} ${guest.hostName} ${toString guest.cores} \
          ${toString guest.memoryMb} ${toString guest.diskGb} \
          ${vlanOf guest.zone} ${toString guest.bootOrder} \
          ${guest.storage} ${guest.diskFormat} ${toString guest.bootDelay} \
          ${guest.macAddress}
    ''
    # Indexed from one, because net0 is the primary interface created above.
    # The index is not decoration: common.nix names the additional interfaces
    # eth1, eth2 and so on in the order they are declared, and addresses them
    # in that order. Attaching them all to net1 would leave every interface
    # after the first configured on a guest and absent from the machine.
    + lib.concatStrings (lib.imap1
      (index: interface: ''

        # Interface ${toString index}, in the ${interface.zone} zone. Only the
        # dual-homed guest has one, and the flows towards the downstream
        # services are admitted from this interface alone.
        qm set ${id} --net${toString index} \
          "virtio,bridge=${cfg.network.bridge},tag=${vlanOf interface.zone},firewall=1"
      '')
      guest.extraInterfaces)
    + lib.optionalString (guest.cpuLimit != null) ''

      # CPU ceiling: keeps a delegation fan-out from saturating the node.
      qm set ${id} --cpulimit ${toString guest.cpuLimit}
    ''
    # Indexed from one for the same reason, and against the same counterpart:
    # scsi0 is the root volume, so the additional ones are scsi1 onwards, and
    # the guest enumerates them in that order as sdb, sdc — which is exactly
    # the arithmetic common.nix uses to decide what to mount where. A second
    # volume written to scsi1 would replace the first in the machine
    # definition, and the mount it was declared for would land on the root
    # filesystem it exists to keep off.
    + lib.concatStrings (lib.imap1
      (index: disk: ''

        # Additional volume mounted on ${disk.mountPoint}. Without it the
        # observability backends write to the root filesystem of this guest,
        # and when that fills up what is lost is not observability.
        qm set ${id} --scsi${toString index} \
          "${disk.storage}:${toString disk.sizeGb},iothread=1,discard=on,ssd=1"
      '')
      guest.extraDisks)
    + ''

        echo "${id} ${guest.hostName}: created."
        CREATED+=(${id})
      fi
    '';

  # Attaching the image and starting the guest is part of creating it: a guest
  # that exists and has never booted is not a machine anybody can install
  # onto, and every step that would make it one by hand — the media, the boot
  # order, an address typed into a console — is a place where the node stops
  # matching the declaration.
  bootstrapGuest = role:
    let
      guest = cfg.guests.${role};
      id = toString guest.vmid;
    in
    ''
      if vm_exists ${id}; then
        bootstrap_guest ${id} ${guest.hostName} ${guest.address}
      else
        problem "${id} ${guest.hostName} does not exist: run create first."
      fi
    '';

  bootstrapCreated = role:
    let
      guest = cfg.guests.${role};
      id = toString guest.vmid;
    in
    ''
      if was_created ${id}; then
        bootstrap_guest ${id} ${guest.hostName} ${guest.address}
      fi
    '';

  installGuest = role:
    let
      guest = cfg.guests.${role};
    in
    ''
      install_guest ${toString guest.vmid} ${guest.hostName} ${guest.address}
    '';

  credentialCheck = role:
    ''
      check_credentials ${cfg.guests.${role}.hostName}
    '';

  # The counterpart of createGuest: every field it sets, read back and
  # compared. The comparison is written against what qm config reports rather
  # than against the command line that produced it — Proxmox normalises both
  # the volume identifiers and the numbers, so an equality test on the
  # arguments would report differences that are not there.
  verifyGuest = role:
    let
      guest = cfg.guests.${role};
      id = toString guest.vmid;
      who = "${id} ${guest.hostName}";
    in
    ''

      # --- ${guest.hostName} ---
      if vm_exists ${id}; then
        load_guest ${id}
        expect "${who}" name '${guest.hostName}'
        expect "${who}" cores '${toString guest.cores}'
        expect "${who}" memory '${toString guest.memoryMb}'
        expect "${who}" balloon '0'
        expect "${who}" onboot '1'
        expect "${who}" protection '1'
        expect "${who}" startup 'order=${toString guest.bootOrder},up=${toString guest.bootDelay}'
        expect_agent "${who}"
        expect_field "${who}" net0 bridge '${cfg.network.bridge}'
        expect_field "${who}" net0 tag '${vlanOf guest.zone}'
        expect_field "${who}" net0 firewall '1'
        expect_field "${who}" net0 virtio '${guest.macAddress}'
        expect_volume "${who}" scsi0 '${guest.storage}' '${toString guest.diskGb}' '${guest.diskFormat}'
    ''
    + lib.concatStrings (lib.imap1
      (index: interface: ''
        expect_field "${who}" net${toString index} bridge '${cfg.network.bridge}'
        expect_field "${who}" net${toString index} tag '${vlanOf interface.zone}'
      '')
      guest.extraInterfaces)
    + lib.optionalString (guest.cpuLimit != null) ''
      expect_number "${who}" cpulimit '${toString guest.cpuLimit}'
    ''
    + lib.concatStrings (lib.imap1
      (index: disk: ''
        expect_volume "${who}" scsi${toString index} '${disk.storage}' '${toString disk.sizeGb}' '-'
      '')
      guest.extraDisks)
    + ''
      else
        note "${who}: not created."
      fi
    '';

  provisionScript = pkgs.writeShellApplication {
    name = "hermes-provision-guests";

    text = ''
      # Guest provisioning for the HERMES-AGENT platform.
      #
      # Run on the Proxmox node. The start order is not a procedural note, it
      # is a property of each virtual machine: secrets, then memory, then the
      # agentic plane, then the ingress. A service started before the secret
      # store does not find its credentials and fails in a way that is not
      # always evident.

      usage() {
        cat <<'USAGE'
      Usage:
        hermes-provision-guests preflight         check the node, create nothing
        hermes-provision-guests create            create the guests, boot the installer on them
        hermes-provision-guests bootstrap         boot the installer on guests that exist
        hermes-provision-guests install           run nixos-anywhere over every guest, in order
        hermes-provision-guests eject             remove the installation media after installing
        hermes-provision-guests verify            compare the guests with the inventory
        hermes-provision-guests fsync             measure the fsync rate of the memory pool
        hermes-provision-guests snapshot <label>  snapshot every guest
        hermes-provision-guests status            list the guests and their start order

      create runs preflight first and stops on its findings, before the node
      has been written to. Guests that already exist are left untouched and
      compared with the inventory instead, so an interrupted run is finished
      by running create again. Each guest it creates is then started on the
      installation image built by this flake and waited for, so that what
      create leaves behind is a machine that answers on its declared address.

      install runs from the repository, which is where the flake it deploys
      is: nixos-anywhere is not part of this script, and it is expected on
      PATH — `nix shell github:nix-community/nixos-anywhere -c ...`.

      fsync is separate because it writes to the pool and takes seconds; the
      rest read the node and nothing else.
      USAGE
      }

      VMIDS=(${lib.concatMapStringsSep " " (role: toString cfg.guests.${role}.vmid) byBootOrder})

      BRIDGE="${cfg.network.bridge}"
      MEMORY_POOL="${cfg.site.storage.memory}"
      ISO_POOL="${cfg.site.storage.iso}"
      INSTALLER_VOLUME="${cfg.site.storage.iso}:iso/${cfg.site.installerImage}"
      INSTALLER_IMAGE="${cfg.site.installerImage}"

      # How long a guest is given to boot the image and answer on port 22.
      # Generous on purpose: it is measured from a cold start of a machine
      # that decompresses its whole root filesystem into memory first.
      SSH_TIMEOUT=300

      # The flake install deploys, which is the repository this script was
      # built from and not the store path it lives in.
      FLAKE="''${FLAKE:-.}"

      # VMIDs created by this run. Only these are booted on the installation
      # image: a guest that already existed may be installed, and starting it
      # on the installer is not what 'create' was asked to do.
      CREATED=()
      BACKUP_TARGET="${cfg.site.backupTarget}"
      BACKUP_MOUNT="${cfg.site.backupMountPoint}"
      FSYNC_MINIMUM=${toString cfg.site.storage.fsyncMinimum}
      TOTAL_CORES=${toString totalCores}
      MAX_GUEST_CORES=${toString maxGuestCores}
      TOTAL_MEMORY_MB=${toString totalMemoryMb}

      PROBLEMS=0
      DRIFT=0

      # A problem stops the run: the node does not admit what the inventory
      # declares, and going on writes something other than what was declared.
      # A warning does not: it is a statement about the node that the operator
      # is the one placed to judge, and stopping on it would make the tool the
      # authority on a decision that is not its own.
      problem() {
        printf 'error:   %s\n' "$1" >&2
        PROBLEMS=$((PROBLEMS + 1))
      }

      warn() {
        printf 'warning: %s\n' "$1" >&2
      }

      note() {
        printf '         %s\n' "$1" >&2
      }

      drift() {
        printf 'drift:   %s\n' "$1" >&2
        DRIFT=$((DRIFT + 1))
      }

      # --- What the node actually holds -----------------------------------
      #
      # Read once. Both lists are needed: a pool can be declared and still be
      # refused by qm create, either because it is not online or because it
      # does not carry content=images, and the refusal is worded the same way
      # in every case.
      STORAGE_ALL=""
      STORAGE_IMAGES=""
      STORAGE_ISO=""

      # Pools already examined. A pool carries several volumes, and reporting
      # one absent pool once per volume it was going to hold turns a single
      # defect into a list, which is how the one line that has to change stops
      # being visible.
      STORAGE_SEEN=""

      NODE_READ=0

      read_node() {
        if [ "$NODE_READ" -eq 1 ]; then
          return 0
        fi

        if ! command -v qm >/dev/null 2>&1 || ! command -v pvesm >/dev/null 2>&1; then
          echo "qm and pvesm are not on PATH: this command runs on the Proxmox node." >&2
          exit 2
        fi

        STORAGE_ALL=$(pvesm status 2>/dev/null | awk 'NR > 1 { print $1 "\t" $2 "\t" $3 "\t" $6 }')
        STORAGE_IMAGES=$(pvesm status --content images 2>/dev/null | awk 'NR > 1 { print $1 }')
        STORAGE_ISO=$(pvesm status --content iso 2>/dev/null | awk 'NR > 1 { print $1 }')
        NODE_READ=1
      }

      storage_field() {
        printf '%s\n' "$STORAGE_ALL" | awk -F '\t' -v name="$1" -v col="$2" '$1 == name { print $col }'
      }

      # A property as declared, which is not the same question as what pvesm
      # reports: the path of a pool and whether it is required to be a mount
      # point exist only in the configuration file.
      # Absent or unreadable, the file yields nothing rather than a status:
      # every caller treats an unset property as unset, and an assignment that
      # carried awk's exit status would end the run with no message at all.
      storage_option() {
        awk -v want="$1" -v key="$2" '
          /^[a-z]+: / { section = $2; next }
          section == want && $1 == key { $1 = ""; sub(/^[ \t]+/, ""); print; exit }
        ' /etc/pve/storage.cfg 2>/dev/null || true
      }

      vm_exists() {
        qm config "$1" >/dev/null 2>&1
      }

      vm_name() {
        qm config "$1" 2>/dev/null | sed -n 's/^name: *//p'
      }

      # The configuration of the guest being verified, read once. Reading it
      # per field would run qm a dozen times per guest and, worse, would
      # compare fields that were not read at the same moment: a guest edited
      # between two of the reads would be reported as consistent with neither
      # state.
      GUEST_CONF=""

      load_guest() {
        GUEST_CONF=$(qm config "$1" 2>/dev/null || true)
      }

      cfg_value() {
        printf '%s\n' "$GUEST_CONF" |
          awk -v key="$1:" '$1 == key { sub(/^[^ ]+ +/, ""); print; exit }'
      }

      check_storage() {
        local store="$1" fmt="$2" what="$3"
        local type status seen=0

        case "$STORAGE_SEEN" in
          *" $store "*) seen=1 ;;
          *) STORAGE_SEEN="$STORAGE_SEEN $store " ;;
        esac

        type=$(storage_field "$store" 2)
        status=$(storage_field "$store" 3)

        # The pool itself is reported on the first volume that needs it; the
        # format is a property of the volume and is checked for each one.
        if [ -z "$type" ]; then
          if [ "$seen" -eq 1 ]; then
            return 0
          fi
          problem "storage '$store' is not declared on this node — needed by $what."
          note "Declare it, or rename the pool that was meant to carry it, in"
          note "/etc/pve/storage.cfg. Do it now: renaming a pool costs one line"
          note "while no volume refers to it, and every reference in the flake"
          note "and in every qm command afterwards."
          note "    pvesm status                  # what the node has today"
          note "    pvesm add dir $store --path <path> --content images"
          return 0
        fi

        if [ "$status" != "active" ]; then
          if [ "$seen" -eq 1 ]; then
            return 0
          fi
          problem "storage '$store' is declared but $status — needed by $what."
          note "An inactive pool is refused by qm create in the same words as a"
          note "pool that does not exist. Bring it online before provisioning."
          return 0
        fi

        if ! printf '%s\n' "$STORAGE_IMAGES" | grep -qx "$store"; then
          if [ "$seen" -eq 1 ]; then
            return 0
          fi
          problem "storage '$store' does not accept disk images — needed by $what."
          note "    pvesm set $store --content images,<the contents it already carries>"
          return 0
        fi

        case "$fmt" in
          qcow2)
            case "$type" in
              dir | nfs | cifs | glusterfs | btrfs) ;;
              *)
                problem "storage '$store' is $type and holds raw volumes only, but $what is declared qcow2."
                note "Either move the volume to a directory-backed pool or set"
                note "diskFormat = \"raw\" for it, accepting that the per-phase"
                note "snapshots go with it."
                ;;
            esac
            ;;
          raw)
            case "$type" in
              dir | nfs | cifs | glusterfs)
                note "$what is raw on the $type pool '$store': the per-phase"
                note "snapshots are unavailable there, and the installation"
                note "procedure loses its rollback points. qcow2 restores them."
                ;;
              *) ;;
            esac
            ;;
          *) ;;
        esac
      }

      # Where a directory-backed pool actually writes. The identifier says
      # nothing about the device: a pool whose filesystem is not mounted is a
      # directory on the root filesystem, it accepts every write, and the
      # separation the sizing rests on is gone without a single error being
      # reported. The memory guest is held to it strictly — a vector index
      # sharing a spindle with everything else produces a retrieval failure
      # that gets blamed on the memory backend.
      check_pool() {
        local store="$1" strict="$2"
        local path source root_source

        path=$(storage_option "$store" path)
        if [ -z "$path" ]; then
          return 0
        fi

        if [ ! -d "$path" ]; then
          problem "storage '$store' points at $path, which is not a directory on this node."
          return 0
        fi

        if ! command -v findmnt >/dev/null 2>&1; then
          return 0
        fi

        source=$(findmnt -n -o SOURCE --target "$path" 2>/dev/null || true)
        root_source=$(findmnt -n -o SOURCE --target / 2>/dev/null || true)

        if [ -n "$source" ] && [ "$source" = "$root_source" ]; then
          if [ "$strict" = "1" ]; then
            problem "storage '$store' resolves to $source, which is the root filesystem."
            note "$path is not a mount point, so its device is either absent or"
            note "not mounted. This pool is declared as a device of its own, and"
            note "everything written to it now lands on the node's root disk."
          else
            warn "storage '$store' resolves to $source, the root filesystem."
          fi
          return 0
        fi

        # Mounted today is not the same as mounted after a reboot. Without
        # is_mountpoint, Proxmox recreates the directory on whatever is
        # underneath and carries on writing there.
        if [ "$(storage_option "$store" is_mountpoint)" != "1" ]; then
          warn "storage '$store' is on $source but is not declared is_mountpoint."
          note "After a boot where that device does not come up, Proxmox writes"
          note "to $path on the root filesystem instead, and reports nothing."
          note "    pvesm set $store --is_mountpoint 1"
        fi
      }

      check_space() {
        local store="$1" want_gb="$2"
        local available_kb want_kb

        available_kb=$(storage_field "$store" 4)
        if [ -z "$available_kb" ]; then
          return 0
        fi

        want_kb=$((want_gb * 1024 * 1024))
        if [ "$available_kb" -lt "$want_kb" ]; then
          warn "storage '$store' has $((available_kb / 1048576)) GiB free and the inventory declares $want_gb GiB on it."
          note "Thin pools accept the allocation and fail later, when the"
          note "volumes are written rather than when they are created."
        fi
      }

      check_vmid() {
        local id="$1" name="$2" existing

        if pct config "$id" >/dev/null 2>&1; then
          problem "VMID $id is already taken by a container, and $name needs it."
          return 0
        fi

        if ! vm_exists "$id"; then
          return 0
        fi

        existing=$(vm_name "$id")
        if [ "$existing" = "$name" ]; then
          note "$id $name already exists: create will leave it untouched."
        else
          problem "VMID $id exists on this node as '$existing', not '$name'."
          note "Nothing is written to a guest this inventory did not create."
        fi
      }

      # qm create accepts a bridge that is not there. The guest is created,
      # it starts, and it comes up with an interface attached to nothing —
      # which is diagnosed as a guest network problem, one layer above where
      # it actually is.
      check_bridge() {
        local filtering

        if [ ! -d "/sys/class/net/$BRIDGE" ]; then
          problem "bridge '$BRIDGE' does not exist on this node."
          note "It is not validated by qm create: the guests would be created"
          note "attached to a bridge that is not there."
          return 0
        fi

        filtering="/sys/class/net/$BRIDGE/bridge/vlan_filtering"
        if [ ! -e "$filtering" ]; then
          warn "'$BRIDGE' is not a Linux bridge, or exposes no VLAN filtering flag."
          return 0
        fi

        if [ "$(cat "$filtering")" != "1" ]; then
          warn "VLAN filtering is off on '$BRIDGE'."
          note "The three zones of this design are separated by VLAN tags on"
          note "this bridge. Without filtering the tags are carried by the"
          note "traditional per-VLAN interfaces, if they exist at all, and the"
          note "segmentation stops being a property of the bridge."
          note "    cat /sys/class/net/$BRIDGE/bridge/vlan_filtering   # expected: 1"
        fi
      }

      # The two figures the sizing was taken against. Proxmox refuses to start
      # a guest with more virtual CPUs than the node has, and memory is the
      # binding constraint of this deployment: neither is visible from the
      # flake, and both change under the operator's feet.
      check_capacity() {
        local cpus available_mb

        cpus=$(nproc)
        if [ "$MAX_GUEST_CORES" -gt "$cpus" ]; then
          problem "a guest is declared with $MAX_GUEST_CORES cores and the node has $cpus."
          note "Proxmox refuses to start a guest whose virtual CPU count"
          note "exceeds the CPUs of the node. It is created and never boots."
        fi

        available_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
        if [ -z "$available_mb" ]; then
          return 0
        fi

        if [ "$TOTAL_MEMORY_MB" -gt "$available_mb" ]; then
          warn "the guests are assigned $TOTAL_MEMORY_MB MB and the node has $available_mb MB available."
          note "Ballooning is disabled by design, so the assignment is fixed:"
          note "the guests cannot give any of it back under pressure."
        else
          note "capacity: $TOTAL_CORES vCPU on $cpus, $TOTAL_MEMORY_MB MB of $available_mb MB available, $((available_mb - TOTAL_MEMORY_MB)) MB left to the host."
        fi
      }

      # Not needed to create a guest, and reported rather than enforced for
      # that reason. It is the first of the three checks the backup phase
      # rests on, and it is cheaper to learn now than at the phase that
      # depends on it.
      check_backup_target() {
        if [ -z "$(storage_field "$BACKUP_TARGET" 2)" ]; then
          warn "backup target '$BACKUP_TARGET' is not declared on this node."
          return 0
        fi

        if [ "$(storage_field "$BACKUP_TARGET" 3)" != "active" ]; then
          warn "backup target '$BACKUP_TARGET' is declared but not active."
          return 0
        fi

        case ",$(storage_option "$BACKUP_TARGET" content)," in
          *,backup,*) ;;
          *) warn "backup target '$BACKUP_TARGET' does not carry content=backup." ;;
        esac

        if [ ! -d "$BACKUP_MOUNT" ]; then
          warn "the backup mount point $BACKUP_MOUNT does not exist on this node."
          note "The identifier of a pool and the path it is mounted on are two"
          note "different things, and with NFS the two diverge."
        fi
      }

      # The image is checked here and not where it is attached, because create
      # boots the guests it creates: without it, create would allocate every
      # volume and stop at the first guest it cannot start, which is the
      # failure mode this gate exists to remove.
      check_installer() {
        local path

        if [ -z "$(storage_field "$ISO_POOL" 2)" ]; then
          problem "iso pool '$ISO_POOL' is not declared on this node."
          return 0
        fi

        if ! printf '%s\n' "$STORAGE_ISO" | grep -qx "$ISO_POOL"; then
          problem "pool '$ISO_POOL' does not accept content of type iso."
          note "    pvesm set $ISO_POOL --content iso,<the contents it already carries>"
          return 0
        fi

        path=$(pvesm path "$INSTALLER_VOLUME" 2>/dev/null || true)
        if [ -z "$path" ]; then
          problem "'$INSTALLER_VOLUME' has no path on this node."
          return 0
        fi

        if [ ! -f "$path" ]; then
          problem "the installation image is not on the node: $INSTALLER_VOLUME"
          note "It is built from this flake, and it carries the administrative"
          note "keys and the address of every guest: a guest that boots it"
          note "comes up reachable, with nothing typed into a console. From"
          note "the repository, on this node:"
          note "    nix build .#installer-iso"
          note "    install -m 0644 result/iso/$INSTALLER_IMAGE $path"
        fi
      }

      cmd_preflight() {
        read_node
        PROBLEMS=0
        STORAGE_SEEN=""

        ${storageChecks}
        ${poolChecks}
        ${vmidChecks}
        check_bridge
        check_capacity
        check_installer
        check_backup_target

        if [ "$PROBLEMS" -gt 0 ]; then
          local word="problems"
          if [ "$PROBLEMS" -eq 1 ]; then
            word="problem"
          fi
          printf '\n%s %s on the node. Nothing was created.\n' "$PROBLEMS" "$word" >&2
          return 1
        fi

        echo "Preflight: the node admits every pool, bridge and VMID the inventory names."
      }

      # --- Reading a guest back -------------------------------------------
      expect() {
        local who="$1" key="$2" want="$3" have
        have=$(cfg_value "$key")
        if [ "$have" != "$want" ]; then
          drift "$who: $key is '$have' on the node, '$want' is declared."
        fi
      }

      # Proxmox prints what it stores, and it stores numbers in a form of its
      # own: a limit set as 3.500000 comes back as 3.5. Comparing the two as
      # strings reports a difference that does not exist, and printing the
      # declared value unrounded reports a real one in a form nobody wrote.
      expect_number() {
        local who="$1" key="$2" want="$3" have shown
        have=$(cfg_value "$key")
        if ! awk -v a="$have" -v b="$want" 'BEGIN { exit !(a + 0 == b + 0) }'; then
          shown=$(awk -v b="$want" 'BEGIN { printf "%g", b + 0 }')
          drift "$who: $key is '$have' on the node, '$shown' is declared."
        fi
      }

      # enabled=1 is stored either as itself or as a bare 1, depending on the
      # version. Both mean the agent is enabled, which is what is declared.
      expect_agent() {
        local who="$1" have
        have=$(cfg_value agent)
        case "$have" in
          1 | 1,* | enabled=1 | enabled=1,*) ;;
          *) drift "$who: agent is '$have' on the node, enabled is declared." ;;
        esac
      }

      expect_field() {
        local who="$1" key="$2" field="$3" want="$4" have
        have=$(cfg_value "$key" | tr ',' '\n' | sed -n "s/^$field=//p")
        if [ "$have" != "$want" ]; then
          drift "$who: $key $field is '$have' on the node, '$want' is declared."
        fi
      }

      # The volume identifier is assigned by Proxmox and carries no
      # information the inventory could predict — what it does carry is the
      # pool it was allocated on, the size, and, on a directory pool, the
      # format as the extension of the file.
      expect_volume() {
        local who="$1" key="$2" store="$3" size="$4" fmt="$5"
        local line volume have_store have_size

        line=$(cfg_value "$key")
        if [ -z "$line" ]; then
          drift "$who: $key is absent on the node, a ''${size}G volume on '$store' is declared."
          return 0
        fi

        volume="''${line%%,*}"
        have_store="''${volume%%:*}"
        have_size=$(printf '%s' "$line" | tr ',' '\n' | sed -n 's/^size=//p')

        if [ "$have_store" != "$store" ]; then
          drift "$who: $key is on '$have_store', '$store' is declared."
        fi

        if [ "$have_size" != "''${size}G" ]; then
          drift "$who: $key is $have_size on the node, ''${size}G is declared."
        fi

        if [ "$fmt" = "qcow2" ]; then
          case "$volume" in
            *.qcow2) ;;
            *) drift "$who: $key is '$volume', which is not a qcow2 volume." ;;
          esac
        fi
      }

      cmd_verify() {
        read_node
        DRIFT=0

        ${lib.concatStringsSep "\n" (map verifyGuest byBootOrder)}

        if [ "$DRIFT" -gt 0 ]; then
          local word="differences"
          if [ "$DRIFT" -eq 1 ]; then
            word="difference"
          fi
          printf '\n%s %s between the node and the inventory.\n' "$DRIFT" "$word" >&2
          echo "A guest is not corrected in place: qm set what belongs to a" >&2
          echo "stopped guest, or destroy it and let create build it again." >&2
          return 1
        fi

        echo "Verify: every guest on the node matches the inventory."
      }

      create_guest() {
        local id="$1" name="$2" cores="$3" ram="$4" disk="$5"
        local vlan="$6" order="$7" store="$8" fmt="$9" delay="''${10}"
        local mac="''${11}"

        qm create "$id" \
          --name "$name" --ostype l26 --cpu host \
          --cores "$cores" --memory "$ram" --balloon 0 \
          --numa ${if cfg.site.numa then "1" else "0"} \
          --scsihw virtio-scsi-single \
          --scsi0 "''${store}:''${disk},iothread=1,discard=on,ssd=1,format=''${fmt}" \
          --net0 "virtio=''${mac},bridge=${cfg.network.bridge},tag=''${vlan},firewall=1" \
          --onboot 1 --startup "order=''${order},up=''${delay}" \
          --agent enabled=1 --protection 1
      }

      was_created() {
        local id="$1" created
        for created in ''${CREATED[@]+"''${CREATED[@]}"}; do
          if [ "$created" = "$id" ]; then
            return 0
          fi
        done
        return 1
      }

      # --- Bringing a guest up on the installation image -------------------
      #
      # nixos-anywhere does not create a machine and does not boot one: it
      # connects over SSH to a Linux already running on the target. This is
      # what puts that Linux there, from the image this flake builds, so that
      # the sequence needs no console — the image carries the administrative
      # keys and recognises each guest by the hardware address the inventory
      # assigns it.
      bootstrap_guest() {
        local id="$1" host="$2" address="$3"

        load_guest "$id"

        if [ "$(cfg_value ide2)" != "$INSTALLER_VOLUME,media=cdrom" ]; then
          qm set "$id" --ide2 "$INSTALLER_VOLUME,media=cdrom"
        fi

        # Disk first, image second. An uninstalled volume carries no boot
        # signature and the firmware falls through to the image; once
        # nixos-anywhere has written a bootloader, the same order boots the
        # installed system — including at the reboot that ends the
        # installation, which the reverse order would send back to the
        # installer for as long as the media stayed attached.
        if [ "$(cfg_value boot)" != "order=scsi0;ide2" ]; then
          qm set "$id" --boot 'order=scsi0;ide2'
        fi

        if [ "$(qm status "$id" | awk '{ print $2 }')" != "running" ]; then
          qm start "$id"
        fi

        wait_for_ssh "$id" "$host" "$address"
      }

      wait_for_ssh() {
        local id="$1" host="$2" address="$3" waited=0

        printf '%s %s: waiting for ssh on %s ' "$id" "$host" "$address"

        while [ "$waited" -lt "$SSH_TIMEOUT" ]; do
          if (exec 3<>"/dev/tcp/$address/22") 2>/dev/null; then
            printf ' answered after %ss.\n' "$waited"
            return 0
          fi
          sleep 5
          waited=$((waited + 5))
          printf '.'
        done

        printf '\n'
        problem "$id $host did not answer on $address:22 within ''${SSH_TIMEOUT}s."
        note "The guest is started and the media is attached, so what is left"
        note "is what the console shows: it boots the image, or it does not."
        note "    qm status $id                 # running?"
        note "    qm config $id | grep -E 'ide2|boot|net0'"
        note "The image configures a guest by the hardware address of net0. If"
        note "that address is not the declared one — 'verify' reports it — the"
        note "guest boots with no address at all."
        note "A guest stopped at 'no bootable device' did not fall through from"
        note "its empty disk to the image, and can be sent to it directly:"
        note "    qm set $id --boot 'order=ide2;scsi0'"
        note "That order boots the installer again after the installation, so"
        note "put it back — or run eject — once the guest is installed."
      }

      cmd_bootstrap() {
        read_node
        PROBLEMS=0

        ${lib.concatStrings (map bootstrapGuest byBootOrder)}

        if [ "$PROBLEMS" -gt 0 ]; then
          return 1
        fi

        echo "Every guest answers on port 22 at its declared address."
      }

      cmd_create() {
        # The gate is the point: a node that does not admit what the inventory
        # declares stops the run here, with nothing allocated, rather than
        # after the guests before it in the start order have been written.
        cmd_preflight
        echo
        ${lib.concatStringsSep "\n" (map createGuest byBootOrder)}

        # What was skipped is not what was verified. A guest left untouched
        # because it exists is compared against the declaration here, so that
        # 'already present' is a statement about its contents and not only
        # about its VMID.
        echo
        cmd_verify || true

        # Only what this run created. A guest that was already there may be
        # installed and running its own system, and starting it on an
        # installation image is not a step create was asked to take.
        if [ "''${#CREATED[@]}" -gt 0 ]; then
          echo
          PROBLEMS=0
          ${lib.concatStrings (map bootstrapCreated byBootOrder)}
        fi

        qm list

        if [ "$PROBLEMS" -gt 0 ]; then
          return 1
        fi
      }

      install_guest() {
        local id="$1" host="$2" address="$3"

        if ! vm_exists "$id"; then
          echo "$id $host does not exist. Run create first." >&2
          exit 1
        fi

        echo
        echo "=== $id $host: $FLAKE#$host onto $address ==="

        # The host key of the image is generated at every boot, and the guest
        # it belongs to has no identity yet: recording it would be recording
        # the identity of the installer, which the installation then replaces.
        # The identity that matters is registered afterwards, from the
        # installed system, and that is the one the credentials are encrypted
        # to.
        nixos-anywhere \
          --flake "$FLAKE#$host" \
          --ssh-option StrictHostKeyChecking=no \
          --ssh-option UserKnownHostsFile=/dev/null \
          "root@$address"
      }

      # The bootstrap credential is read while a guest's configuration is
      # evaluated, not while it is activated. An empty or unencrypted file
      # therefore fails at the end of an installation — when sops-install-
      # secrets builds the manifest, after the guest has been reached, its
      # facts gathered and its closure built — and it fails once per guest,
      # in start order, for as long as it takes to notice that the same thing
      # is wrong with all four.
      CREDENTIALS_EXPLAINED=0

      check_credentials() {
        local host="$1"
        local file="$FLAKE/secrets/$host.yaml"

        if [ ! -s "$file" ]; then
          problem "secrets/$host.yaml is empty or absent."
          # Said once. The four files are written in one sitting and are
          # empty for one reason, and four copies of the explanation bury
          # the four names that matter.
          if [ "$CREDENTIALS_EXPLAINED" -eq 0 ]; then
            note "One file per guest holds the credential it proves its identity"
            note "with, and the configuration does not evaluate without it. The"
            note "shape is in secrets/README.md; the values are issued in F-03,"
            note "so the file is created before them and filled after."
            CREDENTIALS_EXPLAINED=1
          fi
          return 0
        fi

        # sops leaves its own metadata block in a file it has encrypted. A
        # file without it is either plain text — a credential in the clear,
        # about to be copied into the store — or not a sops file at all.
        if ! grep -q '^sops:' "$file"; then
          problem "secrets/$host.yaml is not encrypted."
          note "    sops --config /dev/null --age \"\$ADMIN\" --encrypt --in-place secrets/$host.yaml"
          return 0
        fi
      }

      # In start order, and stopping at the first failure: a guest installed
      # before the secret store is a guest whose services start without their
      # credentials.
      cmd_install() {
        read_node

        if ! command -v nixos-anywhere >/dev/null 2>&1; then
          echo "nixos-anywhere is not on PATH. It is not part of this script:" >&2
          echo "  nix shell github:nix-community/nixos-anywhere \\" >&2
          echo "    -c nix run .#provision-guests -- install" >&2
          exit 2
        fi

        if [ ! -e "$FLAKE/flake.nix" ] && [ "''${FLAKE#*:}" = "$FLAKE" ]; then
          echo "No flake at '$FLAKE'. Run this from the repository, or set" >&2
          echo "FLAKE to where it is." >&2
          exit 2
        fi

        # Every guest's credential file, before the first guest is touched.
        # Checked here rather than one at a time because they are written in
        # one sitting and are wrong in the same way.
        if [ -d "$FLAKE/secrets" ]; then
          PROBLEMS=0
          ${lib.concatStrings (map credentialCheck byBootOrder)}
          if [ "$PROBLEMS" -gt 0 ]; then
            return 1
          fi
        fi

        ${lib.concatStrings (map installGuest byBootOrder)}

        echo
        echo "Installed. Register the host keys before the guests are expected"
        echo "to decrypt anything: the credentials are still encrypted to the"
        echo "operator alone."
      }

      # After the installation, and not before: while the guest boots from its
      # own disk the media costs nothing, and it is the way back if the
      # installation has to be repeated.
      cmd_eject() {
        read_node

        local id protection

        for id in "''${VMIDS[@]}"; do
          if ! vm_exists "$id"; then
            continue
          fi

          load_guest "$id"

          if [ -z "$(cfg_value ide2)" ]; then
            echo "$id: no installation media attached."
            continue
          fi

          # Protection refuses the removal of a drive, which is what it is
          # for. It is cleared for the length of the removal and restored,
          # because a guest left unprotected is a guest one qm destroy away
          # from gone.
          protection=$(cfg_value protection)
          if [ "$protection" = "1" ]; then
            qm set "$id" --protection 0
          fi

          qm set "$id" --delete ide2
          qm set "$id" --boot 'order=scsi0'

          if [ "$protection" = "1" ]; then
            qm set "$id" --protection 1
          fi

          echo "$id: installation media removed, boots from its own disk."
        done
      }

      cmd_fsync() {
        read_node

        local path rate

        if ! command -v pveperf >/dev/null 2>&1; then
          echo "pveperf is not on PATH: this command runs on the Proxmox node." >&2
          exit 2
        fi

        path=$(storage_option "$MEMORY_POOL" path)
        if [ -z "$path" ]; then
          echo "Storage '$MEMORY_POOL' is not directory-backed, and pveperf" >&2
          echo "measures a path. Measure the device it is built on instead." >&2
          exit 2
        fi

        echo "Measuring $path — pveperf writes a temporary file there."
        rate=$(pveperf "$path" | awk -F: '/FSYNCS\/SECOND/ { gsub(/[ \t]/, "", $2); print $2 }')

        if [ -z "$rate" ]; then
          echo "pveperf reported no fsync rate for $path." >&2
          exit 1
        fi

        if [ "''${rate%%.*}" -lt "$FSYNC_MINIMUM" ]; then
          echo "$rate fsync/s on '$MEMORY_POOL', below the declared floor of $FSYNC_MINIMUM." >&2
          echo "Revise the sizing now: below the floor this is diagnosed later" >&2
          echo "as a retrieval failure of the memory backend rather than as a" >&2
          echo "property of the disk underneath it." >&2
          exit 1
        fi

        echo "$rate fsync/s on '$MEMORY_POOL', against a declared floor of $FSYNC_MINIMUM."
      }

      cmd_snapshot() {
        local label="''${1:-}" id missing=""

        if [ -z "$label" ]; then
          echo "A snapshot label is required." >&2
          exit 2
        fi

        for id in "''${VMIDS[@]}"; do
          if ! vm_exists "$id"; then
            missing="$missing $id"
          fi
        done

        # A snapshot of some of the guests is not the rollback point of a
        # phase: the phase that follows is rolled back to a node in a state
        # that never existed.
        if [ -n "$missing" ]; then
          echo "Missing guests:$missing — provisioning is incomplete." >&2
          echo "Run 'hermes-provision-guests create' first; a partial snapshot" >&2
          echo "is not a rollback point for the phase." >&2
          exit 1
        fi

        for id in "''${VMIDS[@]}"; do
          qm snapshot "$id" "$label"
        done
      }

      cmd_status() {
        local id
        for id in "''${VMIDS[@]}"; do
          echo "=== $id ==="
          if vm_exists "$id"; then
            qm config "$id" | grep -E '^(name|startup|memory|cores|scsi[0-9]+):' || true
          else
            echo "not created"
          fi
        done
      }

      case "''${1:-}" in
        preflight) cmd_preflight ;;
        create)    cmd_create ;;
        bootstrap) cmd_bootstrap ;;
        install)   cmd_install ;;
        eject)     cmd_eject ;;
        verify)    cmd_verify ;;
        fsync)     cmd_fsync ;;
        snapshot)  shift; cmd_snapshot "''${1:-}" ;;
        status)    cmd_status ;;
        *)         usage; exit 2 ;;
      esac
    '';
  };
in
{
  config = {
    system.build.pveProvisionScript = provisionScript;
  };
}
