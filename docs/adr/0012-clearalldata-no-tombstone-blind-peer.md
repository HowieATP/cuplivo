# clearAllData Writes Neither Trash Nor Tombstones

`clearAllData` is the single intentional exception to "delete writes trash". It
writes no `deleted_records` rows (the user's intent is "wipe everything";
recoverable trash would contradict that and could itself overflow the 10 MB cap
in one shot) AND no `deletion_markers` rows (sync peers never learn that this
device wiped everything). A peer that previously synced with this device will
retain orphaned conversations/assistants that the other side no longer has.

## Why

- Writing per-id tombstones for a full wipe would produce tens of thousands of
  rows in one operation, instantly blowing the 5000-row marker cap — most would
  be truncated, making the declaration inaccurate anyway.
- A sentinel "clearAll per type" tombstone was considered but rejected: it would
  require the receiver to interpret "delete all my local entities of this type
  predating this timestamp", which is a destructive remote-triggered operation
  with no per-entity confirmation — too dangerous for a community chat client.
- The user who clicks "clear all data" has explicitly opted into irrecoverable
  deletion on this device. Extending that to "also wipe peers" is a scope creep
  the user did not request.

## Consequences

- After a clearAllData on device A, device B (which synced with A before) keeps
  all conversations/assistants that A no longer has. B's user must clear them
  manually if desired.
- This must be stated in the feature's user-facing documentation so users do not
  expect clearAllData to propagate to synced peers.
- clearAllData's existing behavior (wipes all user-data tables) is unchanged;
  the two new tables are added to its DELETE list inside the existing
  transaction.