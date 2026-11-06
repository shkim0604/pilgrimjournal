import { serve } from '@hono/node-server';
import { fileURLToPath } from 'node:url';
import { BootstrapError, ensureBootstrapAdmin } from './auth/bootstrap.ts';
import { ConfigError, loadConfig } from './config.ts';
import { openDatabase } from './db.ts';
import { createApp } from './server.ts';

const webAdminDir = fileURLToPath(new URL('../', import.meta.url));

try {
  const config = loadConfig(process.env, webAdminDir);
  const db = openDatabase(config.dbPath);
  await ensureBootstrapAdmin(db, config.bootstrap, (message) => console.log(message));
  const app = createApp({ db, config });
  serve({ fetch: app.fetch, port: config.port, hostname: '0.0.0.0' }, (info) => {
    console.log(`Pilgrim admin console listening on :${info.port} (origin ${config.origin})`);
  });
} catch (error) {
  if (error instanceof ConfigError || error instanceof BootstrapError) {
    console.error(`${error.name}: ${error.message}`);
    process.exit(1);
  }
  throw error;
}
