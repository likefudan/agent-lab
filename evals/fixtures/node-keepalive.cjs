// Promptfoo 0.121.19 schedules its final process.exit() on an unreferenced
// timer. Node 26 can otherwise terminate a successful CLI command with status
// 13 for an unsettled top-level await. This referenced handle survives only
// until Promptfoo's own 100 ms shutdown exit executes.
setInterval(() => {}, 1000);
