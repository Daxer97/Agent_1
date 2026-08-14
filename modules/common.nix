# Configuration shared by every guest.
#
# What belongs here is what must be true of all of them: time, name
# resolution, administrative access, the derivation of the age identity used
# to decrypt the bootstrap credential, and the build settings. Anything that
# differs by role belongs to the role module instead.

{ config, lib, pkgs, ... }:

let
  cfg = config.hermes;
  guest = cfg.guests.${cfg.role};

  zoneOf = zone: cfg.network.zones.${zone};

  prefixLength = zone:
    lib.toInt (lib.last (lib.splitString "/" (zoneOf zone).cidr));

  # Predictable interface names are disabled below, so the interfaces appear
  # in the order the machine declares them: the primary one first, then the
  # additional ones in the order they are listed. That order is a property of
  # the guest definition, which makes the naming deterministic without
  # depending on firmware-reported slots.
  primaryInterface = {
    name = "eth0";
    address = guest.address;
    prefix = prefixLength guest.zone;
  };

  extraInterfaces = lib.imap1
    (index: interface: {
      name = "eth${toString index}";
      address = interface.address;
      prefix = prefixLength interface.zone;
      zone = interface.zone;
    })
    guest.extraInterfaces;

  allInterfaces = [ primaryInterface ] ++ extraInterfaces;

  # Zones this guest has an interface in. Everything else it reaches through a
  # router.
  attachedZones = [ guest.zone ] ++ (map (interface: interface.zone) guest.extraInterfaces);

  unattachedZones = lib.filter
    (name: !(builtins.elem name attachedZones))
    (builtins.attrNames cfg.network.zones);

  # A dual-homed guest is dual-homed for a reason: the flows towards the
  # downstream services must leave from its application interface. The default
  # route points at the zone of the primary interface, so without an explicit
  # route the reply to a request bound to the application address would leave
  # through the other one — the packet is not dropped by anything here, it is
  # dropped upstream, on a path nobody is looking at.
  applicationInterface = lib.findFirst
    (interface: interface.zone == "app")
    null
    extraInterfaces;

  routeTo = zone: {
    address = lib.head (lib.splitString "/" (zoneOf zone).cidr);
    prefixLength = prefixLength zone;
    via = (zoneOf zone).gateway;
  };

  # Volumes attached to this guest beyond its root disk. They are created by
  # the provisioning script as additional SCSI devices, in declaration order,
  # and the guest sees them as /dev/sdb, /dev/sdc, and so on. Declaring the
  # mount is what makes the separation real: attached and unmounted, the path
  # is an ordinary directory on the root volume and the growth it was meant to
  # contain lands on the disk of whatever else the guest runs.
  extraVolumes = lib.imap0
    (index: disk: {
      inherit (disk) mountPoint;
      device = "/dev/sd${lib.elemAt lib.lowerChars (index + 1)}";
    })
    guest.extraDisks;
in
{
  config = {
    system.stateVersion = cfg.nix.stateVersion;
    time.timeZone = cfg.network.timeZone;

    networking = {
      useDHCP = false;
      nameservers = cfg.network.nameservers;
      usePredictableInterfaceNames = false;

      interfaces = lib.listToAttrs (map
        (interface: lib.nameValuePair interface.name {
          ipv4.addresses = [{
            address = interface.address;
            prefixLength = interface.prefix;
          }];

          # Zones the guest is not attached to are reached through the
          # application interface when it has one, so that the flow leaves
          # from the address the downstream rules admit.
          ipv4.routes = lib.optionals
            (applicationInterface != null && interface.name == applicationInterface.name)
            (map routeTo unattachedZones);
        })
        allInterfaces);

      # Out of the zone: the resolver, the time source, the management range
      # and — for every guest but the dual-homed one — the other two zones.
      defaultGateway = {
        address = (zoneOf guest.zone).gateway;
        interface = primaryInterface.name;
      };
    };

    # The additional volumes, mounted where they were declared to be. Formatted
    # on first boot if they carry no filesystem: the provisioning script
    # attaches raw devices, and a volume that is attached and unmounted is
    # indistinguishable from a directory on the root disk until the day it
    # matters.
    fileSystems = lib.listToAttrs (map
      (volume: lib.nameValuePair volume.mountPoint {
        device = volume.device;
        fsType = "ext4";
        autoFormat = true;
        options = [ "noatime" ];
      })
      extraVolumes);

    services.timesyncd = {
      enable = true;
      servers = cfg.network.ntpServers;
    };

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };

    # The guest agent is what lets the node take a consistent snapshot and
    # report the guest address back. Both are relied upon by the installation
    # procedure.
    services.qemuGuest.enable = true;

    # The age identity is derived from the host key: there is no additional
    # key to distribute, and a guest can decrypt its own secrets and no
    # others.
    # The bootstrap credentials themselves are declared by the secret store
    # agent module, one pair per machine identity the guest hosts.
    sops.age.sshKeyPaths = [ cfg.nix.sopsAgeKeyPath ];
    sops.defaultSopsFile = ../secrets + "/${guest.hostName}.yaml";

    # Outbound traffic is denied by default on every guest, which also stops a
    # rebuild performed locally as root from reaching the binary cache. The
    # closures are therefore built elsewhere and pushed, which is the option
    # consistent with the design: a guest running untrusted code has no need
    # of a build toolchain.
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      substituters = cfg.nix.substituters;
      auto-optimise-store = true;
    };

    environment.systemPackages = with pkgs; [
      curl
      jq
    ];

    # Core dumps of platform services would contain credential material.
    systemd.coredump.enable = false;

    boot.kernel.sysctl = {
      "kernel.dmesg_restrict" = 1;
      "net.ipv4.conf.all.rp_filter" = 1;
    };
  };
}
