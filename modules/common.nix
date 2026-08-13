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
    })
    guest.extraInterfaces;

  allInterfaces = [ primaryInterface ] ++ extraInterfaces;
in
{
  config = {
    system.stateVersion = cfg.nix.stateVersion;
    time.timeZone = cfg.network.timeZone;

    networking = {
      hostName = guest.hostName;
      useDHCP = false;
      nameservers = cfg.network.nameservers;
      usePredictableInterfaceNames = false;

      interfaces = lib.listToAttrs (map
        (interface: lib.nameValuePair interface.name {
          ipv4.addresses = [{
            address = interface.address;
            prefixLength = interface.prefix;
          }];
        })
        allInterfaces);
    };

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
