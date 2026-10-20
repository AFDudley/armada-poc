// ESLint for every tracked JavaScript/TypeScript file (contracts tooling,
// scripts/, relayer/, mcp-server/, crowdfund-ui/, governance-ui/, packages/):
// the typescript-eslint recommended set, unscoped (no type-checked project
// resolution, so it runs uniformly across every sub-project's files without
// needing each one's own tsconfig wired in).
//
// _legacy/ is explicitly "Deprecated earlier approach — do not modify or
// reference in new code" (CLAUDE.md); lib/forge-std and lib/halmos-cheatcodes
// are vendored third-party Foundry libraries. All three are excluded from
// every hook, the same way armada-nitro excludes vendored src/nitro/.
import tseslint from "typescript-eslint";
import reactHooks from "eslint-plugin-react-hooks";

export default tseslint.config(
  {
    ignores: [
      "_legacy/**",
      "lib/forge-std/**",
      "lib/halmos-cheatcodes/**",
      "**/node_modules/**",
      "**/dist/**",
      "**/artifacts/**",
      "**/cache/**",
      "**/typechain-types/**",
      "**/out/**",
      "**/forge-out/**",
      "**/*.d.ts",
    ],
  },
  ...tseslint.configs.recommended,
  {
    // Registers the `react-hooks` rule namespace so the pre-existing
    // `// eslint-disable-next-line react-hooks/...` comments in
    // crowdfund-ui/ and governance-ui/ resolve to a known rule instead of
    // erroring as an unknown rule reference. The rules themselves stay off
    // (no `rules:` entry here): turning them on is a new lint pass over
    // ~800 React component files this install does not scope to run.
    plugins: { "react-hooks": reactHooks },
  },
  {
    // Rule relaxations against the repo's existing, already-committed
    // conventions (exophial init: install-time baseline, no source edits).
    // Each rule below fires on pre-existing patterns, not on a new-code bug
    // class; none is `--fix`-able, so closing it would mean rewriting the
    // flagged source.
    rules: {
      // 512 pre-existing sites across hardhat scripts, the relayer and the
      // frontends. The repo's own tsconfig runs with `strict: true`, so
      // `any` is a deliberate escape hatch at ABI/RPC/library boundaries,
      // not an oversight.
      "@typescript-eslint/no-explicit-any": "off",
      // Chai's getter-style assertions (`expect(x).to.be.true`) are a
      // property access with no call, so eslint reads every assertion in
      // the test suite as an unused expression.
      "@typescript-eslint/no-unused-expressions": "off",
      // Destructuring a tuple return to document ignored positions (e.g.
      // `const [used, _ignored] = await fn()`), a common pattern in the
      // Hardhat/Chai test suite.
      "@typescript-eslint/no-unused-vars": "off",
      // CommonJS `require()` interop with packages that have no ESM
      // export (snarkjs, circomlibjs) in scripts/ and the relayer.
      "@typescript-eslint/no-require-imports": "off",
      // Pre-existing `@ts-ignore` comments predate this repo's eslint
      // install; migrating each to `@ts-expect-error` is a source edit.
      "@typescript-eslint/ban-ts-comment": "off",
      // Single pre-existing site each (scripts/capture/e2e-tx-differential.ts,
      // crowdfund-ui IdenticonSvg.tsx's .d.ts triple-slash reference);
      // closing either means rewriting the flagged declaration.
      "@typescript-eslint/no-empty-object-type": "off",
      "@typescript-eslint/triple-slash-reference": "off",
    },
  },
);
