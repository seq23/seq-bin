This PR covers the deletes in the 22 Nov 2026 engineering sweep's **Not swept** list. Each one is now held to three cases: abuse, data loss and outage. Three of them were real bugs and are fixed here. The other sites were already correct, and they now have tests that prove it.

## Fixed
- **Almanac refresh (`spirit/almanac_import.ts`)**
  - The scoped `DELETE` used to run on its own, and then the inserts ran in separate 50-row batches. A failure part-way through lost the old copy.
  - The delete and the inserts are now one batch, which is one transaction.
  - A paste over `MAX_IMPORT_EVENTS` (500) is refused before anything is deleted. Two years of real data is under 100.
- **Contribution removal (`routes/spirit.ts:995`)**
  - The row used to be deleted first and audited afterwards. If the audit insert failed, the entry was gone with no trace.
  - The delete and the audit row now go in one batch, using `auditStatement`, which is new in `lib/audit.ts`. `audit()` now uses it too.
- **Vault restore (`routes/vault.ts`)**
  - A `replace` that carried zero rows used to wipe every table it named.
  - It is now refused with a 422, and nothing is written.

## Proven as they were (no code change)
- **Practice routes:** un-tick and gate reset are scoped to one key or gate and today. A bad key or gate name is a 400 and deletes nothing.
- **Vault restore:**
  - A forged table name is ignored.
  - A replace that fails mid-way rolls back fully.
- **Vault prune:** a failed bucket delete keeps the row complete.
- **Secret hand-off expiry:** only expired rows go.

A failing write in these tests is a real D1 failure: a `RAISE(ABORT)` trigger, dropped after each test.

## Mutation proof
Mutations (each undone after; log in the session scratchpad)
| # | Mutation | Red test |
|---|---|---|
| M1 | almanac delete run outside the batch | a refresh that fails part-way leaves the old copy exactly as it was |
| M2 | almanac cap removed | a paste larger than any real almanac is refused before anything is deleted |
| M3 | contribution delete unbatched from its audit | if the audit record cannot be written, the entry stays |
| M4 | empty replace allowed | a replace that carries no rows is refused and wipes nothing |
| M5 | restore run statement by statement | a replace whose write fails part-way leaves every table as it was |
| M6 | hand-off expiry `<` → `>` | removes only the hand-offs past their expiry |
| M7 | un-tick not scoped to today | un-ticking takes that one item today |
| M8 | gate reset not scoped to the gate | resetting one gate leaves the other gates and earlier days alone |
| M9 | prune swallows the bucket error | a prune whose bucket delete fails keeps the snapshot complete |

## Tests run locally
- `tsc --noEmit`
- `tests/boss/deletesHoldUnderFailure.test.ts`: 12 tests
- `tests/boss/spirit.test.ts`: 46
- `tests/boss/vault.test.ts`: 11

## Not in this PR
- The 12 deletes in the chassis's `src/worker/services/*` are handled by the chassis-removal PR (sweep row 11).

## Review fixes (F1-F3, S1-S4), each fix undone and its test red
| Mutation | Red test |
|---|---|
| M10 F1: rows-written check removed (vault.ts) | rows that fit no column are refused; one unfit table beside a writable one is refused; forged table name |
| M11 F2: vault_restores record + audit run after the batch | a replace whose record cannot be written leaves every table as it was |
| M12 F3: almanac audit after the batch | a refresh whose audit row cannot be written leaves the old copy whole |
| M13 S1: audit on every delete, no 404 | a double tap records one removal, not two |
| M14 S3: span cap removed | a refresh spanning far beyond the horizon is refused |
| M15 S4: file deleted before the record | a prune whose record cannot be updated never deletes a complete snapshot's file; a half-done prune leaves no complete row and the next prune finishes it |

- **S2:** `replaced` is now the DELETE's own `meta.changes`, and the audit row reads it with `changes()` inside the batch. Pinned by "a refresh records what it replaced" (0 then 2). A COUNT read beforehand gives the same number when nothing runs at the same time, so no single-threaded mutation turns this red.
- **Behaviour change:** a replace that would write nothing is now refused (422), including the forged-table-name case, which used to return 201 having written nothing.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01CJ98gQuotzmQekevoSTPiy



