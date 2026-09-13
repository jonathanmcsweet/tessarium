import { readFileSync } from "node:fs";

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

const SEMVER = /^\d+\.\d+\.\d+$/;
const RELEASE_SOURCE = "dune-project";

let bad = 0;
const fail = (message) => {
  console.log(`  FAIL  ${message}`);
  bad++;
};

const read1 = (file, re, what) => {
  const hit = read(file).match(re);
  if (hit === null) {
    fail(`${file}  ${what} is not where this check looks -- it has stopped checking`);
    return undefined;
  }
  if (!SEMVER.test(hit[1])) {
    fail(`${file}  ${what} says "${hit[1]}", which is not a semver release`);
    return undefined;
  }
  return hit[1];
};

// The release version names every package. Nothing below may disagree with it.
const release = read1(RELEASE_SOURCE, /^\(version ([^)]*)\)/m, "the release version");

// The sections version on their own and need no parity with each other or
// with the release: only that each is a semver release someone bumped.
read1("ocaml/lib/version.ml", /^let core = "([^"]*)"/m, "the core version");
read1("ui/package.json", /"version": "([^"]*)"/, "the dashboard version");

const tarball = (v) =>
  new RegExp(`tessarium-${v.replace(/\./g, "\\.")}-linux-x86_64\\.tar\\.gz`);

const carries = [
  ["tessarium.opam", /^version: "([^"]*)"/m, "the opam package"],
  ["ocaml/server/bin/main.ml", /~version:"([^"]*)"/, "tessarium-server --version"],
  ["ocaml/pmtiles/bin/main.ml", /~version:"([^"]*)"/, "tessarium-basemap --version"],
  ["packaging/snap/snapcraft.yaml", /^version: '([^']*)'$/m, "the snap"],
  [
    "packaging/flatpak/io.github.tessarium.Tessarium.metainfo.xml",
    /<release version="([^"]*)"/,
    "the newest flatpak release note",
  ],
];

if (release !== undefined) {
  for (const [file, re, what] of carries) {
    const hit = read(file).match(re);
    if (hit === null) {
      fail(`${file}  ${what} has no version -- this check is stale`);
    } else if (hit[1] !== release) {
      fail(`${file}  ${what} says ${hit[1]}, ${RELEASE_SOURCE} says ${release}`);
    }
  }

  const builds = [
    ["packaging/flatpak/io.github.tessarium.Tessarium.yml", "the flatpak build"],
    ["packaging/snap/snapcraft.yaml", "the snap build"],
  ];
  for (const [file, what] of builds) {
    if (!tarball(release).test(read(file))) {
      fail(`${file}  ${what} does not consume tessarium-${release}-...`);
    }
  }

  // Every packaging script must read the release from one place. A second
  // expression is a second source of truth, which is how the manifests
  // reached 0.1.0 while the binaries were on 0.2.0.
  for (const script of [
    "package.sh",
    "package-deb.sh",
    "package-rpm.sh",
    "package-flatpak.sh",
    "package-appimage.sh",
  ]) {
    // The exact expression, not merely a mention of the file: a comment
    // naming dune-project beside a sed that reads something else is how a
    // second source of truth gets back in.
    const extract = `sed -n 's/^(version \\([^)]*\\))/\\1/p' ${RELEASE_SOURCE}`;
    if (!read(`tools/${script}`).includes(extract)) {
      fail(`tools/${script}  does not read the version from ${RELEASE_SOURCE}`);
    }
  }
}

console.log(
  `versions: release ${release ?? "?"} from ${RELEASE_SOURCE}, `
    + `core ${read("ocaml/lib/version.ml").match(/^let core = "([^"]*)"/m)?.[1] ?? "?"}, `
    + `dashboard ${read("ui/package.json").match(/"version": "([^"]*)"/)?.[1] ?? "?"}; `
    + `${bad} disagreements`,
);
process.exit(bad ? 1 : 0);
