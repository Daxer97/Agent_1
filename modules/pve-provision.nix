# Node-side provisioning helper.
#
# The guests are created from the same inventory the NixOS configurations are
# built from. Writing the creation commands by hand would introduce a second
# place where a VMID, a storage identifier or a start order can be wrong, and
# the two would disagree without either of them failing.
#
# The script is meant to run on the Proxmox node. It is generated here so that
# it cannot drift from the declaration.

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

  createGuest = role:
    let
      guest = cfg.guests.${role};
    in
    ''
      create_guest \
        ${toString guest.vmid} ${guest.hostName} ${toString guest.cores} \
        ${toString guest.memoryMb} ${toString guest.diskGb} \
        ${vlanOf guest.zone} ${toString guest.bootOrder} \
        ${guest.storage} ${guest.diskFormat} ${toString guest.bootDelay}
    ''
    + lib.concatMapStrings
      (interface: ''
        # Second interface, in the ${interface.zone} zone. Only this guest is
        # dual-homed, and the flows towards the downstream services are
        # admitted from this interface alone.
        qm set ${toString guest.vmid} --net1 \
          "virtio,bridge=${cfg.network.bridge},tag=${vlanOf interface.zone},firewall=1"
      '')
      guest.extraInterfaces
    + lib.optionalString (guest.cpuLimit != null) ''

      # CPU ceiling: keeps a delegation fan-out from saturating the node.
      qm set ${toString guest.vmid} --cpulimit ${toString guest.cpuLimit}
    ''
    + lib.concatMapStrings
      (disk: ''

        # Additional volume mounted on ${disk.mountPoint}. Without it the
        # observability backends write to the root filesystem of this guest,
        # and when that fills up what is lost is not observability.
        qm set ${toString guest.vmid} --scsi1 \
          "${disk.storage}:${toString disk.sizeGb},iothread=1,discard=on,ssd=1"
      '')
      guest.extraDisks;

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
        hermes-provision-guests create            create every guest
        hermes-provision-guests snapshot <label>  snapshot every guest
        hermes-provision-guests status            list the guests and their start order
      USAGE
      }

      VMIDS=(${lib.concatMapStringsSep " " (role: toString cfg.guests.${role}.vmid) byBootOrder})

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
        ${lib.concatStringsSep "\n" (map createGuest byBootOrder)}

        qm list
      }

      cmd_snapshot() {
        local label="''${1:-}"
        if [ -z "$label" ]; then
          echo "A snapshot label is required." >&2
          exit 2
        fi

        for id in "''${VMIDS[@]}"; do
          qm snapshot "$id" "$label"
        done
      }

      cmd_status() {
        for id in "''${VMIDS[@]}"; do
          echo "=== $id ==="
          qm config "$id" | grep -E '^(name|startup|memory|cores):' || true
        done
      }

      case "''${1:-}" in
        create)   cmd_create ;;
        snapshot) shift; cmd_snapshot "''${1:-}" ;;
        status)   cmd_status ;;
        *)        usage; exit 2 ;;
      esac
    '';
  };
in
{
  config = {
    system.build.pveProvisionScript = provisionScript;
  };
}
