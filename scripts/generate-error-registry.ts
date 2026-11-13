/**
 * generate-error-registry.ts
 *
 * Builds WebApp/src/utils/contractErrorRegistry.ts from the compiled hardhat
 * artifacts in Coin/artifacts: every custom error declared by any contract,
 * with its canonical signature, 4-byte selector, parameters, and the list of
 * contracts that declare it.
 *
 * Why it exists: the previous copy of the registry was generated 2026-03-21 by
 * a script that is no longer in the tree, and the drift showed — EscrowV2
 * errors (TokenNotSupported, InvalidSellerSignature, BadAttribution,
 * FeeTooLarge, …) were missing, so the WebApp could not decode them.
 * (EscrowFeeNotAllowed is NOT one of them: no contract in this tree declares
 * it — verified 2026-11-13 — so its absence is correct, not drift.)
 *
 * Usage:
 *   cd Coin
 *   NODE_PATH=/home/omnirick/OmniBazaar/node_modules \
 *     npx tsx scripts/generate-error-registry.ts [--out <path>]
 *
 *   The WebApp path is the default output. `--out` exists so
 *   scripts/check-error-registry.cjs can regenerate to a temp file and diff.
 *
 * Determinism: artifacts are visited in sorted order, error entries are sorted
 * by error name (the convention the committed file already follows — one entry
 * per selector, so a contract-major grouping is not representable), and each
 * entry's contract list is sorted alphabetically. The header's `Generated at`
 * line honours ERROR_REGISTRY_TIMESTAMP so a reproducibility check can pin it;
 * everything else is a pure function of the artifact set plus the checked-in
 * `scripts/error-registry-legacy.json` seed, so re-running on an unchanged tree
 * rewrites the same bytes.
 *
 * Legacy seed: contracts get deleted from this repo while their deployments
 * stay live, and a selector that used to decode must keep decoding. Every
 * selector the artifact sweep no longer produces is merged back from
 * `scripts/error-registry-legacy.json` (the pre-2026-11-13 registry's entries,
 * frozen). Artifacts always win on a selector they produce.
 *
 * Formatting: the output is piped through prettier with the WebApp's
 * .prettierrc (printWidth 100, singleQuote, tabWidth 2, trailingComma es5) so
 * the file stays byte-identical to what a WebApp `prettier --write` produces.
 */
import fs from "node:fs";
import path from "node:path";
import { id } from "ethers";
import * as prettier from "prettier";

/** One flattened error declaration. */
interface ErrorRecord {
  name: string;
  signature: string;
  selector: string;
  parameters: Array<{ name: string; type: string }>;
  contracts: Set<string>;
}

/** Minimal shape of a hardhat artifact we rely on. */
interface AbiInput {
  name: string;
  type: string;
  components?: AbiInput[];
}

interface AbiItem {
  type: string;
  name?: string;
  inputs?: AbiInput[];
}

interface Artifact {
  contractName?: string;
  abi?: AbiItem[];
}

/** Canonical ABI type for a signature: tuples expand to `(a,b)` + any array suffix. */
function canonicalType(input: AbiInput): string {
  if (input.type.startsWith("tuple")) {
    const suffix = input.type.slice("tuple".length);
    const inner = (input.components ?? []).map(canonicalType).join(",");
    return `(${inner})${suffix}`;
  }
  return input.type;
}

/** Every `*.json` artifact under `dir` (skipping `.dbg.json` build-info stubs). */
function findArtifacts(dir: string, out: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      findArtifacts(full, out);
    } else if (entry.name.endsWith(".json") && !entry.name.endsWith(".dbg.json")) {
      out.push(full);
    }
  }
  return out.sort();
}

