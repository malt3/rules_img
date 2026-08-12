# Design: process-wide blob location cache for deduplicated push

## Status

Plan only — not implemented.

## Problem

[`deduplicated_push`](push-strategies.md#deduplicated-push) plans uploads across every
opted-in destination in one go: each shared blob is uploaded to a single *home*
repository (today: the lexicographically smallest) and cross-mounted into the rest.

That assumes the full working set is known up front. In **`img deploy` persistent
worker** mode, each Bazel work request carries its own deploy manifest and is
planned independently via `prepareDedupPush`. There is no cross-request upload plan,
so:

- A single-destination request is a no-op for the upload-once path (`resolveBlobMount`
  skips when nothing else in *this* plan needs the blob).
- Concurrent or sequential work requests that share a layer can each upload it into
  their own repository.
- Cross-request savings only appear indirectly after a previous request’s manifests
  show up in `findPresentManifests`.

One-shot `img deploy` (no worker) has the full plan, but still picks homes by
alphabetical order rather than by arrival / operation order.

## Goal

One mechanism that:

1. Works when destinations arrive **incrementally** (persistent worker).
2. Is reused for **one-shot** deploy, replacing alphabetical home selection with
   “first repo that comes along.”
3. Keeps the existing phase shape: finish this request’s blob upload work, *then*
   mount and push manifests — no waiting on another request’s future completion.

## Core idea: process-wide blob location cache

Own one shared cache for the process (worker lifetime, or one-shot deploy lifetime):

```text
BlobLocationCache

  present:  (registry, digest) → home repository
            // this process knows that repository holds the blob

  inflight: (registry, digest) → home repository
            // some request chose this home and is uploading (or will);
            // peers mount from the same home and also enqueue that upload
```

Upload ownership is keyed by `(registry, digest)`, not per repository, so two
requests cannot pick different homes for the same blob. The value names the home
others should mount from (and co-upload to).

Mounts still never cross registries — every decision stays inside one registry, as
today.

## Inflight: co-upload, do not wait

Seeing an `inflight` entry must **not** block on another request finishing.

Instead:

1. Reuse that entry’s home repository as the mount source.
2. Schedule the same upload `(home repo, digest)` in **this** request’s pre-mount
   upload phase.
3. Rely on go-containerregistry’s per-`(registry, repository, digest)` deduplication
   so concurrent uploaders to the same home share one real upload (extra callers
   join / `HEAD` rather than re-transfer bytes).

Ordering stays local and phase-shaped:

```text
resolve/claim → enqueue this request’s home uploads → upload phase → mount / push manifests
```

There are no waiter channels, completion barriers, or “await something that may
happen eventually” edges. Cancellation and deadlock concerns from a waiter design
do not apply.

## Resolve / claim protocol

For each needed `(registry, digest)` among opted-in push / `registry_tag` operations:

1. **`present` hit** → mount from that home; do **not** enqueue an upload.
2. **`inflight` hit** → mount from that home; **enqueue upload** to the same home in
   this request’s upload phase (ggcr coalesces with peers).
3. **Else claim** → home = first destination in this request that needs the blob
   (“first repo that comes along”); insert `inflight[reg,digest]=home`; enqueue
   upload to home; other destinations in this request mount from home.

After this request’s uploads succeed, write `present` and clear `inflight` for those
digests so later requests can skip the upload enqueue entirely.

If a claim’s upload fails: remove `inflight` (if this request still owns the claim
and nothing else promoted it) and fail the request as today. A peer that co-uploaded
successfully may still set `present`.

### Seeding `present`

Also seed from existing cheap signals (same trust model as today’s mount kinds):

| Source | When | Trust |
|--------|------|--------|
| Successful upload by this process (claim or co-upload) | after upload phase | **mount-only** |
| `findPresentManifests` → layers of a present manifest | per request, as today | **soft** (inference; byte-upload fallback) |
| Upstream `LayerBlob.Sources` (shallow base) | per layer, as today | **soft** |
| Optional blob `HEAD` | if added later | soft or mount-only depending on who checked |

Keep the soft vs mount-only split: inferred sources keep the ordinary byte-upload
fallback; process-owned uploads stay mount-only (mount refused ⇒ fail loud).

### Mount source priority

1. `present` (process-known) → mount only  
2. `inflight` → mount from that home **and** enqueue upload to that home  
3. Manifest-confirmed repos from `findPresentManifests` (and seed `present`)  
4. Upstream `LayerBlob.Sources`  
5. `Settings.BlobRepository` (build-time staging)  
6. **Claim** first needing repo in this request as home  

Drop alphabetical `smallestRepository` for home selection.

## Persistent worker behavior

```text
Request A (repo/foo needs layer L)     Request B (repo/bar needs L), concurrent
  claim home=foo                         inflight hit → home=foo
  upload foo/L                           upload foo/L  (ggcr dedups with A's upload)
  mount / push foo                       mount foo→bar, push bar
```

- B never waits on A’s completion.
- B only mounts after **B’s** upload phase, which includes `foo/L`, so the mount
  source is expected to be ready from B’s point of view.
- Sequential case: A finishes and promotes to `present`; B only mounts (step 1).

Wire the cache on `deployWorkerHandler` (same lifetime as the shared pusher and CAS
blob cache).

### Single-destination requests

A lone opted-in destination **still claims** (or co-uploads on `inflight`). The old
“nothing to mount into ⇒ skip” rule made the first worker request invisible to later
ones. Claiming publishes the home process-wide so the next request can mount instead
of uploading into its own repository.

## One-shot unification

Use the same cache type, local to the deploy:

- Build the working set in manifest / operation order (already deterministic).
- Home = first needing repo in that order via the same claim path — not alphabetical.
- Within one prepare, `inflight` co-upload mainly matters if uploads overlap; the
  usual “upload phase then manifest push” shape still produces one upload per
  `(registry, digest)` then mounts.

Worker and one-shot share resolve / claim / upload / promote instead of two policies.

## Lifecycle sketch

```text
prepareDedupPush(..., cache *BlobLocationCache):
  working = dedupWorkingSet(...)
  presentManifests = findPresentManifests(...)  // seed cache.present from layer digests
  for each (registry, digest) needed (stable order):
      mount = cache.ResolveOrClaim(registry, digest, needingReposInOrder, ...)
  uploads = set of (homeRepo, digest) from claims and inflight co-uploads
  uploadDedupBlobs(...)                         // ggcr dedups concurrent same tuples
  on success: promote those digests to present, clear inflight
  build CrossMountPlan (sources + mountOnly) as today
  return views
```

Dedupe the upload set in our plan as well so we do not schedule the same
`(home, digest)` twice before ggcr sees it.

## Interactions with existing settings

- **`forbid_layer_push`** — never claim an upload; only resolve from `present` /
  confirmed / upstream / staging.
- **Ops that did not opt in** — still excluded from the working set; they must not
  become mount sources for opted-in ops, and should not populate `present` unless
  explicitly desired (default: only seed from opted-in prep and this process’s
  claimed / co-uploaded successes).
- **`--sink`** — strategy off, as today; cache unused.
- **`bes` / `cas_registry`** — still rejected with deduplicated push.
- **CAS read cache** — unchanged; still download-side only. Cross-mounted layers
  continue to avoid reads entirely when mounts succeed.

## Reporting

Extend the deduplicated-push stderr line with counts such as:

- from process `present` cache  
- co-uploaded via `inflight` (same home as a peer)  
- claimed uploads  
- plus today’s confirmed / upstream / mounted / skipped figures  

## Out of scope

- Persisting the cache across worker process restarts (registry / manifest checks
  refill after restart).
- Cross-registry mounts.
- Config blob dedup (still per-image / in-memory in go-containerregistry).
- Replacing the local CAS read cache.

## Suggested rollout

1. Introduce `BlobLocationCache` with claim / co-upload / promote unit tests
   (concurrent claimers, failed claim clearing, sequential `present` hit).
2. Teach `planDedupPush` / `resolveBlobMount` to take the cache and an ordered
   needing list; remove alphabetical home selection.
3. Always claim for opted-in single-destination requests; seed from manifest
   presence.
4. Plumb the cache through `deployWorkerHandler` and one-shot `DeployProcess`.
5. Registry integration tests:
   - two sequential work-request-shaped prepares sharing a layer → second is
     present-only;
   - two concurrent prepares → one home, both enqueue upload to that home, both
     succeed;
   - one-shot multi-repo → first operation’s repository is home.

## Net effect

Worker mode deduplicates across requests via process memory and co-scheduled uploads
to a shared home; one-shot uses the same “first home wins” rule; alphabetical global
planning is no longer required; and the only ordering constraint remains
per-request: upload work before mount.
