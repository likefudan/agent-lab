# Decision 0009: Keep DuckDuckGo and defer SearXNG

Status: accepted

## Decision

The MVP keeps the DuckDuckGo integration bundled with pinned Open WebUI 0.10.2
and does not add SearXNG to `compose.yaml`. The measured search cases meet the
current online-search requirements, while no explicit privacy or provider-control
requirement calls for another local service.

DuckDuckGo remains available only in the `online-manual` and explicitly selected
`online-automatic` profiles. The `offline` profile disables web search. Search
results remain transient context unless the user separately ingests a URL or
document into Open WebUI knowledge.

## Measured evidence

The P6-T02 integration suite uses two time-stable queries with different
authoritative target domains. The latest recorded run in
`.agent-lab/results/search-latest.jsonl` produced:

| Case | Required evidence | Result | Latency |
| --- | --- | --- | ---: |
| `iana_reserved_domains` | An `iana.org` source and a snippet containing `example` | Pass | 2 s |
| `python_pathlib_docs` | A `docs.python.org` source and a snippet containing `pathlib` | Pass | 6 s |

Across those two independent provider requests, 2/2 qualified results passed.
The observed external-provider failure rate was 0/2 (0%), and the observed
provider-result-drift rate was 0/2 (0%). Latency ranged from 2 to 6 seconds, with
a 4-second mean.

The same suite also gates behavior outside the saved per-query result artifact:

- the offline profile rejects the search endpoint with HTTP 403;
- the online/manual profile exposes DuckDuckGo only after profile selection;
- successful results contain fetched source URLs and complete citation records;
- the qualified local tool-calling model selects search for a current-information
  request and does not select it for a timeless arithmetic request; and
- the suite restores `online-manual`, the default online behavior, when it
  finishes.

The result file intentionally contains only the latest run, so these numbers are
an acceptance snapshot, not a claim of long-term provider availability. In
particular, two passing queries cannot measure regional blocking, sustained rate
limits, or future markup drift. That limitation does not justify SearXNG by
itself: the deferred-work gate requires repeated failures or an explicit unmet
requirement, neither of which is present.

## Comparison against MVP requirements

| Concern | DuckDuckGo through Open WebUI | SearXNG impact | MVP conclusion |
| --- | --- | --- | --- |
| Reliability | Both required queries passed; the suite distinguishes HTTP/provider failures from local model failures. | Can aggregate multiple engines, but those upstream engines can still fail or rate-limit requests. It also adds a service that must remain healthy. | No measured reliability gap. |
| Privacy | Queries and normal network metadata leave the computer in online profiles. No credential is configured, and offline disables the provider. | A local instance centralizes engine policy, but it still makes outbound requests unless paired with separately designed network/proxy controls. It does not make web search offline. | Current explicit opt-in and offline boundary satisfy the stated policy. |
| Provider control | The MVP selects one keyless engine and exposes only profile-level enablement. | Offers engine selection and instance-level policy under operator control. | Multiple-provider, locale, proxy, or engine-policy control is not currently required. |
| Result quality | Both stable cases returned the expected authoritative domain, matching snippet, fetched sources, and citation shape. | Could improve coverage through aggregation, but no same-corpus quality deficit has been measured. | Current denominator passes. |
| Operational cost | Uses the pinned Open WebUI integration with no API key, extra image, port, service lifecycle, or additional offline artifact. | Requires another pinned image, configuration, network policy, health checks, updates, resource measurement, and failure/recovery procedures. | Added cost has no demonstrated MVP benefit. |

## Revisit criteria

SearXNG may be proposed only through a separately reviewed design and
implementation plan when at least one of these conditions is demonstrated:

1. A required search case records an external-provider failure or result drift
   in at least two of three independent suite runs, and the same corpus shows a
   materially better result through a pinned SearXNG candidate.
2. An explicit privacy requirement prohibits direct DuckDuckGo requests and a
   documented SearXNG egress design measurably improves that boundary.
3. A concrete workflow requires operator-controlled engines, locales, proxies,
   or multiple-provider aggregation that the pinned Open WebUI DuckDuckGo path
   cannot provide.

Any proposal must pin the SearXNG image by immutable digest, define its allowed
egress and offline behavior, measure its memory and latency on the target Mac,
add lifecycle and health coverage, and re-run the same search/citation corpus.
Until that evidence exists, SearXNG remains absent from the MVP.