function parseArgs(argv: string[]): { out: string } {
  const defaultOut = path.join(
    __dirname,
    "..",
    "..",
    "WebApp",
    "src",
    "utils",
    "contractErrorRegistry.ts",
  );
  let out = process.env.ERROR_REGISTRY_OUT || defaultOut;
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--out") {
      const value = argv[i + 1];
      if (!value) throw new Error("--out needs a path");
      out = path.resolve(value);
      i += 1;
    }
  }
  return { out };
}

async function main(): Promise<void> {
  const { out } = parseArgs(process.argv.slice(2));
  const artifactsDir = path.join(__dirname, "..", "artifacts");
  if (!fs.existsSync(artifactsDir)) {
    throw new Error(`no artifacts at ${artifactsDir} — run hardhat compile first`);
  }

  const files = findArtifacts(artifactsDir);
  const errors = new Map<string, ErrorRecord>();
  const conflicts: string[] = [];
  let artifactCount = 0;
  const contracts = new Set<string>();

  for (const file of files) {
    let artifact: Artifact;
    try {
      artifact = JSON.parse(fs.readFileSync(file, "utf8")) as Artifact;
    } catch {
      continue;
    }
    if (!artifact || !Array.isArray(artifact.abi)) continue;
    const contractName = artifact.contractName;
    if (typeof contractName !== "string" || contractName === "") continue;
    artifactCount += 1;
    contracts.add(contractName);

    for (const item of artifact.abi) {
      if (item.type !== "error" || typeof item.name !== "string") continue;
      const inputs = item.inputs ?? [];
      const signature = `${item.name}(${inputs.map(canonicalType).join(",")})`;
      const selector = id(signature).slice(0, 10);
      const parameters = inputs.map((input) => ({
        name: input.name,
        type: input.type,
      }));

      const existing = errors.get(selector);
      if (existing) {
        existing.contracts.add(contractName);
        if (existing.signature !== signature) {
          conflicts.push(
            `${selector} ${existing.signature} (${[...existing.contracts].join(", ")}) vs ${signature} (${contractName})`,
          );
        }
        continue;
      }
      errors.set(selector, {
        name: item.name,
        signature,
        selector,
        parameters,
        contracts: new Set([contractName]),
      });
    }
  }

  // ---- merge the frozen legacy seed (selectors no artifact produces) -----
  const seedPath = path.join(__dirname, "error-registry-legacy.json");
  let legacyAdded = 0;
  if (fs.existsSync(seedPath)) {
    const seed = JSON.parse(fs.readFileSync(seedPath, "utf8")) as
      | ErrorRecord[]
      | { entries: ErrorRecord[] };
    const seedEntries = Array.isArray(seed) ? seed : seed.entries;
    for (const entry of seedEntries) {
      if (errors.has(entry.selector)) continue;
      errors.set(entry.selector, {
        name: entry.name,
        signature: entry.signature,
        selector: entry.selector,
        parameters: entry.parameters ?? [],
        contracts: new Set(entry.contracts ?? []),
      });
      legacyAdded += 1;
    }
  }

  const entries = [...errors.values()].sort((a, b) => {
    const byName = a.name < b.name ? -1 : a.name > b.name ? 1 : 0;
    return byName !== 0 ? byName : a.signature < b.signature ? -1 : 1;
  });

  const generatedAt =
    process.env.ERROR_REGISTRY_TIMESTAMP || new Date().toISOString();

  const lines: string[] = [];
  lines.push("/**");
  lines.push(" * Contract Error Registry");
  lines.push(" *");
  lines.push(" * AUTO-GENERATED FILE - DO NOT EDIT MANUALLY");
  lines.push(" * Generated by: Coin/scripts/generate-error-registry.ts");
  lines.push(` * Generated at: ${generatedAt}`);
  lines.push(" *");
  lines.push(
    " * This file contains all custom error selectors from OmniBazaar smart contracts.",
  );
  lines.push(
    " * Each error is mapped to its name, signature, and the contracts that use it.",
  );
  lines.push(" */");
  lines.push("");
  lines.push("/** Shape of a single decoded contract error entry */");
  lines.push("export interface ContractError {");
  lines.push('  /** Error name (e.g., "AlreadyRegistered") */');
  lines.push("  name: string;");
  lines.push('  /** Full signature with types (e.g., "AlreadyRegistered()") */');
  lines.push("  signature: string;");
  lines.push('  /** 4-byte selector (e.g., "0x3a81d6fc") */');
  lines.push("  selector: string;");
  lines.push("  /** Parameter definitions */");
  lines.push("  parameters: Array<{ name: string; type: string }>;");
  lines.push("  /** Contracts that define this error */");
  lines.push("  contracts: string[];");
  lines.push("}");
  lines.push("");
  lines.push("/**");
  lines.push(" * Registry of all contract errors by selector");
  lines.push(" */");
  lines.push(
    "export const CONTRACT_ERROR_REGISTRY: Record<string, ContractError> = {",
  );

  for (const entry of entries) {
    const contractList = [...entry.contracts].sort();
    lines.push(`  // ${entry.signature}`);
    lines.push(`  '${entry.selector}': {`);
    lines.push(`    name: '${entry.name}',`);
    lines.push(`    signature: '${entry.signature}',`);
    lines.push(`    selector: '${entry.selector}',`);
    if (entry.parameters.length === 0) {
      lines.push("    parameters: [],");
    } else if (entry.parameters.length === 1) {
      const only = entry.parameters[0];
      lines.push(`    parameters: [{ name: '${only.name}', type: '${only.type}' }],`);
    } else {
      lines.push("    parameters: [");
      for (const params of entry.parameters) {
        lines.push(`      { name: '${params.name}', type: '${params.type}' },`);
      }
      lines.push("    ],");
    }
    lines.push(`    contracts: [${contractList.map((c) => `'${c}'`).join(", ")}],`);
    lines.push("  },");
    lines.push("");
  }

  lines.push("};");
  lines.push("");
  lines.push("/**");
  lines.push(" * Lookup error by selector");
  lines.push(" * @param selector - 4-byte hex selector (with or without 0x prefix)");
  lines.push(" * @returns Matching ContractError, or undefined if not found");
  lines.push(" */");
  lines.push(
    "export function getErrorBySelector(selector: string): ContractError | undefined {",
  );
  lines.push("  return CONTRACT_ERROR_REGISTRY[selector.toLowerCase()];");
  lines.push("}");
  lines.push("");
  lines.push("/**");
  lines.push(" * Lookup error by name");
  lines.push(' * @param name - Error name (e.g. "AlreadyRegistered")');
  lines.push(" * @returns Matching ContractError, or undefined if not found");
  lines.push(" */");
  lines.push(
    "export function getErrorByName(name: string): ContractError | undefined {",
  );
  lines.push(
    "  return Object.values(CONTRACT_ERROR_REGISTRY).find((e) => e.name === name);",
  );
  lines.push("}");
  lines.push("");
  lines.push("/** Total number of registered errors */");
  lines.push(`export const ERROR_COUNT = ${entries.length};`);
  lines.push("");

  const formatted = await prettier.format(lines.join("\n"), {
    parser: "typescript",
    semi: true,
    singleQuote: true,
    tabWidth: 2,
    trailingComma: "es5",
    printWidth: 100,
    bracketSpacing: true,
    arrowParens: "always",
    endOfLine: "lf",
  });

  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, formatted);

  console.log(`artifacts scanned: ${artifactCount}`);
  console.log(`contracts:         ${contracts.size}`);
  console.log(`errors:            ${entries.length}`);
  console.log(`selectors:         ${errors.size}`);
  console.log(`legacy seed merged: ${legacyAdded}`);
  console.log(`written:           ${out}`);
  if (conflicts.length > 0) {
    console.log("\nselector collisions (same 4 bytes, different signature):");
    for (const conflict of conflicts) console.log(`  ${conflict}`);
  }
}

void main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
