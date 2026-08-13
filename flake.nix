{
  description = "HERMES-AGENT — declarative infrastructure for the agent_1 platform on Proxmox VE";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # --- uv2nix toolchain: reproducible builds of the Python components -----
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Authoritative source of the agent runtime: the fork versioned by this
    # project, pinned to an immutable revision. Never a moving reference.
    # The revision itself is a parameter (hermes.agent.sourceRevision); this
    # input only fixes the repository the flake fetches it from.
    hermes-src = {
      url = "github:Daxer97/hermes-agent";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , sops-nix
    , pyproject-nix
    , uv2nix
    , build-systems
    , hermes-src
    , ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = false;
      };

      python = pkgs.python312;

      # ----------------------------------------------------------------------
      # Site parameters
      #
      # Every option carries the proposed value of the deployment variable
      # matrix as its default, so parameters.nix holds only what this
      # installation changes — plus the handful of values the matrix does not
      # propose, and the acknowledgement that the rest were checked.
      #
      # The file is still required. A configuration that builds from defaults
      # alone would describe the reference installation rather than this one,
      # and it would do so without anybody having said so.
      # ----------------------------------------------------------------------
      parametersPath = ./parameters.nix;

      parameters =
        if builtins.pathExists parametersPath
        then import parametersPath
        else throw ''
          parameters.nix is missing.

          Copy the template and review it against the node before evaluating
          this flake:

              cp parameters.example.nix parameters.nix
              $EDITOR parameters.nix

          Every option already defaults to the proposed value of the variable
          matrix, so the file is short by design: it carries the values the
          matrix does not propose, whatever this site changes, and the review
          acknowledgement. All of them are documented in README.md.
        '';

      # ----------------------------------------------------------------------
      # Python environments
      # ----------------------------------------------------------------------
      mkVenv = name: root:
        let
          workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = root; };
          overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
          base = pkgs.callPackage pyproject-nix.build.packages { inherit python; };
          pySet = base.overrideScope (lib.composeManyExtensions [
            build-systems.overlays.default
            overlay
          ]);
        in
        pySet.mkVirtualEnv name workspace.deps.default;

      egressBroker = mkVenv "egress-broker-env" ./pkgs/egress-broker;
      hermesEnv = mkVenv "hermes-env" hermes-src;

      # ----------------------------------------------------------------------
      # NixOS systems
      # ----------------------------------------------------------------------
      commonModules = [
        sops-nix.nixosModules.sops
        parameters
        ./modules/options.nix
        ./modules/common.nix
        ./modules/pve-provision.nix
        ./modules/network-zones.nix
        ./modules/secrets-agent.nix
        { nixpkgs.pkgs = pkgs; }
      ];

      mkHost = role: lib.nixosSystem {
        inherit system;
        specialArgs = { inherit egressBroker hermesEnv hermes-src; };
        modules = commonModules ++ [
          { hermes.role = role; }
          (./hosts + "/${role}.nix")
        ];
      };

      # One evaluation answers the questions the flake itself has to ask:
      # which guests exist, what they are called, and where the policy
      # documents and the provisioning script get their values. Reading them
      # from an evaluated configuration rather than from the raw parameter
      # file is what lets the option defaults apply to them too.
      reference = (mkHost "agent").config;

      guests = reference.hermes.guests;

      # A guest whose alias is set has no configuration of its own: its
      # components are hosted by the guest it points at. The alias keeps the
      # role addressable in the configuration that already references it,
      # without creating a virtual machine that does not exist.
      activeRoles = lib.filter
        (role: guests.${role}.aliasOf == null)
        (builtins.attrNames guests);

      baoPolicies = pkgs.callPackage ./policies {
        inherit (reference.hermes.secretStore) mount;
      };

      pveProvision = reference.system.build.pveProvisionScript;
    in
    {
      packages.${system} = {
        inherit egressBroker hermesEnv baoPolicies pveProvision;
        default = egressBroker;
      };

      apps.${system}.provision-guests = {
        type = "app";
        program = "${pveProvision}/bin/hermes-provision-guests";
      };

      nixosConfigurations = lib.listToAttrs (map
        (role: lib.nameValuePair guests.${role}.hostName (mkHost role))
        activeRoles);

      # --- Gate: no unresolved placeholder may survive a build --------------
      # `nix flake check` fails while a single PLACEHOLDER_ marker is left in
      # a file the deployment actually reads. This is the cheapest way of
      # stopping a partially configured environment from reaching the
      # deployment phases, where the same defect costs an order of magnitude
      # more to diagnose.
      #
      # Files named *.example.* are exempt. They are templates by definition
      # and their markers are the point: the operator copies them and fills in
      # the copy, and it is the copy the check has to see.
      #
      # The check deliberately ignores ${...} references. Those are runtime
      # secrets rendered by the secret store agent and must never appear in
      # the repository in any form, so they are verified against the secret
      # store itself rather than against the working tree.
      checks.${system} = {
        no-unresolved-placeholders =
          pkgs.runCommand "no-unresolved-placeholders" { src = ./.; } ''
            if grep -RIn --exclude-dir=.git --exclude='*.example.*' \
                 -e 'PLACEHOLDER_[A-Z0-9_]\+' "$src" > found.txt
            then
              echo "Unresolved placeholders — see the variable tables in README.md:"
              cat found.txt
              exit 1
            fi
            touch $out
          '';

        inherit baoPolicies;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          age
          jq
          nixpkgs-fmt
          sops
          ssh-to-age
          uv
          yq-go
        ];
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
