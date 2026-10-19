// Cross-platform launcher for the Supabase CLI.
//
// The `supabase` npm package declares its binary as `bin/supabase`, but on Windows
// it only ships `bin/supabase.exe`. Yarn resolves `yarn supabase ...` from that
// package.json `bin` field (ignoring the generated node_modules/.bin shims), so on
// Windows it ends up trying to run a non-existent file and fails with:
//
//   Error: Cannot find module '.../node_modules/supabase/bin/supabase'
//
// This wrapper picks the correct binary for the current platform and forwards
// every argument, so `yarn supabase <args>` behaves the same on Windows, macOS
// and Linux.
//
// Newer CLI releases (2.100+) drop `bin/` and ship a Node entry at `dist/supabase.js`
// instead. Yarn 1 ignores the Berry-format yarn.lock and resolves the newest release,
// so both layouts are supported here.
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const packageDir = path.join(projectRoot, 'node_modules', 'supabase');
const binaryName = process.platform === 'win32' ? 'supabase.exe' : 'supabase';
const binaryPath = path.join(packageDir, 'bin', binaryName);
const nodeEntryPath = path.join(packageDir, 'dist', 'supabase.js');

let command;
let args = process.argv.slice(2);

if (existsSync(binaryPath)) {
  command = binaryPath;
} else if (existsSync(nodeEntryPath)) {
  command = process.execPath;
  args = [nodeEntryPath, ...args];
} else {
  console.error(
    `Supabase CLI not found at:\n  ${binaryPath}\n  ${nodeEntryPath}\n\nRun \`yarn install\` to install it.`,
  );
  process.exit(1);
}

const { status, error } = spawnSync(command, args, {
  stdio: 'inherit',
});

if (error) {
  console.error(`Failed to run the Supabase CLI: ${error.message}`);
  process.exit(1);
}

process.exit(status ?? 1);
