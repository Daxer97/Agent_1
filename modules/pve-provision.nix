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
# Two properties matter as much as the commands themselves, and both exist
# because the node holds state the flake cannot see:
#
#   * `create` refuses to start until every pool the inventory names is
#     present, active and accepting disk images. A storage identifier that
#     the node does not know is not a defect of the guest that first refers
#     to it — it stops that guest and every guest after it, in the middle of
#     a run that has already written to the node.
#
#   * `create` is resumable. A guest that already exists is left untouched,
#     so a run interrupted halfway is finished by running it again rather
#     than by destroying what it managed to create. Re-issuing `qm set` for
#     an existing volume would allocate a second one and orphan the first.

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

  vmidChecks = lib.concatMapStrings
    (role: ''
      check_vmid ${toString cfg.guests.${role}.vmid} ${cfg.guests.${role}.hostName}
    '')
    byBootOrder;

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
          ${guest.storage} ${guest.diskFormat} ${toString guest.bootDelay}
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
        hermes-provision-guests create            create the guests that do not exist yet
        hermes-provision-guests snapshot <label>  snapshot every guest
        hermes-provision-guests status            list the guests and their start order

      create runs preflight first and stops on its findings, before the node
      has been written to. Guests that already exist are left untouched, so an
      interrupted run is finished by running create again.
      USAGE
      }

      VMIDS=(${lib.concatMapStringsSep " " (role: toString cfg.guests.${role}.vmid) byBootOrder})

      PROBLEMS=0

      problem() {
        printf 'error: %s\n' "$1" >&2
        PROBLEMS=$((PROBLEMS + 1))
      }

      note() {
        printf '       %s\n' "$1" >&2
      }

      # --- What the node actually holds -----------------------------------
      #
      # Read once. Both lists are needed: a pool can be declared and still be
      # refused by qm create, either because it is not online or because it
      # does not carry content=images, and the refusal is worded the same way
      # in every case.
      STORAGE_ALL=""
      STORAGE_IMAGES=""

      # Pools already examined. A pool carries several volumes, and reporting
      # one absent pool once per volume it was going to hold turns a single
      # defect into a list, which is how the one line that has to change stops
      # being visible.
      STORAGE_SEEN=""

      read_node() {
        if ! command -v qm >/dev/null 2>&1 || ! command -v pvesm >/dev/null 2>&1; then
          echo "qm and pvesm are not on PATH: this command runs on the Proxmox node." >&2
          exit 2
        fi

        STORAGE_ALL=$(pvesm status 2>/dev/null | awk 'NR > 1 { print $1 "\t" $2 "\t" $3 }')
        STORAGE_IMAGES=$(pvesm status --content images 2>/dev/null | awk 'NR > 1 { print $1 }')
      }

      storage_field() {
        printf '%s\n' "$STORAGE_ALL" | awk -F '\t' -v name="$1" -v col="$2" '$1 == name { print $col }'
      }

      vm_exists() {
        qm config "$1" >/dev/null 2>&1
      }

      vm_name() {
        qm config "$1" 2>/dev/null | sed -n 's/^name: *//p'
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

      cmd_preflight() {
        read_node
        PROBLEMS=0
        STORAGE_SEEN=""

        ${storageChecks}
        ${vmidChecks}

        if [ "$PROBLEMS" -gt 0 ]; then
          local word="problems"
          if [ "$PROBLEMS" -eq 1 ]; then
            word="problem"
          fi
          printf '\n%s %s on the node. Nothing was created.\n' "$PROBLEMS" "$word" >&2
          return 1
        fi

        echo "Preflight: every pool the inventory names is present, active and takes images."
      }

      create_guest() {
        local id="$1" name="$2" cores="$3" ram="$4" disk="$5"
        local vlan="$6" order="$7" store="$8" fmt="$9" delay="''${10}"

        qm create "$id" \
          --name "$name" --ostype l26 --cpu host \
          --cores "$cores" --memory "$ram" --balloon 0 \
          --numa ${if cfg.site.numa then "1" else "0"} \
          --scsihw virtio-scsi-single \
          --scsi0 "''${store}:''${disk},iothread=1,discard=on,ssd=1,format=''${fmt}" \
          --net0 "virtio,bridge=${cfg.network.bridge},tag=''${vlan},firewall=1" \
          --onboot 1 --startup "order=''${order},up=''${delay}" \
          --agent enabled=1 --protection 1
      }

      cmd_create() {
        # The gate is the point: a pool missing from the node stops the run
        # here, with nothing allocated, rather than after the guests before it
        # in the start order have already been written.
        cmd_preflight
        echo
        ${lib.concatStringsSep "\n" (map createGuest byBootOrder)}

        qm list
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
