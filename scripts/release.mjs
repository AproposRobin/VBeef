#!/usr/bin/env node
// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
//
// The release side of the VisualBeef updater (docs/Releasing.md). Node 24, built-in crypto only (Ed25519).
//
//   node scripts/release.mjs keygen [--out <private-key-file>]
//       New Ed25519 key pair. Default <out>: VB_RELEASE_KEY, else %USERPROFILE%\.visualbeef\vb-release-signing.key (the
//       public key goes next to it
//       as <out>.pub). Refuses to overwrite a key and refuses a path inside the repository. Prints the public key to
//       paste into VisualBeefCore/src/Update/ReleaseKeys.bf.
//   node scripts/release.mjs public [--key <private-key-file>]
//       Prints the base64 public key of a private key.
//   node scripts/release.mjs sign --tag <tag> [--key <file>] [--dir <folder>] [--channel stable|preview]
//                                 [--sequence <n>] [--version <v>] [--notes-file <file>] [--out <release.json>]
//       Builds release.json from the packaged files and signs it. Without --dir the files are downloaded from the
//       (draft) GitHub release of <tag> into a scratch folder. The version defaults to the one in CommandLine.bf
//       (<Version>-<Channel>); the sequence to one above the highest sequence already published. Warns when there is
//       no passed smoke report for the full win64 zip yet.
//   node scripts/release.mjs publish --tag <tag> [--file <release.json>] [--create --dir <folder>]
//                                    [--smoke-report <file> | --force-unsmoked "<reason>"]
//       Checks release.json (signature against ReleaseKeys.bf, tag, the release's file sizes), uploads it to the
//       release of <tag>, and publishes the release (draft off; pre-release on for the preview channel, off and
//       marked latest for stable). --create makes the release first and uploads the packages from <folder>.
//       REFUSES without a passed, complete release smoke report (scripts/release-smoke.ps1) for the SHA-256 of the
//       full win64 zip: build/smoke/smoke-<first 12 hex>.json, or the file given with --smoke-report. The documented
//       escape is --force-unsmoked "<reason>": it publishes anyway and writes the reason into the release notes.
//   node scripts/release.mjs verify <release.json> [--dir <folder>] [--keys <base64;...>]
//       Checks a descriptor's signature (default keys: ReleaseKeys.bf) and, with --dir, the files' sizes and hashes.
//   node scripts/release.mjs vectors
//       Prints the test vector the `update` test suite carries (fixed TEST seed, never a real key).
//
// Environment: VB_RELEASE_REPO (default AproposRobin/VBeef), GH (path of gh, default "gh").

import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, sign, verify } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const keysFile = path.join(repoRoot, "VisualBeefCore", "src", "Update", "ReleaseKeys.bf");
const infoFile = path.join(repoRoot, "VisualBeefCore", "src", "Document", "CommandLine.bf");
const ghRepo = process.env.VB_RELEASE_REPO || "AproposRobin/VBeef";
const gh = process.env.GH || "gh";
export const DOMAIN = "visualbeef-release-v1";

function fail(message) {
  console.error(`release: ${message}`);
  process.exit(1);
}

function args(list) {
  const out = { _: [] };
  for (let i = 0; i < list.length; i++) {
    const a = list[i];
    if (a.startsWith("--")) {
      const name = a.slice(2);
      if (["create", "force"].includes(name)) out[name] = true;
      else {
        if (i + 1 >= list.length) fail(`${a} needs a value`);
        out[name] = list[++i];
      }
    } else out._.push(a);
  }
  return out;
}

function defaultKeyPath() {
  if (process.env.VB_RELEASE_KEY) return process.env.VB_RELEASE_KEY;
  return path.join(os.homedir(), ".visualbeef", "vb-release-signing.key");
}

function insideRepo(file) {
  const rel = path.relative(repoRoot, path.resolve(file));
  return !rel.startsWith("..") && !path.isAbsolute(rel);
}

export function loadPrivateKey(file) {
  let key;
  try {
    key = createPrivateKey(readFileSync(file));
  } catch (e) {
    fail(`cannot read the private key ${file}: ${e.message}`);
  }
  if (key.asymmetricKeyType !== "ed25519") fail(`${file} is a ${key.asymmetricKeyType} key, not Ed25519`);
  return key;
}

export function publicKeyBase64(privateKey) {
  return createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32).toString("base64");
}

/** The keys compiled into the editor (ReleaseKeys.bf), base64, or [] when the constant is empty. */
export function compiledKeys() {
  const m = /public const String Keys = "([^"]*)";/.exec(readFileSync(keysFile, "utf8"));
  if (!m) fail(`no Keys constant in ${keysFile}`);
  return m[1].split(/[;,\s]+/).filter(Boolean);
}

