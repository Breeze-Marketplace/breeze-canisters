# identity-notifications (vendored)

A copy of [`identity-notifications`](https://github.com/dfinity/identity-notifications) 0.3.2
(Apache-2.0, Copyright 2026 DFINITY Stiftung: see `NOTICE`, copied from upstream commit
`73fd9e26b0bd1da3d1ac581208b3fe4164bbb258`), used by core to push platform alerts to staff
browsers through Internet Identity (BRE-211). The mixin is `../../mixins/Notifications.mo`. These
files are modified from upstream as listed below, and formatted with the repo's prettier.

What differs from the published package:

- **State is passed in.** The mixin takes a `State.mo` record that core holds and a core migration
  creates, because core's `--enhanced-migration` build refuses stable fields declared with initial
  values inside a mixin (M0250). Changing `State` or the types under it needs a core migration.
- **Bounded wait.** The call to II's `app_send_notification` uses `with timeout`, so a silent II
  can't block core from stopping or upgrading.
- **`notifications.origin()`** returns the configured `notification_origin`, so core can link
  notifications to its own pages.
- **Fixes** (BRE-211 review), worth sending upstream:
  - `Outbox.add` removes replaced content together with its byte count, and puts it back only if
    the replacement is refused and its notification survived shedding. Upstream subtracted the
    old size but kept the content, so `bytes` could underflow and trap.
  - Accepted entries are scheduled under `(dueAt, id)`, which doesn't change. Upstream removed
    them by `expiresAt`, which a same-key replacement changes first, leaving a stale row whose
    sweep later deleted the live replacement.
  - `NoSuchSender` parks the batch for one later attempt, like an unreachable II, instead of
    requeueing it every coalesce period until it expires.
  - A notification replaced while its batch is in flight, and then accepted, is sent again
    (`Outbox.resend`), so II gets the replacement's window.
- **`wanted` check.** The mixin takes `wanted(recipient, id)` from the app and asks it again
  before each send or retry and on each content pull, so a notification queued for someone who
  has since opted out or lost access is dropped instead of delivered. `notifications.idFor` gives
  the id a key maps to, for that check.
- **Expiry.** `Outbox.nextDue` includes the earliest accepted expiry, so an idle outbox still
  sweeps, and a pull or report for an expired notification is refused even before the sweep.
- `notification_sender` / `notification_origin` are read with `Runtime.envVar` as before; set
  them on `backend` in `icp.yaml`.

To take a newer upstream version, diff its `motoko/src/` against this folder and the mixin, and
keep the changes above.
