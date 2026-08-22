/**
 * seeker-parity.ts
 *
 * The Seeker app builds its instructions with `accountsStrict`, which means a
 * single renamed or reordered account is a runtime failure on a user's phone
 * rather than a compile error. This suite pins the app's account shapes to the
 * program's own IDL so that drift is caught here instead of there.
 *
 * It is deliberately static: it needs no validator, no wallet and no React
 * runtime, so it runs in the same pass as the on-chain suite and cannot be
 * skipped by an environment that lacks the mobile toolchain.
 */
import { expect } from "chai";
import * as fs from "fs";
import * as path from "path";

const ROOT = path.join(__dirname, "..");
const PROGRAM_IDL = path.join(ROOT, "target/idl/quid.json");
const SEEKER_IDL  = path.join(ROOT, "seeker/constants/quid.json");
const HOOK        = path.join(ROOT, "seeker/hooks/useStockExposure.ts");

const camel = (s: string) => s.replace(/_([a-z])/g, (_, c) => c.toUpperCase());

/** Account keys passed to the `accountsStrict({...})` that follows `.method(` */
function accountsFor(src: string, method: string): string[] {
  const at = src.indexOf(`.${method}(`);
  expect(at, `${method} is never called by the app`).to.be.greaterThan(-1);
  const open = src.indexOf("accountsStrict({", at);
  expect(open, `${method} does not use accountsStrict`).to.be.greaterThan(-1);

  let depth = 0, i = src.indexOf("{", open), end = i;
  for (; i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) { end = i; break; }
  }
  return src.slice(open, end)
    .split("\n").slice(1)
    .map(l => l.trim())
    // Object literals here mix `name: value` with `name,` shorthand.
    .filter(l => /^[A-Za-z][A-Za-z0-9]*\s*[:,]/.test(l))
    .map(l => l.split(/[:,]/)[0].trim());
}

describe("Seeker ↔ program parity", () => {
  const program = JSON.parse(fs.readFileSync(PROGRAM_IDL, "utf8"));
  const seeker  = JSON.parse(fs.readFileSync(SEEKER_IDL, "utf8"));
  const hook    = fs.readFileSync(HOOK, "utf8");

  it("P.1 The app ships the program's own IDL, not a stale copy", () => {
    expect(seeker.address).to.equal(program.address);
    expect(JSON.stringify(seeker)).to.equal(JSON.stringify(program));
    console.log("  ✓ IDL identical, program", program.address);
  });

  it("P.2 The app calls only instructions the program still exposes", () => {
    const exposed = new Set(program.instructions.map((i: any) => camel(i.name)));
    const called = [...hook.matchAll(/program\.methods\s*\n?\s*\.([a-zA-Z0-9]+)\(/g)]
      .map(m => m[1]);
    expect(called.length, "app calls no instructions at all").to.be.greaterThan(0);
    for (const c of called) expect(exposed.has(c), `app calls removed instruction ${c}`).to.be.true;
    console.log("  ✓ App calls:", [...new Set(called)].join(", "));
  });

  it("P.3 Every accountsStrict block names exactly the IDL's accounts", () => {
    for (const name of ["deposit", "withdraw"]) {
      const want = program.instructions
        .find((i: any) => i.name === name).accounts.map((a: any) => camel(a.name));
      const got = accountsFor(hook, camel(name));
      // Anchor resolves `accountsStrict` by name, so the set is what has to
      // match; ordering is only house style and is not asserted here.
      expect([...got].sort(), `${name} account set drifted`)
        .to.deep.equal([...want].sort());
      console.log(`  ✓ ${name}: all ${got.length} accounts present, none extra`);
    }
  });

  it("P.4 The app does not reach for instructions that are not a user's to send", () => {
    // Liquidation is permissionless keeper work, flash loans are a settlement
    // concern, and config is admin-only. None of them belong behind a tap.
    for (const forbidden of ["liquidate", "sweep", "flashBorrow", "flashRepay",
                             "initConfig", "updateConfig", "setKestrel"]) {
      expect(hook.includes(`.${forbidden}(`), `app should not call ${forbidden}`).to.be.false;
    }
    console.log("  ✓ No keeper, settlement or admin instructions in the app");
  });
});