function keyObjectFromBase64(pub) {
  const raw = Buffer.from(pub, "base64");
  if (raw.length !== 32) fail(`'${pub}' is not a base64 32-byte Ed25519 public key`);
  const der = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]);
  return createPublicKey({ key: der, format: "der", type: "spki" });
}

/** A private key from a 32-byte seed (tests only). */
export function keyFromSeed(seed) {
  const der = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  return createPrivateKey({ key: der, format: "der", type: "pkcs8" });
}

function ordinal(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

/** The exact text the editor verifies (ReleaseDescriptor.CanonicalText). */
export function canonical(d) {
  for (const f of [d.product, d.version, d.channel, d.tag, d.publishedAt]) {
    if (typeof f !== "string" || /[\r\n\0]/.test(f)) fail("a signed field is missing or spans several lines");
  }
  let text = `${DOMAIN}\nproduct=${d.product}\nversion=${d.version}\nchannel=${d.channel}\nsequence=${d.sequence}\ntag=${d.tag}\npublishedAt=${d.publishedAt}\n`;
  const assets = [...d.assets].sort((x, y) => ordinal(x.platform, y.platform));
  for (const a of assets) text += `asset=${a.platform} ${a.name} ${a.size} ${a.sha256}\n`;
  return text;
}

export function signDescriptor(d, privateKey) {
  const { signature, ...fields } = d;
  return { ...fields, signature: sign(null, Buffer.from(canonical(fields), "utf8"), privateKey).toString("base64") };
}

export function verifyDescriptor(d, keys) {
  if (!d.signature) return false;
  const sig = Buffer.from(d.signature, "base64");
  if (sig.length !== 64) return false;
  const text = Buffer.from(canonical(d), "utf8");
  return keys.some((k) => verify(null, text, keyObjectFromBase64(k), sig));
}

const SAFE = /^[A-Za-z0-9._+-]{1,128}$/;

function readVersion() {
  const t = readFileSync(infoFile, "utf8");
  const v = /public const String Version = "([^"]+)";/.exec(t);
  const c = /public const String Channel = "([a-z0-9]+)";/.exec(t);
  if (!v || !c) fail(`VisualBeefInfo.Version / Channel not found in ${infoFile}`);
  return { version: v[1], channel: c[1] };
}

/** Which platform a package file is, from its name (scripts/package.ps1, scripts/package_linux.sh). */
export function platformOf(name, version, productChannel) {
  const full = `${version}-${productChannel}`;
  if (name === `VisualBeef-${version}-win64.zip`) return "win64";
  if (name === `VisualBeef-${full}-win64.zip`) return "win64-minimal";
  if (name === `VisualBeef-${full}-x86_64.AppImage`) return "linux-x86_64-appimage";
  if (name === `VisualBeef-${full}-linux64.tar.gz`) return "linux-x86_64";
  return null;
}

