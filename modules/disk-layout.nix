# Root volume layout and boot path of every guest.
#
# The additional volumes are declared in common.nix, next to the mount points
# they serve. The root volume is declared here instead, because it is not a
# mount but the whole installation: it is what nixos-anywhere partitions
# before a single option of this flake reaches the guest, and what the
# bootloader is written to afterwards.
#
# Neither existed. The guests declared the volumes they mount and nothing
# about the one they boot from, so `nixosConfigurations` could not evaluate at
# all — the root filesystem and the bootloader are assertions in NixOS itself,
# not conventions — and nixos-anywhere had no partition table to apply. The
# layout is stated once, here, for every guest: it is a property of how they
# are provisioned, and no role varies it.
#
# The layout follows what pve-provision.nix creates and cannot be chosen
# independently of it:
#
#   * `qm create` sets neither `--bios ovmf` nor `--efidisk0`, so the guests
#     start on SeaBIOS. UEFI is not merely unselected — without an EFI disk
#     there is nowhere for a UEFI variable store to live, so the boot path is
#     legacy BIOS and the bootloader is GRUB embedded in the disk.
#   * The table is still GPT, with the 1 MiB BIOS boot partition that legacy
#     booting from GPT requires. GPT keeps a backup header, which is what
#     makes a resized volume recoverable; an MBR label would save nothing
#     here and forfeit that.
#   * The root volume is attached as scsi0, so it is hermes.nix.rootDevice.

{ config, lib, ... }:

let
  device = config.hermes.nix.rootDevice;
in
{
  disko.devices.disk.root = {
    inherit device;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        # Where GRUB's core image goes. It holds no filesystem and is never
        # mounted: one megabyte, before everything else on the disk. The
        # ordering is not written out here because disko already derives it —
        # an EF02 partition is placed first and one sized 100% last — and a
        # priority stated by hand would only be a second place for it to
        # disagree.
        bios = {
          size = "1M";
          type = "EF02";
        };

        # The remainder. Sized by hermes.guests.<role>.diskGb on the node
        # side, so the partition takes whatever the volume was created with
        # and a volume that is grown later is grown here too.
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            # Matching the additional volumes: none of these filesystems
            # carries a workload that reads access times, and writing them
            # back costs a write for every read.
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };

  boot.loader = {
    # Written to the disk rather than to a partition, which is what the BIOS
    # boot partition above exists to make possible.
    grub = {
      enable = true;
      efiSupport = false;
      devices = [ device ];
    };

    # The guests are started by the node in a fixed order with a delay between
    # them, and that order is already the slowest part of a cold start. A menu
    # nobody is at the console to read need not extend it.
    timeout = lib.mkDefault 1;
  };
}
