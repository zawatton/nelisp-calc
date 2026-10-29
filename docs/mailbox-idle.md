# Mailbox idle work

The request protocol is append-only ASCII with LF or CRLF line endings.
Complete lines are acknowledged once, including tokens that raise an error;
an unfinished line is retried after the file grows. Same-size replacement is
unsupported. Truncation, including deletion of a previously read file, raises
an error instead of silently losing or replaying requests.

Polling caches the request pathname and the byte size sampled before reading.
An unchanged size avoids creating a buffer, reading, or scanning the backlog.
The cache advances only after a successful read and response publication.
An append between metadata sampling and reading can cause one extra scan;
the acknowledged line count prevents replay. This deliberately uses no
unverified partial-byte read API or core changes.

The 100 ms interval remains unchanged. With no registered adapter process and
no async timer, the mailbox calls the existing native sleep helper directly.
Otherwise it retains the general process/timer pump. Native sleep errors stay
visible. Response publication retains its bounded rename retry of the already
computed result.

Focused checks: `test/mailbox-idle-test.el` extracts definitions only, avoiding
any production entry-point switch. Run it in a fresh `NELISP_CALC_TARGET`
directory with host Emacs or the pinned standalone runtime. It covers absent
and empty files, unchanged reads, partial lines, CRLF, token errors, a metadata
sampling race, truncation, timer/process dispatch, and publication retries.
`MAILBOX_TEST_SOURCE` selects old source for the negative control.
The focused runner emits `MAILBOX-IDLE-PASS:13`; require both this exact
completion count and a zero exit code. The native CLI may also print its
returned string, so do not mistake duplicated output for additional cases.

Resource checks: `tools/idle-resource-probe.ps1 -Runtime PATH -Seconds 10
-WithHistory [-Backlog 100]`. Each run owns and cleans up its backend, waits
for the acknowledged setup count before sampling, and appends a final
clear/2/add/3/equals sequence. CPU uses one core; limits remain 5 percent,
32 MiB growth, and 512 MiB private memory. `-MailboxSource PATH` permits a
matched old-source negative control. Every run keeps its measurement and logs
under its own `target/idle-resource-*` directory, including failed runs.

The probe defaults to a three-second warmup after the setup acknowledgement,
then samples only steady idle. It records warmup duration, source/runtime
hashes, acknowledged history count, final arithmetic, exit status and stderr.

## Measurements

The exact original mailbox with fourteen Standard requests used27.789% of
one logical CPU over10s. The final candidate measured3.903% with that same
setup over10s. Earlier size-guard/pump variants failed at7.805% and5.777%.
The candidate plus100 additional backspace requests initially failed at
5.931% over10s without a separate warmup; that result is retained, rather
than reclassified as passing.

The integrated candidate was measured independently with the same114 setup
requests, a3s warmup and30.006s idle:2.239% CPU, private399.449->396.449MiB,
final display5,119 acknowledgements, exit0 and empty stderr. Limits remain
5% of one core,32MiB growth and512MiB private memory; the poll interval is
still100ms. A short steady sample is not a long-run memory-leak guarantee.

Growing request files are still scanned from the beginning when they change;
the optimization bounds unchanged idle work. Replacement, truncation and
compaction are not part of the append-only protocol. Native process/timer
pumping remains available whenever its queues are nonempty or unknown.

## Live application

The user's original session measured21.75% of one core with private429.1->
429.3MiB over8s. After the optimized mailbox was independently verified,
the session was restarted without activation. Fifteen original requests were
replayed after one startup-mode request; display2/statusok and history/memory
file hashes matched the snapshot. The replacement window remained minimized.

The actual replacement backend measured1.20% of one core over30.026s, with
private409.2->406.2MiB and16 acknowledgements. Native multi-mode interaction
also passed: UK gallons, inverse Grad, programmer remainder, implicit circle
(58segments/175rows), then Standard arithmetic5. Shared Anvil/input runtimes
were not restarted, and the immutable repaired NeLisp executable was reused.

Progress criteria and local evidence are in
`tools/ai/mailbox-idle-progress.org` and `target/mailbox-idle-*`. Target files
are ignored and unavailable in a fresh checkout. A new source checkout must
use the Windows wait repair documented in `idle-resource-fix.org`. Initial
runtime memory remains substantial; neither30s sample proves long-run
allocator retention resolved. No commit or push was performed.