function sha256File(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function collectAssets(dir, version, productChannel) {
  const assets = [];
  for (const name of readdirSync(dir).sort()) {
    const platform = platformOf(name, version, productChannel);
    if (!platform) continue;
    const file = path.join(dir, name);
    const sha256 = sha256File(file);
    const side = `${file}.sha256`;
    if (existsSync(side)) {
      const listed = readFileSync(side, "utf8").trim().split(/\s+/)[0].toLowerCase();
      if (listed !== sha256) fail(`${name}: the .sha256 file says ${listed}, the file hashes to ${sha256}`);
    }
    assets.push({ platform, name, size: statSync(file).size, sha256 });
  }
  if (assets.length === 0) fail(`no VisualBeef ${version} package in ${dir} (expected names from scripts/package.ps1 / package_linux.sh)`);
  return assets;
}

function ghRun(argv, opts = {}) {
  try {
    return execFileSync(gh, argv, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"], ...opts });
  } catch (e) {
    fail(`gh ${argv.join(" ")} failed${e.status !== undefined ? ` (exit ${e.status})` : `: ${e.message}`}`);
  }
}

/** The highest sequence among published release.json files of the repository (0 when none). */
function highestPublishedSequence(exceptTag) {
  const list = JSON.parse(ghRun(["release", "list", "--repo", ghRepo, "--limit", "100", "--json", "tagName,isDraft"]));
  let highest = 0;
  const scratch = mkdtempSync(path.join(os.tmpdir(), "vb-release-seq-"));
  try {
    for (const r of list) {
      if (r.isDraft || r.tagName === exceptTag) continue;
      const dir = path.join(scratch, r.tagName.replace(/[^A-Za-z0-9._+-]/g, "_"));
      mkdirSync(dir);
      try {
        execFileSync(gh, ["release", "download", r.tagName, "--repo", ghRepo, "--pattern", "release.json", "--dir", dir], { stdio: "ignore" });
      } catch {
        continue; // a release without a descriptor
      }
      const f = path.join(dir, "release.json");
      if (!existsSync(f)) continue;
      const seq = Number(JSON.parse(readFileSync(f, "utf8")).sequence);
      if (Number.isInteger(seq) && seq > highest) highest = seq;
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return highest;
}

/** The SHA-256 of the full win64 zip, the artifact the release smoke pass runs on (null when there is none). */
export function smokeTarget(assets) {
  const a = assets.find((x) => x.platform === "win64");
  return a ? { name: a.name, sha256: a.sha256 } : null;
}

/** Looks for the smoke report of a zip: build/smoke/smoke-<sha12>.json, or an explicit file. */
export function smokeStatus(target, explicit) {
  if (!target) return { ok: false, why: "the release has no full win64 zip to smoke-test" };
  const file = explicit ? path.resolve(explicit) : path.join(repoRoot, "build", "smoke", `smoke-${target.sha256.slice(0, 12)}.json`);
  if (!existsSync(file)) return { ok: false, file, why: `no smoke report for ${target.name} (${target.sha256.slice(0, 12)}); run scripts/release-smoke.ps1 on it` };
  let r;
  try {
    r = JSON.parse(readFileSync(file, "utf8").replace(/^﻿/, ""));
  } catch (e) {
    return { ok: false, file, why: `cannot read the smoke report ${file}: ${e.message}` };
  }
  if (!r.zip || String(r.zip.sha256).toLowerCase() !== target.sha256) return { ok: false, file, why: `${file} is a report for another file (${r.zip && r.zip.sha256}), not ${target.name} (${target.sha256})` };
  if (r.complete !== true) return { ok: false, file, why: `${file} is a partial run (complete=false)` };
  if (r.passed !== true) return { ok: false, file, why: `${file}: the smoke pass FAILED (${(r.failures || []).length} failure(s))` };
  return { ok: true, file, report: r };
}

function cmdKeygen(o) {
  const out = path.resolve(o.out || defaultKeyPath());
  if (insideRepo(out)) fail(`refusing to write a private key inside the repository (${out})`);
  if (existsSync(out) || existsSync(`${out}.pub`)) fail(`${out} or its .pub exists; refusing to overwrite a signing key`);
  mkdirSync(path.dirname(out), { recursive: true });
  const { privateKey } = generateKeyPairSync("ed25519");
  writeFileSync(out, privateKey.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
  const pub = publicKeyBase64(privateKey);
  writeFileSync(`${out}.pub`, `${pub}\n`);
  console.log(`Private key: ${out}  (keep it offline and backed up; it never goes into a repository)`);
  console.log(`Public key:  ${pub}  (also in ${out}.pub)`);
  console.log(`Next: paste the public key into ${path.relative(repoRoot, keysFile)} (the Keys constant) and commit.`);
}

function cmdSign(o) {
  if (!o.tag || !SAFE.test(o.tag)) fail("sign needs --tag <tag> (for example v0.2.0)");
  const channel = o.channel || "stable";
  if (!["stable", "preview"].includes(channel)) fail("--channel is stable or preview");
  const info = readVersion();
  const version = o.version || `${info.version}-${info.channel}`;
  if (!SAFE.test(version)) fail(`'${version}' is not a valid version`);
  const coreVersion = version.split("-")[0];
  const productChannel = version.includes("-") ? version.slice(version.indexOf("-") + 1) : info.channel;
  const key = loadPrivateKey(o.key || defaultKeyPath());
  const pub = publicKeyBase64(key);
  const compiled = compiledKeys();
  if (!compiled.includes(pub) && !o.force) {
    fail(compiled.length === 0
      ? `ReleaseKeys.bf trusts no key yet: paste ${pub} into it, commit, and build the release from that commit (or pass --force to sign anyway)`
      : `this key (${pub}) is not in ReleaseKeys.bf, so released editors would refuse the descriptor (--force signs anyway)`);
  }
  let dir = o.dir;
  let scratch = null;
  if (!dir) {
    scratch = mkdtempSync(path.join(os.tmpdir(), "vb-release-"));
    dir = scratch;
    console.log(`Downloading the packages of ${o.tag} from ${ghRepo} ...`);
    ghRun(["release", "download", o.tag, "--repo", ghRepo, "--dir", dir, "--pattern", "*.zip", "--pattern", "*.AppImage", "--pattern", "*.tar.gz", "--pattern", "*.sha256"]);
  }
  try {
    const assets = collectAssets(dir, coreVersion, productChannel);
    let sequence;
    if (o.sequence !== undefined) {
      sequence = Number(o.sequence);
      if (!Number.isInteger(sequence) || sequence < 1) fail("--sequence must be a whole number above 0");
    }
    const highest = o.sequence !== undefined && o.force ? 0 : highestPublishedSequence(o.tag);
    if (sequence === undefined) sequence = highest + 1;
    if (sequence <= highest) fail(`sequence ${sequence} is not above the highest published one (${highest}); editors would never offer it`);
    let notes = "";
    if (o["notes-file"]) notes = readFileSync(o["notes-file"], "utf8").trim();
    const descriptor = signDescriptor({
      format: 1,
      product: "VisualBeef",
      version,
      channel,
      sequence,
      tag: o.tag,
      publishedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
      assets,
      notes,
    }, key);
    if (!verifyDescriptor(descriptor, [pub])) fail("the new signature does not verify (internal error)");
    const smoke = smokeStatus(smokeTarget(assets), null);
    if (!smoke.ok) {
      console.error(`release: WARNING: ${smoke.why}`);
      console.error("release: 'publish' will refuse until a passed smoke report exists (docs/Releasing.md), unless --force-unsmoked is used.");
    }
    const out = path.resolve(o.out || "release.json");
    writeFileSync(out, `${JSON.stringify(descriptor, null, 2)}\n`);
    console.log(`Wrote ${out}: VisualBeef ${version}, channel ${channel}, sequence ${sequence}, ${assets.length} files:`);
    for (const a of assets) console.log(`  ${a.platform.padEnd(22)} ${a.name}  ${a.size} bytes  ${a.sha256}`);
  } finally {
    if (scratch) rmSync(scratch, { recursive: true, force: true });
  }
}

function readDescriptor(file) {
  let d;
  try {
    d = JSON.parse(readFileSync(file, "utf8"));
  } catch (e) {
    fail(`cannot read ${file}: ${e.message}`);
  }
  if (d.format !== 1 || d.product !== "VisualBeef" || !Array.isArray(d.assets)) fail(`${file} is not a VisualBeef release descriptor`);
  return d;
}

function cmdVerify(o) {
  const file = o._[0] || "release.json";
  const d = readDescriptor(file);
  const keys = o.keys ? o.keys.split(/[;,\s]+/).filter(Boolean) : compiledKeys();
  if (keys.length === 0) fail("no keys to check against (ReleaseKeys.bf is empty; pass --keys)");
  if (!verifyDescriptor(d, keys)) fail(`${file}: the signature does not verify against ${keys.join(", ")}`);
  console.log(`${file}: signature OK (VisualBeef ${d.version}, ${d.channel}, sequence ${d.sequence}, tag ${d.tag})`);
  if (o.dir) {
    for (const a of d.assets) {
      const f = path.join(o.dir, a.name);
      if (!existsSync(f)) fail(`${a.name} is not in ${o.dir}`);
      if (statSync(f).size !== a.size || sha256File(f) !== a.sha256) fail(`${a.name}: size or SHA-256 differs from the descriptor`);
      console.log(`  ${a.name}: size and SHA-256 OK`);
    }
  }
}

function cmdPublish(o) {
  if (!o.tag || !SAFE.test(o.tag)) fail("publish needs --tag <tag>");
  const file = path.resolve(o.file || "release.json");
  const d = readDescriptor(file);
  if (d.tag !== o.tag) fail(`${file} is for tag ${d.tag}, not ${o.tag}`);
  const keys = compiledKeys();
  if (keys.length === 0 && !o.force) fail("ReleaseKeys.bf trusts no key: editors built from this tree would refuse every release (--force publishes anyway)");
  if (keys.length > 0 && !verifyDescriptor(d, keys)) fail(`${file}: the signature does not verify against ReleaseKeys.bf`);
  // The owner's rule: nothing is published without a passed smoke pass on the exact zip that ships.
  const smoke = smokeStatus(smokeTarget(d.assets), o["smoke-report"]);
  let unsmokedNote = "";
  if (smoke.ok) {
    console.log(`Smoke report OK: ${smoke.file} (${smoke.report.zip.name} ${smoke.report.zip.sha256.slice(0, 12)}, ${smoke.report.finishedAt})`);
  } else if (o["force-unsmoked"] !== undefined) {
    const reason = String(o["force-unsmoked"]).trim();
    if (reason.length < 8) fail("--force-unsmoked needs a real reason (at least 8 characters)");
    unsmokedNote = `

---
Published without the release smoke pass (${smoke.why}). Reason: ${reason}`;
    console.error(`release: WARNING: publishing unsmoked: ${smoke.why}. The reason goes into the release notes.`);
  } else {
    fail(`refusing to publish: ${smoke.why}. Run scripts/release-smoke.ps1 -Tag ${o.tag} (a passed report for the zip's SHA-256 under build/smoke/, or --smoke-report <file>), or --force-unsmoked "<reason>" (written into the release notes).`);
  }
  if (unsmokedNote) d.notes = `${d.notes || `VisualBeef ${d.version}`}${unsmokedNote}`;
  if (o.create) {
    if (!o.dir) fail("--create needs --dir <folder with the packages>");
    const files = d.assets.map((a) => path.join(o.dir, a.name));
    for (const a of d.assets) {
      const f = path.join(o.dir, a.name);
      if (!existsSync(f) || statSync(f).size !== a.size || sha256File(f) !== a.sha256) fail(`${a.name} in ${o.dir} does not match the descriptor`);
      if (existsSync(`${f}.sha256`)) files.push(`${f}.sha256`);
    }
    ghRun(["release", "create", o.tag, "--repo", ghRepo, "--verify-tag", "--draft", "--prerelease", "--title", `VisualBeef ${d.version}`, "--notes", d.notes || `VisualBeef ${d.version}`, ...files]);
  }
  const view = JSON.parse(ghRun(["release", "view", o.tag, "--repo", ghRepo, "--json", "assets,isDraft,isPrerelease"]));
  for (const a of d.assets) {
    const onRelease = view.assets.find((x) => x.name === a.name);
    if (!onRelease) fail(`${a.name} is not on the release ${o.tag}`);
    if (onRelease.size !== a.size) fail(`${a.name} on the release has ${onRelease.size} bytes, the descriptor says ${a.size}`);
  }
  // The asset must be called release.json whatever the local file is called.
  const tmp = mkdtempSync(path.join(os.tmpdir(), "vb-release-up-"));
  try {
    const named = path.join(tmp, "release.json");
    writeFileSync(named, unsmokedNote ? `${JSON.stringify(d, null, 2)}
` : readFileSync(file)); // notes are not signed
    ghRun(["release", "upload", o.tag, named, "--repo", ghRepo, "--clobber"]);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
  const edit = ["release", "edit", o.tag, "--repo", ghRepo, "--draft=false"];
  if (d.channel === "preview") edit.push("--prerelease=true");
  else edit.push("--prerelease=false", "--latest");
  if (d.notes) edit.push("--notes", d.notes);
  ghRun(edit);
  console.log(`Published ${o.tag}: release.json uploaded, ${d.channel === "preview" ? "pre-release" : "latest release"}.`);
}

function cmdVectors() {
  const seed = Buffer.alloc(32);
  for (let i = 0; i < 32; i++) seed[i] = i + 1; // TEST seed 01..20, never a real key
  const key = keyFromSeed(seed);
  const d = signDescriptor({
    format: 1,
    product: "VisualBeef",
    version: "0.2.0-alpha",
    channel: "stable",
    sequence: 7,
    tag: "v0.2.0",
    publishedAt: "2026-10-12T10:00:00Z",
    assets: [
      { platform: "win64", name: "VisualBeef-0.2.0-win64.zip", size: 1234567, sha256: "a".repeat(64) },
      { platform: "linux-x86_64-appimage", name: "VisualBeef-0.2.0-alpha-x86_64.AppImage", size: 7654321, sha256: "b".repeat(64) },
      { platform: "win64-minimal", name: "VisualBeef-0.2.0-alpha-win64.zip", size: 1000, sha256: "c".repeat(64) },
    ],
    notes: "Test notes",
  }, key);
  console.log(JSON.stringify({ publicKey: publicKeyBase64(key), descriptor: d }, null, 2));
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  const [command, ...rest] = process.argv.slice(2);
  const o = args(rest);
  switch (command) {
    case "keygen": cmdKeygen(o); break;
    case "public": console.log(publicKeyBase64(loadPrivateKey(o.key || o._[0] || defaultKeyPath()))); break;
    case "sign": cmdSign(o); break;
    case "publish": cmdPublish(o); break;
    case "verify": cmdVerify(o); break;
    case "vectors": cmdVectors(); break;
    default:
      console.error("usage: node scripts/release.mjs keygen|public|sign|publish|verify|vectors [options] (see the top of this file)");
      process.exit(2);
  }
}
