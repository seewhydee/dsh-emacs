// dsh-emacs-bridge — client (browser) bundle. The shared preset in
// deepseek-harness/packages/client/tsdown.client.ts (clientConfig) is
// repo-locked and cannot run for an out-of-tree package, so this replicates its
// artifact contract for this package alone. Keep the banner/footer/intro
// wrapper, the externals, the purity gate, and the define substitutions in sync
// with that preset (the contract is pre-release and the most likely thing to
// drift on a dsh version bump).
import { readFileSync } from 'node:fs'
import type { UserConfig } from 'tsdown'

const id = 'dsh-emacs-bridge'

/** Baseline module-table rows, mirrored from packages/client/web/src/platform.ts. */
const PLATFORM_MODULES = [
  'react',
  'react/jsx-runtime',
  'react-dom',
  'react-dom/client',
  '@deepseek-ai/cordis',
  '@deepseek-ai/dsh-client-ui-slots',
  '@deepseek-ai/dsh-client-ui-primitives',
] as const

/** Dynamic rows the parser preloads before shell boot, from the same file. */
const PRELOADED_CLIENT_EXTERNALS = ['@deepseek-ai/dsh-client-runtime/client'] as const

/** The package's own non-baseline module-table requests (`dsh.client.external`). */
function requestedExternal(): ReadonlySet<string> {
  const manifest = JSON.parse(
    readFileSync(new URL('package.json', import.meta.url), 'utf8'),
  ) as { dsh?: { client?: { external?: unknown } } }
  const raw = manifest.dsh?.client?.external
  return new Set(Array.isArray(raw) ? raw.filter((entry): entry is string => typeof entry === 'string') : [])
}

const requested = requestedExternal()

/** Whether an import specifier is answered by the loader module table. */
function isExternal(specifier: string): boolean {
  return (PLATFORM_MODULES as readonly string[]).includes(specifier)
    || (PRELOADED_CLIENT_EXTERNALS as readonly string[]).includes(specifier)
    || requested.has(specifier)
}

/** Inline-safe wire layers and vendored libraries a client bundle may carry privately. */
const INLINE_SAFE =
  /^@deepseek-ai\/dsh-(host-apiproxy|file-reference|session|llm|tools|brand)(\/|$)/
const VENDORED_LIBRARY = /^@deepseek-ai\/(cosmokit|schemastery)(\/|$)/
const GENERATED_REMOTE = /^@deepseek-ai\/dsh-[a-z0-9]+(?:-[a-z0-9]+)*\/remote$/

/** Build a node-idiom substitution set matching the shared preset's define. */
function buildDefines(): Record<string, string> {
  const mode = JSON.stringify(process.env.NODE_ENV ?? 'production')
  return {
    'process.env.NODE_ENV': mode,
    'import.meta.env.MODE': mode,
    'import.meta.env': JSON.stringify({ MODE: process.env.NODE_ENV ?? 'production' }),
  }
}

const config: UserConfig = {
  name: `${id}/client`,
  entry: { client: 'src/client/index.ts' },
  outDir: 'lib',
  format: ['cjs'],
  platform: 'browser',
  target: 'es2024',
  dts: false,
  sourcemap: true,
  clean: false,
  deps: {
    // Requested module-table rows stay imports; everything else bundles. A
    // require() the table cannot answer throws at runtime.
    neverBundle: isExternal,
    alwaysBundle: (specifier: string) => !isExternal(specifier),
  },
  define: buildDefines(),
  plugins: [{
    // Bundle purity gate (mirror of tsdown.client.ts' dsh-client-bundle-purity):
    // a cross-plugin value import that is neither a requested module row nor an
    // inline-safe wire layer is a build error. Type-only imports are erased
    // before this runs, so they never reach the gate.
    name: 'dsh-client-bundle-purity',
    resolveId(source: string) {
      if (!source.startsWith('@deepseek-ai/')) return null
      if (isExternal(source)) return null
      if (INLINE_SAFE.test(source) || VENDORED_LIBRARY.test(source) || GENERATED_REMOTE.test(source)) return null
      throw new Error(
        `client bundle purity: "${source}" is not a requested module row, an inline-safe wire layer, `
        + 'or a generated /remote contribution — declare it in dsh.client.external or collaborate through cordis services',
      )
    },
  }],
  outputOptions: {
    entryFileNames: 'client.js',
    banner: `window.__ModuleLoader__.load({ id: ${JSON.stringify(id)}, factory: (require) => {`,
    footer: 'return module.exports; } });',
    intro: 'var module = { exports: {} }; var exports = module.exports;',
  },
}

export default config
