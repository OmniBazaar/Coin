/**
 * check-error-registry.cjs
 *
 * Regenerates the WebApp contract error registry into a temp file and fails
 * the build when the committed copy differs, naming the missing / stale /
 * changed selectors.
 *
 * It runs the real generator (scripts/generate-error-registry.ts) against the
 * hardhat artifacts in this repo, so it needs a compile first:
 *
 *   cd Coin
 *   npx hardhat compile
 *   node scripts/check-error-registry.cjs
 *
 * Exit codes:
 *   0  committed registry matches the artifacts
 *   1  the registry is stale (diff printed)
 *   2  precondition failure (no artifacts, no committed file, generator error)
 *
 * Options / env:
 *   --committed <path>   committed registry to compare against
 *                        (default ../WebApp/src/utils/contractErrorRegistry.ts,
 *                        also settable with WEBAPP_ERROR_REGISTRY)
 *   --verbose            print the generator's own output
 *
 * No WebApp build is needed: the only WebApp input is the committed .ts file.
 */
const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_COMMITTED = path.join(
  __dirname,
  "..",
  "..",
  "WebApp",
  "src",
  "utils",
  "contractErrorRegistry.ts",
);

function parseArgs(argv) {
  const options = {
    committed: process.env.WEBAPP_ERROR_REGISTRY || DEFAULT_COMMITTED,
    verbose: argv.includes("--verbose"),
  };
  const at = argv.indexOf("--committed");
  if (at !== -1) {
    const value = argv[at + 1];
    if (!value) {
      console.error("--committed needs a path");
      process.exit(2);
    }
    options.committed = path.resolve(value);
  }
  return options;
}

/** selector -> signature, from a registry file. */
function readRegistry(source) {
  const entries = new Map();
  const pattern = /^ {2}'(0x[0-9a-f]{8})': \{\n {4}name: '([^']*)',\n {4}signature: '([^']*)',/gm;
  let match;
  while ((match = pattern.exec(source)) !== null) {
    entries.set(match[1], { name: match[2], signature: match[3] });
  }
  return entries;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const artifactDir = path.join(__dirname, "..", "artifacts");
  if (!fs.existsSync(artifactDir)) {
    console.error(
      `no artifacts at ${artifactDir} — run \`npx hardhat compile\` in Coin first`,
    );
    process.exit(2);
  }
  if (!fs.existsSync(options.committed)) {
    console.error(`no committed registry at ${options.committed}`);
    process.exit(2);
  }

  const committedSource = fs.readFileSync(options.committed, "utf8");
  // Pin the header timestamp to the committed one so the comparison is about
  // selectors, not about when the generator ran.
  const stampMatch = committedSource.match(/ \* Generated at: (.*)$/m);
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "error-registry-"));
  const tmpFile = path.join(tmpDir, "contractErrorRegistry.ts");

  const generator = path.join(__dirname, "generate-error-registry.ts");
  const env = {
    ...process.env,
    ...(stampMatch ? { ERROR_REGISTRY_TIMESTAMP: stampMatch[1] } : {}),
  };
  let child = null;
  for (const args of [
    ["--no-install", "tsx", generator, "--out", tmpFile],
    ["--yes", "tsx", generator, "--out", tmpFile],
  ]) {
    child = spawnSync("npx", args, {
      cwd: path.join(__dirname, ".."),
      stdio: options.verbose ? "inherit" : "pipe",
      encoding: "utf8",
      env,
    });
    if (child.status === 0) break;
  }
  if (!child || child.status !== 0) {
    console.error("generator failed");
    if (child && child.stderr) console.error(child.stderr);
    console.error(
      "hint: the generator needs tsx; install it with `npm install --no-save tsx`",
    );
    process.exit(2);
  }

  const generatedSource = fs.readFileSync(tmpFile, "utf8");
  if (generatedSource === committedSource) {
    const count = readRegistry(generatedSource).size;
    console.log(
      `error registry is up to date (${count} selectors): ${options.committed}`,
    );
    fs.rmSync(tmpDir, { recursive: true, force: true });
    return;
  }

  const committed = readRegistry(committedSource);
  const generated = readRegistry(generatedSource);
  const missing = [...generated.keys()].filter((s) => !committed.has(s));
  const stale = [...committed.keys()].filter((s) => !generated.has(s));
  const changed = [...generated.keys()].filter(
    (s) => committed.has(s) && committed.get(s).signature !== generated.get(s).signature,
  );

  console.error("error registry is STALE — regenerate and commit:");
  console.error("  cd Coin && npx tsx scripts/generate-error-registry.ts");
  console.error(
    "(in the dev monorepo, tsx lives in the root node_modules — use `npx tsx` from Coin or set NODE_PATH=../node_modules)",
  );
  console.error(
    `\ncommitted ${committed.size} selectors, artifacts produce ${generated.size}`,
  );
  const show = (label, selectors, pick) => {
    if (selectors.length === 0) return;
    console.error(`\n${label} (${selectors.length}):`);
    for (const selector of selectors.slice(0, 40)) {
      console.error(`  ${selector}  ${pick(selector)}`);
    }
    if (selectors.length > 40) {
      console.error(`  … ${selectors.length - 40} more`);
    }
  };
  show("missing from the committed file", missing, (s) => generated.get(s).signature);
  show("stale in the committed file", stale, (s) => committed.get(s).signature);
  show(
    "signature changed",
    changed,
    (s) => `${committed.get(s).signature} -> ${generated.get(s).signature}`,
  );

  fs.rmSync(tmpDir, { recursive: true, force: true });
  process.exit(1);
}

main();
