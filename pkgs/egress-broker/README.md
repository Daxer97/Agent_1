# Egress broker

An OpenAI-compatible proxy that holds the inference credential on behalf of
the agentic runtime. The runtime receives an internal token; only this process
ever sees the real gateway key.

## Contract

The implementation is replaceable, the contract is not. Any substitute must
satisfy every row below.

| Requirement | How this implementation satisfies it |
| --- | --- |
| Protocol transparency: the body is forwarded intact, including gateway-specific fields and the deliberation alias | The body is read as a byte sequence and resent without deserialisation. No request model, no schema validation. |
| Credential substitution at the container boundary | Only the authorisation header is rewritten. Hop-by-hop headers are dropped as HTTP prescribes; every other header passes through. |
| Spending cap per plane and per profile | In-memory counters checked before forwarding. Beyond the hard cap the request is rejected with a retry hint. |
| Cost metrics labelled by plane, profile and purpose | The real cost is read back from the gateway's accounting endpoint, queried by generation identifier on a separate channel. |
| Streamed responses without buffering | Chunk-level pass-through. The generation identifier is found in the first chunk without altering the bytes forwarded. |
| Capacity reserved for the interactive plane | Two semaphores. The programmatic plane cannot occupy more than the unreserved share of the connections towards the gateway. |
| Revocation without a rebuild | Tokens and credentials are read from the runtime secrets directory and reloaded on `SIGHUP`. |

## Three lines that must not be "cleaned up"

`body = await request.body()` followed by `content=body`. Replacing it with a
parsed body would look tidier and would break protocol transparency: the
re-serialisation is not byte-identical and gateway-specific fields would be
normalised away.

`async for chunk in upstream.aiter_raw()` with `yield chunk`. Accumulating the
chunks for convenience of logging would change the perceived latency of a
streamed answer, which is precisely what the interface contract asks not to
do.

`access_log=False`. The access log would record paths and query strings.

## Building

The package is built through `uv2nix`, which requires a resolved lock file.
Generate it once and commit it next to `pyproject.toml`:

```sh
nix develop -c uv lock
git add pkgs/egress-broker/uv.lock
```

The lock file is a deliverable, not a build artefact: it is what makes the
reproducibility target measurable.
