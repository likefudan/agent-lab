#!/usr/bin/env node
'use strict';

/**
 * Offline check that deliberate bad responses fail the documented assertions.
 * Does not call models or the network.
 */
const fs = require('fs');
const path = require('path');

const fixturePath = path.join(__dirname, 'bad-responses.json');
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

function fails(caseRow) {
  const out = caseRow.bad_output;
  switch (caseRow.assertion) {
    case 'equals':
      return out !== caseRow.expected;
    case 'contains':
      return !String(out).includes(caseRow.expected_substring);
    case 'not-contains':
      return String(out).includes(caseRow.forbidden_substring);
    default:
      throw new Error(`unknown assertion: ${caseRow.assertion}`);
  }
}

let failed = 0;
for (const row of fixture.cases) {
  const ok = fails(row) === Boolean(row.must_fail);
  if (!ok) {
    console.error(`FAIL: ${row.id} did not demonstrate assertion failure`);
    failed += 1;
  } else {
    console.log(`PASS: ${row.id} fails as expected`);
  }
}

if (failed > 0) {
  process.exit(1);
}
console.log(`verified ${fixture.cases.length} bad-response fixtures`);
