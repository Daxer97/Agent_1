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

## Creating a file

```sh
sops secrets/<host>.yaml
```

The encryption rules are in `.sops.yaml` at the root of the repository. Verify,
from the guest itself rather than from the workstation, that it can decrypt its
own file and no other:

```sh
ssh <guest> "sops -d /etc/nixos/secrets/<host>.yaml >/dev/null && echo OK"
```

A successful decryption of a file that does not belong to that guest means the
rules are too broad. Correct them before going any further: a guest that can
read another guest's credentials makes the whole policy separation decorative.
