import { readFileSync } from "node:fs";

let checks = 0;
let failures = 0;
const check = (name, ok) => {
  checks++;
  if (!ok) {
    failures++;
    console.log(`  FAIL  ${name}`);
  }
};

const makefile = readFileSync(
  new URL("../../Makefile", import.meta.url),
  "utf8",
);

/* The recipe, from its target line to the first line that starts a new one. */
const recipe = (name) => {
  const start = makefile.indexOf(`\n${name}:`);
  if (start < 0) return "";
  const body = makefile.slice(start + 1);
  const end = body.search(/\n[^\t\n#][^\n]*:/);
  return end < 0 ? body : body.slice(0, end);
};

const testUi = recipe("test-ui");
check("the end-to-end recipe is where it was", testUi.length > 0);

const launches = testUi
  .replace(/\\\n\s*/g, " ")
  .split("server/bin/main.exe")
  .slice(1)
  /* The recipe also BUILDS main.exe, and `dune build` takes no --port. */
  .filter((slice) => /--port/.test(slice));
check(
  `every server the suite starts is accounted for (${launches.length})`,
  launches.length === 5,
);

const LOOPBACK = /^http:\/\/127\.0\.0\.1:/;
for (const flag of ["--basemap-source", "--basemap-assets"]) {
  const unpinned = launches.filter((line) => {
    const url = new RegExp(`${flag}\\s+(\\S+)`).exec(line)?.[1];
    return url === undefined || !LOOPBACK.test(url);
  });
  check(
    `no test server takes its ${flag} from the internet (${
      unpinned.length || "none"
    } unpinned)`,
    unpinned.length === 0,
  );
}

const suite = readFileSync(new URL("./e2e.mjs", import.meta.url), "utf8");
const hosts = [
  ...suite.matchAll(/(?:https?:)?\/\/([a-zA-Z0-9.-]+)(?::\d+)?/g),
]
  .map((hit) => hit[1])
  /* `evil.example` and `fallback.com` are arguments to checks about requests
     being REFUSED, and are never dereferenced. */
  .filter((host) => !/^(127\.0\.0\.1|localhost|evil\.example)$/.test(host));
check(
  `and the suite names no host but this machine (${
    [...new Set(hosts)].join(", ") || "none"
  })`,
  hosts.length === 0,
);

console.log(`\nharness: ${checks} checks, ${failures} failures`);
if (failures > 0) process.exit(1);
