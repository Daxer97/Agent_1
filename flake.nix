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
      url = "github:Daxer97/agent_1";
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
      # Every value that describes a specific installation lives in a single
      # file. The repository ships an unfilled template only: an operator
      # copies it to parameters.nix, fills it in, and versions it alongside
      # the flake, so the flake remains the single point of truth required by
      # HLD DD-06. Evaluation stops with an explicit message until that file
      # exists, which is the earliest and cheapest place for the failure to
      # occur.
      # ----------------------------------------------------------------------
      parametersPath = ./parameters.nix;

      parameters =
        if builtins.pathExists parametersPath
        then import parametersPath
        else throw ''
          parameters.nix is missing.

          Copy the template and fill in the values of the deployment variable
          matrix before evaluating this flake:

              cp parameters.example.nix parameters.nix
              $EDITOR parameters.nix

          Every parameter is documented in README.md. Parameters that describe
          the site — addresses, storage identifiers, VMIDs, public keys — have
          no default on purpose: an unset one is reported by name instead of
          being silently replaced by a value that happens to evaluate.
        '';

      guests = parameters.hermes.guests or
        (throw "parameters.nix does not define hermes.guests.");

      # A guest whose aliasOf is set has no configuration of its own: its
      # components are hosted by the guest it points at. The alias keeps the
      # role addressable in the configuration files that already reference it,
      # without creating a virtual machine that does not exist.
      activeRoles = lib.filter
        (role: (guests.${role}.aliasOf or null) == null)
        (builtins.attrNames guests);

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
          {
            hermes.role = role;
            networking.hostName = guests.${role}.hostName;
          }
          (./hosts + "/${role}.nix")
        ];
      };

      # Policy documents and provisioning helpers are rendered from the same
      # parameters as the guests, through the same module evaluation, so that
      # option defaults apply to them too. Nothing carrying a site value is
      # written twice: a second copy is a second place where it can be wrong.
      reference = (mkHost "agent").config;

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
      # the repository. This is the cheapest way of stopping a partially
      # configured environment from reaching the deployment phases, where the
      # same defect costs an order of magnitude more to diagnose.
      #
      # The check deliberately ignores ${...} references: those are runtime
      # secrets rendered by the secret store agent and must never appear in
      # the repository in any form. They are verified against the secret store
      # itself, not against the working tree.
      #
      # It also ignores files whose name carries `.example.`: those are
      # versioned unfilled on purpose — they are what a site is copied from —
      # so their markers are the one case where a placeholder is the correct
      # content, and reporting them says nothing about the deployment.
      #
      # What is left is not expected to be empty from the start. The age keys
      # of the guests do not exist until the guests do, and the backup
      # recipient belongs to whoever holds it. The gate stays red until they
      # are all filled in, and that is its job: what it must not do is report
      # something that will never be filled in, because a signal that is
      # always red is one nobody reads.
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

        # --- Gate: the recorded revision is the one that is built ----------
        # hermes.agent.sourceRevision is what the trajectory files report as
        # the version that produced them, and the flake input is what is
        # actually built. Nothing keeps the two together on its own: updating
        # the lock changes the code and leaves the parameter reporting the
        # revision it replaced, so the measurement of reproducibility would be
        # taken against a version string that no longer describes anything.
        agent-revision-pinned =
          let recorded = reference.hermes.agent.sourceRevision;
          in pkgs.runCommand "agent-revision-pinned" { } (
            if lib.hasPrefix recorded hermes-src.rev
            then "touch $out"
            else ''
              echo "hermes.agent.sourceRevision is ${recorded}, but the runtime"
              echo "input resolves to ${hermes-src.rev}."
              echo
              echo "Set the parameter to the locked revision, or lock the input"
              echo "to the recorded one:"
              echo "    nix flake lock --override-input hermes-src \\"
              echo "        github:Daxer97/hermes-agent/${recorded}"
              exit 1
            '');

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
