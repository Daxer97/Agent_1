# The installation image the guests boot before they are installed.
#
# `nixos-anywhere` does not create a machine and does not boot one: it
# connects over SSH to a Linux already running on the target. Something has to
# put that Linux there, and the stock minimal image cannot be it — it comes up
# with no authorised key and no address, and these zones have no DHCP server,
# so both have to be typed into a console. Two guests, two consoles, four
# chances to type an address that is not the one the flake declares.
#
# So the image is built from the inventory instead. It carries the
# administrative keys and a table of every guest's address keyed by hardware
# address, which is why those are declared rather than left to Proxmox: one
# image serves every guest, and each recognises itself when it boots.
#
# What it is not: it is not the installed system, and nothing here is
# inherited by it. The image is a shell that lives in RAM for the length of
# one installation — the guests are defined by their own configurations, which
# nixos-anywhere writes to disk from this flake.

{ hermes, lib, modulesPath, ... }:

let
  activeRoles = lib.filter
    (role: hermes.guests.${role}.aliasOf == null)
    (builtins.attrNames hermes.guests);

  byBootOrder = lib.sort
    (a: b: hermes.guests.${a}.bootOrder < hermes.guests.${b}.bootOrder)
    activeRoles;

  zoneOf = zone: hermes.network.zones.${zone};

  prefixLength = zone:
    lib.toInt (lib.last (lib.splitString "/" (zoneOf zone).cidr));

  # One network per guest, matched on the address the inventory assigns to its
  # primary interface. A guest that boots this image finds exactly one match
  # and configures itself with the address it will keep once installed, so the
  # installation and the installed system are reached at the same place.
  networkOf = index: role:
    let guest = hermes.guests.${role}; in
    lib.nameValuePair "${toString (10 + index)}-${guest.hostName}" {
      matchConfig.MACAddress = guest.macAddress;
      address = [ "${guest.address}/${toString (prefixLength guest.zone)}" ];
      networkConfig = {
        Gateway = (zoneOf guest.zone).gateway;
        LinkLocalAddressing = "no";
      };
      linkConfig.RequiredForOnline = "routable";
    };
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  config = {
    # The file name the provisioning script attaches, without its extension.
    # It is baseName and not isoName: since 25.05 the image derivation takes
    # its name from here, and isoName — renamed to image.fileName — no longer
    # reaches it. Setting the wrong one of the two produces an image that
    # builds and is never found where the script looks for it.
    image.baseName = lib.mkForce (lib.removeSuffix ".iso" hermes.site.installerImage);

    # The image is written to the node's iso pool and booted from there. It
    # never leaves this deployment, and the volume label is what the operator
    # sees in the boot menu of a guest that stops at it.
    isoImage.volumeID = lib.mkForce "HERMES_INSTALL";
    networking.hostName = lib.mkForce "hermes-installer";

    # Static, and declared per guest. The alternative is DHCP, and the zones
    # of this design have no server to answer it: a guest that comes up
    # without an address has to be given one through the console, which is the
    # step this image exists to remove.
    networking.useDHCP = lib.mkForce false;
    networking.useNetworkd = true;
    networking.wireless.enable = lib.mkForce false;

    systemd.network.networks = lib.listToAttrs (lib.imap0 networkOf byBootOrder);

    # The dual-homed guest boots with a second interface this image does not
    # recognise — deliberately, since nothing reaches it before the guest is
    # installed. Waiting for every link to be configured would hold the boot
    # at that one until it times out.
    systemd.network.wait-online.anyInterface = true;

    assertions = [{
      assertion = hermes.nix.adminKeys != [ ]
        && !(lib.any (key: lib.hasPrefix "PLACEHOLDER_" key) hermes.nix.adminKeys);
      message = ''
        hermes.nix.adminKeys is empty or still carries a placeholder, and this
        image has no other way in: its root account has no password and
        password authentication is disabled. It would build, and it would
        produce guests that boot, come up on their declared addresses, and
        admit nobody. Set it to the operator's public key:
            cat ~/.ssh/id_ed25519.pub
      '';
    }];

    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = lib.mkForce false;
        PermitRootLogin = lib.mkForce "prohibit-password";
      };
    };

    # The only way in, on an image whose root account has no password. The
    # installation image of a machine with no identity yet is exactly where a
    # password would be typed into a console and then reused.
    users.users.root.openssh.authorizedKeys.keys = hermes.nix.adminKeys;

    # Time is not cosmetic here: the installer writes the store and the
    # bootloader, and a clock behind the source it is installing from produces
    # failures that read as corruption.
    services.timesyncd = {
      enable = true;
      servers = hermes.network.ntpServers;
    };
    time.timeZone = hermes.network.timeZone;

    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      substituters = hermes.nix.substituters;
    };

    # The default is zstd at level 19, which is chosen for images that are
    # downloaded. This one is copied once, to a pool on the same node: level 6
    # builds it several times faster for a few hundred megabytes nobody
    # transfers.
    isoImage.squashfsCompression = "zstd -Xcompression-level 6";

    system.stateVersion = hermes.nix.stateVersion;
  };
}
