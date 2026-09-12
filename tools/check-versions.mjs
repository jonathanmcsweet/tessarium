import { readFileSync } from "node:fs";

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

const SOURCE = "ocaml/server/bin/main.ml";
const CANONICAL = /~version:"([^"]*)"/;

const found = (file, re, what) => {
  const hit = read(file).match(re);
  if (hit === null) return { file, what, missing: true };
  return { file, what, version: hit[1] };
};

const version = read(SOURCE).match(CANONICAL)?.[1];

let bad = 0;
const fail = (message) => {
  console.log(`  FAIL  ${message}`);
  bad++;
};

if (version === undefined) {
  fail(`no ~version: in ${SOURCE} -- this check has stopped checking`);
} else if (!/^\d+\.\d+\.\d+$/.test(version)) {
  fail(`${SOURCE} says "${version}", which is not a semver release`);
}

const tarball = (v) =>
  new RegExp(`tessarium-${v.replace(/\./g, "\\.")}-linux-x86_64\\.tar\\.gz`);

const claims = version === undefined ? [] : [
  found("ocaml/pmtiles/bin/main.ml", CANONICAL, "the basemap binary"),
  found("ui/package.json", /"version": "([^"]*)"/, "the dashboard"),
  found("packaging/snap/snapcraft.yaml", /^version: '([^']*)'$/m, "the snap"),
  found(
    "packaging/flatpak/io.github.tessarium.Tessarium.metainfo.xml",
    /<release version="([^"]*)"/,
    "the newest flatpak release note",
  ),
];

for (const claim of claims) {
  if (claim.missing) {
    fail(`${claim.file}  ${claim.what} has no version -- this check is stale`);
  } else if (claim.version !== version) {
    fail(
      `${claim.file}  ${claim.what} says ${claim.version}, ${SOURCE} says ${version}`,
    );
  }
}

const tarballs = version === undefined ? [] : [
  ["packaging/flatpak/io.github.tessarium.Tessarium.yml", "the flatpak build"],
  ["packaging/snap/snapcraft.yaml", "the snap build"],
];

for (const [file, what] of tarballs) {
  if (!tarball(version).test(read(file))) {
    fail(`${file}  ${what} does not consume tessarium-${version}-...`);
  }
}

console.log(
  `versions: ${version ?? "?"} from ${SOURCE}; `
    + `${claims.length + tarballs.length} places, ${bad} disagreements`,
);
process.exit(bad ? 1 : 0);
