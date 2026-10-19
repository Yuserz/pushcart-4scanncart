// Creates (or resets) the staff accounts a fresh database needs, and sets the POS
// staff PIN.
//
// Accounts can't live in supabase/seeds: auth.users rows carry GoTrue-managed fields
// (identities, confirmation state, password hashing), so they are made through the
// Auth admin API instead. Re-running is safe: an existing account keeps its id and
// gets its password, role and name reset to the values here.
//
//   admin@pushcart.test    role 'admin'  - admin dashboard, products, POS mapping
//   cashier@pushcart.test  role 'user'   - a cashier (valid_cashier: non-anonymous 'user')
//
// Customers need no account: the shop flow signs them in anonymously.
//
// Passwords and the PIN are read from the environment (or .env), never from this file,
// because the repo is public and the cloud project is reachable from the internet:
//   SEED_ADMIN_PASSWORD, SEED_CASHIER_PASSWORD, SEED_STAFF_PIN (4-8 digits, optional)
//
// Usage:
//   node scripts/seed-accounts.mjs
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const projectRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
);

/** Minimal .env reader: KEY=value per line, ignoring comments and blank lines. */
function loadEnvFile(file) {
  if (!existsSync(file)) {
    return {};
  }

  const values = {};

  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line);

    if (!match || match[2] === '') {
      continue;
    }

    let value = match[2];

    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    values[match[1]] = value;
  }

  return values;
}

/** Finds an auth user by email, following pagination. */
async function findUserByEmail(supabase, email) {
  const perPage = 1000;

  for (let page = 1; ; page += 1) {
    const { data, error } = await supabase.auth.admin.listUsers({
      page,
      perPage,
    });

    if (error) {
      throw new Error(`Could not list users: ${error.message}`);
    }

    const user = data.users.find((u) => u.email === email);

    if (user || data.users.length < perPage) {
      return user ?? null;
    }
  }
}

/** Creates the account, or resets the password of the existing one. Returns its id. */
async function upsertAccount(supabase, account) {
  const existing = await findUserByEmail(supabase, account.email);

  if (existing) {
    const { error } = await supabase.auth.admin.updateUserById(existing.id, {
      password: account.password,
      email_confirm: true,
    });

    if (error) {
      throw new Error(`Could not update ${account.email}: ${error.message}`);
    }

    return { id: existing.id, created: false };
  }

  const { data, error } = await supabase.auth.admin.createUser({
    email: account.email,
    password: account.password,
    email_confirm: true,
  });

  if (error) {
    throw new Error(`Could not create ${account.email}: ${error.message}`);
  }

  return { id: data.user.id, created: true };
}

async function main() {
  const env = { ...loadEnvFile(path.join(projectRoot, '.env')), ...process.env };
  const url = env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = env.SUPABASE_SECRET_KEY;
  const publishableKey = env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;

  const missing = [
    'NEXT_PUBLIC_SUPABASE_URL',
    'SUPABASE_SECRET_KEY',
    'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY',
    'SEED_ADMIN_PASSWORD',
    'SEED_CASHIER_PASSWORD',
  ].filter((key) => !env[key]);

  if (missing.length > 0) {
    console.error(
      `Missing ${missing.join(', ')}.\n` +
        'Set them in .env (`make dev` copies .env.cloud there) or export them first.',
    );
    process.exitCode = 1;
    return;
  }

  const accounts = [
    {
      email: 'admin@pushcart.test',
      password: env.SEED_ADMIN_PASSWORD,
      role: 'admin',
      first_name: 'Store',
      last_name: 'Admin',
    },
    {
      email: 'cashier@pushcart.test',
      password: env.SEED_CASHIER_PASSWORD,
      role: 'user',
      first_name: 'Counter',
      last_name: 'Cashier',
    },
  ];

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  for (const account of accounts) {
    const { id, created } = await upsertAccount(admin, account);

    // handle_new_user already made the profile row; set its role and name.
    const { error } = await admin
      .from('profiles')
      .update({
        role: account.role,
        first_name: account.first_name,
        last_name: account.last_name,
      })
      .eq('id', id);

    if (error) {
      throw new Error(`Could not set the profile of ${account.email}: ${error.message}`);
    }

    console.log(`${created ? 'Created' : 'Reset'} ${account.email} (${account.role})`);
  }

  if (!env.SEED_STAFF_PIN) {
    console.log('SEED_STAFF_PIN not set: staff PIN left unchanged.');
    return;
  }

  // pos_set_staff_pin checks is_admin() against auth.uid(), so it must run as the admin.
  const asAdmin = createClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error: signInError } = await asAdmin.auth.signInWithPassword({
    email: accounts[0].email,
    password: accounts[0].password,
  });

  if (signInError) {
    throw new Error(`Could not sign in as ${accounts[0].email}: ${signInError.message}`);
  }

  const { error: pinError } = await asAdmin.rpc('pos_set_staff_pin', {
    p_pin: env.SEED_STAFF_PIN,
  });

  if (pinError) {
    throw new Error(`Could not set the staff PIN: ${pinError.message}`);
  }

  await asAdmin.auth.signOut();
  console.log('Staff PIN set.');
}

main().catch((error) => {
  console.error(`\nSeeding accounts failed: ${error.message}`);
  process.exitCode = 1;
});
