# Bootstrap credentials

This directory holds one encrypted file per guest, versioned as ciphertext.
Each file contains a single thing: the credential with which that guest proves
its identity to the secret store. Every other secret lives in the store and is
never versioned.

The split exists because a vault cannot hold the key that opens it. That one
credential — and only that one — has to travel with the configuration.

## Structure of a file

Decrypted, a file looks like this. It never exists in this form in the
repository.

```yaml
openbao:
  hermes:
    role_id: <role identifier>
    secret_id: <secret identifier>
  broker:
    role_id: <role identifier>
    secret_id: <secret identifier>
```

One pair per machine identity the guest hosts. The agentic guest hosts two:
the agent runtime and the egress broker. They are separate identities on
purpose — the broker holds the only policy able to read an inference
credential, and the runtime must not inherit it.

The ingress guest carries one additional key. The identity provider's user
file holds password digests, and it cannot come from the secret store for the
same reason the bootstrap credential cannot: the provider must be able to
authenticate before anything else on that guest works. It is decrypted at
activation into `/etc/authelia/users.yml`, owned by the provider and readable
by nobody else.

```yaml
authelia:
  users_file: |
    users:
      ...            # shape in config/authelia/users.example.yml
```

## Creating a file

```sh
nix develop                      # sops is here, not on the system
"${EDITOR:-vi}" secrets/<host>.yaml
sops --config /dev/null --age "$ADMIN" --encrypt --in-place secrets/<host>.yaml
git add secrets/<host>.yaml
```

`--config /dev/null` applies until the guests exist. The rules in `.sops.yaml`
name each guest's key alongside the administrator's, and sops will not encrypt
for a recipient it cannot parse, so while those are still markers every
creation through the rules fails — including for the guests whose key is not
the one it happens to report. Encrypting to the administrator alone is enough
to make the file exist, which is all the evaluation needs; `sops updatekeys`
adds the guest once its key is real, and it reads `.sops.yaml` normally.

The second command is not tidiness. A flake is evaluated from the tracked tree,
so a file that exists here and was never added is not there as far as the
evaluation is concerned — and because these files are read while the
configuration is evaluated rather than while it is activated, the result is not
a guest that fails to start but a repository that does not evaluate at all.

One file per guest is required before `nix flake check` reports anything else,
including the placeholder gate.

The encryption rules are in `.sops.yaml` at the root of the repository. Verify,
from the guest itself rather than from the workstation, that it can decrypt its
own file and no other:

```sh
ssh <guest> "sops -d /etc/nixos/secrets/<host>.yaml >/dev/null && echo OK"
```

A successful decryption of a file that does not belong to that guest means the
rules are too broad. Correct them before going any further: a guest that can
read another guest's credentials makes the whole policy separation decorative.
