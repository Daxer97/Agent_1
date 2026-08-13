# Evaluation datasets

The retrieval objective is measured as the outcome of a reproducible
experiment over a versioned dataset, not as a sample rebuilt at each
measurement. That is what this directory is for, and why it is versioned
alongside the configuration.

`obj03-recall.example.jsonl` is the shape of that dataset, not its content.
Replace it with the real evaluation set and load it once:

```sh
phoenix datasets create --name <dataset> \
  --file config/phoenix/datasets/<dataset>.jsonl
```

Two properties matter more than the size of the set.

The evaluators run at temperature zero. A non-deterministic evaluation does not
detect drift in the knowledge graph — it imitates it, and produces a series
that looks informative and is not.

The measurement is taken after consolidation has run. Taken immediately after
retention, the result is systematically pessimistic and the threshold appears
to be missed when it is met.
