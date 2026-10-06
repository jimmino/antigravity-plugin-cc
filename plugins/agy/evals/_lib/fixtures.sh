# Fixture generators for the offloading eval cases. Sourced by scaffold.sh,
# after common.sh. Everything is deterministic: the canned agy answers in
# case.yaml cite exact lines, and each generator checks its anchors.

# ------------------------------------------------------------- backend ----
# make_backend small|full
#   small: ~10 files, ~6 KB. Cheaper to read directly than to offload.
#   full:  adds a plugin platform (src/platform/) and 110 segment modules
#          (src/modules/, ~1 MB) that each register their own route, auth
#          policy and, for some, a scheduled job; plus a vendored
#          node_modules tree. Mapping it means reading many files, the
#          shape where offloading pays.
#
# Ground truth used by the graders:
#   src/server.ts:12         app.listen (entry point; port from config.ts:5)
#   src/server.ts:9          registers the users, orders and admin routes
#   src/db/client.ts:8       the one pg Pool
#   src/db/queries.ts:21     parameterised query (safe)
#   src/db/queries.ts:34     string-concatenated query (unsafe: ?status=)
#   src/auth/session.ts:40   verifySession; expiry enforced at :48
#   src/jobs/cleanup.ts:15   runCleanup (file has 21 lines)
#   importers of src/db/client.ts: db/queries.ts, jobs/cleanup.ts,
#     routes/orders.ts, modules/mod007.ts, mod023.ts, mod058.ts, mod091.ts
# full only:
#   src/server.ts:11         bootPlatform(app)
#   src/platform/boot.ts:11  mounts each segment route behind its policy
#   src/platform/policies.ts:14  preHandlerFor: public none, session 401,
#                            admin 401 then 403 unless in ADMIN_USER_IDS
#   src/platform/scheduler.ts:8  jobs run on setInterval in every process
#   src/db/queries.ts:44     runSql, the segment modules' query helper
#   segment policy: m%5==0 admin, else m%3==0 public, else session;
#     POST when m is odd; a job when m%7==0; mod%4==3 validates nothing
make_backend() {
  local size="${1:-full}"
  mkdir -p src/routes src/auth src/db src/jobs src/util

  cat > package.json <<'EOF'
{
  "name": "orders-api",
  "version": "1.4.0",
  "main": "dist/server.js",
  "scripts": { "start": "node dist/server.js", "build": "tsc" },
  "dependencies": { "fastify": "^5.0.0", "pg": "^8.11.0" }
}
EOF

  cat > README.md <<'EOF'
# orders-api

Order intake and fulfilment backend. `src/server.ts` boots the HTTP server;
routes live in `src/routes/`, data access in `src/db/`, scheduled work in
`src/jobs/`, and `src/modules/` holds the domain modules.
EOF

  cat > src/config.ts <<'EOF'
import { readFileSync } from 'fs';

export const config = {
  databaseUrl: process.env.DATABASE_URL ?? 'postgres://localhost/orders',
  port: Number(process.env.PORT ?? 8080),
  sessionTtlSeconds: 3600,
  version: JSON.parse(readFileSync('package.json', 'utf8')).version as string,
};
EOF

  cat > src/util/log.ts <<'EOF'
export const log = {
  info: (msg: string) => console.log(`[info] ${msg}`),
  warn: (msg: string) => console.warn(`[warn] ${msg}`),
};
EOF

  if [ "$size" = "full" ]; then
    cat > src/server.ts <<'EOF'
import Fastify from 'fastify';
import { config } from './config';
import { log } from './util/log';
import { registerUserRoutes } from './routes/users';
import { registerOrderRoutes } from './routes/orders';
import { registerAdminRoutes } from './routes/admin';
import { bootPlatform } from './platform/boot';
const app = Fastify();
for (const register of [registerUserRoutes, registerOrderRoutes, registerAdminRoutes]) register(app);
// Segment modules (src/modules) register their own routes, auth policy and jobs.
bootPlatform(app);
app.listen({ port: config.port }, () => log.info(`listening on ${config.port}`));
EOF
  else
    cat > src/server.ts <<'EOF'
import Fastify from 'fastify';
import { config } from './config';
import { log } from './util/log';
import { registerUserRoutes } from './routes/users';
import { registerOrderRoutes } from './routes/orders';
import { registerAdminRoutes } from './routes/admin';

const app = Fastify();
registerUserRoutes(app);
registerOrderRoutes(app);
registerAdminRoutes(app);
app.listen({ port: config.port }, () => log.info(`listening on ${config.port}`));
EOF
  fi

  cat > src/db/client.ts <<'EOF'
import { Pool } from 'pg';
import { config } from '../config';

// One pool for the whole process. Every query in the app goes through
// this export, so connection limits are set in exactly one place.
const MAX_CONNECTIONS = 20;

export const db = new Pool({ connectionString: config.databaseUrl, max: MAX_CONNECTIONS });
EOF

  cat > src/db/queries.ts <<'EOF'
import { db } from './client';

export interface User {
  id: string;
  email: string;
  createdAt: Date;
}

export interface Order {
  id: string;
  userId: string;
  status: string;
  totalCents: number;
}

// Looks a user up by primary key. The id comes straight from the URL
// parameter in routes/users.ts.
export async function findUser(id: string): Promise<User | null> {
  // Parameterised: pg sends the value separately from the SQL text.
  const sql = 'SELECT id, email, created_at FROM users WHERE id = $1';
  const res = await db.query(sql, [id]);
  return res.rows[0] ?? null;
}

// Lists orders in one status for the admin dashboard. `status` is the
// ?status= query parameter from routes/admin.ts.
export async function ordersByStatus(status: string): Promise<Order[]> {
  const base = 'SELECT id, user_id, status, total_cents FROM orders';
  const where = " WHERE status = '" + status + "'";
  const order = ' ORDER BY created_at DESC LIMIT 100';
  if (status.length > 32) {
    throw new Error('status too long');
  }
  const res = await db.query(base + where + order);
  return res.rows;
}

export async function countOrders(userId: string): Promise<number> {
  const res = await db.query('SELECT count(*) AS n FROM orders WHERE user_id = $1', [userId]);
  return Number(res.rows[0].n);
}
EOF

  cat > src/auth/session.ts <<'EOF'
import { createHmac, timingSafeEqual } from 'crypto';
import { config } from '../config';

export interface Session {
  userId: string;
  issuedAt: number;
  exp: number;
}

const SECRET = process.env.SESSION_SECRET ?? 'dev-only-secret';

function now(): number {
  return Math.floor(Date.now() / 1000);
}

function sign(body: string): string {
  return createHmac('sha256', SECRET).update(body).digest('base64url');
}

// Issues a token of the form <base64url(json)>.<signature>.
export function issueSession(userId: string): string {
  const issuedAt = now();
  const payload: Session = { userId, issuedAt, exp: issuedAt + config.sessionTtlSeconds };
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  return `${body}.${sign(body)}`;
}

function decode(body: string): Session | null {
  try {
    return JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as Session;
  } catch {
    return null;
  }
}

// Checks the signature and the expiry. Called by the auth hook on every
// request; a null result means 401.
// The signature comparison is constant-time.
// Expiry is checked after the signature so a forged exp is never trusted.
export function verifySession(token: string): Session | null {
  const [body, sig] = token.split('.');
  if (!body || !sig) return null;
  const expected = Buffer.from(sign(body));
  const given = Buffer.from(sig);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;
  const payload = decode(body);
  if (!payload) return null;
  if (payload.exp <= now()) return null;
  return payload;
}
EOF

  cat > src/auth/hook.ts <<'EOF'
import type { FastifyInstance } from 'fastify';
import { verifySession } from './session';

export function requireSession(app: FastifyInstance): void {
  app.addHook('onRequest', async (req, reply) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer /, '');
    const session = verifySession(token);
    if (!session) return reply.code(401).send({ error: 'unauthorized' });
    (req as any).session = session;
  });
}
EOF

  cat > src/routes/users.ts <<'EOF'
import type { FastifyInstance } from 'fastify';
import { findUser } from '../db/queries';
import { requireSession } from '../auth/hook';

export function registerUserRoutes(app: FastifyInstance): void {
  requireSession(app);
  app.get('/users/:id', async (req) => findUser((req.params as any).id));
}
EOF

  cat > src/routes/orders.ts <<'EOF'
import type { FastifyInstance } from 'fastify';
import { db } from '../db/client';

export function registerOrderRoutes(app: FastifyInstance): void {
  app.post('/orders', async (req) => {
    const { userId, totalCents } = req.body as { userId: string; totalCents: number };
    const res = await db.query(
      'INSERT INTO orders (user_id, status, total_cents) VALUES ($1, $2, $3) RETURNING id',
      [userId, 'new', totalCents],
    );
    return { id: res.rows[0].id };
  });
}
EOF

  cat > src/routes/admin.ts <<'EOF'
import type { FastifyInstance } from 'fastify';
import { ordersByStatus } from '../db/queries';

export function registerAdminRoutes(app: FastifyInstance): void {
  app.get('/admin/orders', async (req) => ordersByStatus(String((req.query as any).status ?? 'new')));
}
EOF

  cat > src/jobs/cleanup.ts <<'EOF'
import { db } from '../db/client';
import { log } from '../util/log';

// Nightly: removes carts abandoned for more than 30 days and expired
// password-reset tokens. Scheduled by the platform cron, not by this app.
const CART_TTL_DAYS = 30;

async function deleteAbandonedCarts(): Promise<number> {
  const res = await db.query(
    "DELETE FROM carts WHERE updated_at < now() - make_interval(days => $1)",
    [CART_TTL_DAYS],
  );
  return res.rowCount ?? 0;
}
export async function runCleanup(): Promise<number> {
  const carts = await deleteAbandonedCarts();
  const tokens = await db.query('DELETE FROM reset_tokens WHERE expires_at < now()');
  const total = carts + (tokens.rowCount ?? 0);
  log.info(`cleanup removed ${total} rows`);
  return total;
}
EOF

  if [ "$size" = "full" ]; then
    mkdir -p src/platform src/modules node_modules/fastq/lib

    cat >> src/db/queries.ts <<'EOF'

// Generic parameterised query for the segment modules.
export async function runSql(sql: string, params: unknown[]): Promise<{ rows: any[] }> {
  return db.query(sql, params);
}
EOF

    cat > src/platform/registry.ts <<'EOF'
import type { FastifyRequest } from 'fastify';

export type AuthPolicy = 'public' | 'session' | 'admin';

export interface SegmentRoute {
  method: 'GET' | 'POST';
  url: string;
  auth: AuthPolicy;
  handler: (req: FastifyRequest) => Promise<unknown>;
}

export interface SegmentJob {
  name: string;
  everyMinutes: number;
  run: () => Promise<void>;
}

const routes: SegmentRoute[] = [];
const jobs: SegmentJob[] = [];

// Segment modules call these at import time; boot.ts reads them back.
export const registry = {
  route: (r: SegmentRoute) => { routes.push(r); },
  job: (j: SegmentJob) => { jobs.push(j); },
  routes: () => routes,
  jobs: () => jobs,
};
EOF

    cat > src/platform/policies.ts <<'EOF'
import type { FastifyReply, FastifyRequest } from 'fastify';
import { verifySession } from '../auth/session';
import type { AuthPolicy } from './registry';

const ADMIN_IDS = new Set((process.env.ADMIN_USER_IDS ?? '').split(',').filter(Boolean));

type PreHandler = (req: FastifyRequest, reply: FastifyReply) => Promise<void>;

function bearer(req: FastifyRequest): string {
  return (req.headers.authorization ?? '').replace(/^Bearer /, '');
}

// One preHandler per auth policy. 'public' routes get none.
export function preHandlerFor(policy: AuthPolicy): PreHandler | undefined {
  if (policy === 'public') return undefined;
  return async (req, reply) => {
    const session = verifySession(bearer(req));
    if (!session) return reply.code(401).send({ error: 'unauthorized' });
    if (policy === 'admin' && !ADMIN_IDS.has(session.userId)) {
      return reply.code(403).send({ error: 'forbidden' });
    }
    (req as any).session = session;
  };
}
EOF

    cat > src/platform/boot.ts <<'EOF'
import type { FastifyInstance } from 'fastify';
import { registry } from './registry';
import { preHandlerFor } from './policies';
import { startScheduler } from './scheduler';
import './segments';

// Mounts every route the segment modules registered, each behind the
// preHandler for its auth policy, then starts their scheduled jobs.
export function bootPlatform(app: FastifyInstance): void {
  for (const r of registry.routes()) {
    app.route({ method: r.method, url: r.url, preHandler: preHandlerFor(r.auth), handler: r.handler });
  }
  startScheduler(registry.jobs());
}
EOF

    cat > src/platform/scheduler.ts <<'EOF'
import { log } from '../util/log';
import type { SegmentJob } from './registry';

// No cron daemon: each job runs on a fixed interval inside the API process,
// so every API replica runs every job.
export function startScheduler(jobs: SegmentJob[]): void {
  for (const job of jobs) {
    setInterval(() => {
      job.run().catch((err) => log.warn(`job ${job.name} failed: ${err}`));
    }, job.everyMinutes * 60_000);
  }
}
EOF

    # 110 segment modules, ~9 KB each. Each registers one route with an
    # auth policy, some a sweep job; four use the db client directly, the
    # rest go through runSql. One in four validates nothing.
    awk 'BEGIN {
      n = split("returns gift-cards loyalty invoices shipments coupons wishlists reviews refunds subscriptions bundles inventory warehouses carriers tax fraud payouts vendors catalog search recommendations notifications", domains, " ")
      seg = "src/platform/segments.ts"
      print "// One import per segment module; importing a module registers it." > seg
      for (m = 1; m <= 110; m++) {
        f = sprintf("src/modules/mod%03d.ts", m)
        printf "import \x27../modules/mod%03d\x27;\n", m > seg
        d = domains[(m - 1) % n + 1]
        table = d; gsub(/-/, "_", table)
        policy = (m % 5 == 0) ? "admin" : ((m % 3 == 0) ? "public" : "session")
        method = (m % 2 == 1) ? "POST" : "GET"
        has_job = (m % 7 == 0)
        v = m % 4
        uses_db = (m == 7 || m == 23 || m == 58 || m == 91)
        q = uses_db ? "db.query" : "runSql"

        print "import { registry } from \x27../platform/registry\x27;" > f
        if (uses_db) print "import { db } from \x27../db/client\x27;" > f
        else print "import { runSql } from \x27../db/queries\x27;" > f
        print "import { log } from \x27../util/log\x27;" > f
        print "" > f
        printf "// Segment %03d: %s for catalogue segment %03d. Registers one %s route\n", m, d, m, method > f
        printf "// (%s access)%s. Pricing rules follow.\n", policy, has_job ? ", and a sweep job" : "" > f
        printf "const SEGMENT = %d;\n\n", m > f
        printf "interface SegmentRequest%03d {\n  id?: string;\n  qty?: number;\n  note?: string;\n}\n\n", m > f
        printf "function validate%03d(body: SegmentRequest%03d): string | null {\n", m, m > f
        if (v == 0) print "  if (!body.id) return \x27id is required\x27;" > f
        if (v == 1) print "  if (body.qty === undefined || body.qty < 1 || body.qty > 99) return \x27qty must be 1-99\x27;" > f
        if (v == 2) print "  if ((body.note ?? \x27\x27).length > 280) return \x27note too long\x27;" > f
        if (v == 3) print "  // Accepts any body." > f
        print "  return null;\n}\n" > f
        printf "async function handle%03d(req: any): Promise<unknown> {\n", m > f
        printf "  const body = (req.body ?? req.query ?? {}) as SegmentRequest%03d;\n", m > f
        printf "  const problem = validate%03d(body);\n", m > f
        print "  if (problem) return { error: problem };" > f
        printf "  const res = await %s(\x27SELECT * FROM %s WHERE segment = $1 AND id = $2\x27, [SEGMENT, body.id ?? null]);\n", q, table > f
        print "  return res.rows;\n}\n" > f
        printf "registry.route({ method: \x27%s\x27, url: \x27/segments/%03d/%s\x27, auth: \x27%s\x27, handler: handle%03d });\n", method, m, d, policy, m > f
        if (has_job) {
          print "registry.job({" > f
          printf "  name: \x27%s-%03d-sweep\x27,\n  everyMinutes: %d,\n", d, m, 5 + (m % 25) > f
          print "  run: async () => {" > f
          printf "    await %s(\x27DELETE FROM %s WHERE segment = $1 AND expires_at < now()\x27, [SEGMENT]);\n", q, table > f
          printf "    log.info(\x27%s-%03d-sweep done\x27);\n  },\n});\n", d, m > f
        }
        print "" > f
        printf "// Pricing rules for segment %03d. Each rule adjusts a base price in\n", m > f
        print "// cents; rules run in declaration order." > f
        print "" > f
        for (k = 1; k <= 22; k++) {
          printf "export interface Rule%03d_%02d {\n  segment: number;\n  factor: number;\n  floorCents: number;\n}\n\n", m, k > f
          printf "export function applyRule%03d_%02d(priceCents: number, rule: Rule%03d_%02d): number {\n", m, k, m, k > f
          printf "  const scaled = Math.round(priceCents * rule.factor * %d.%02d);\n", (m % 3) + 1, k > f
          printf "  if (scaled < rule.floorCents) {\n    log.warn(`segment %03d rule %02d hit its floor`);\n    return rule.floorCents;\n  }\n", m, k > f
          print "  return scaled;\n}\n" > f
        }
        close(f)
      }
      close(seg)
      # A vendored dependency, to see whether node_modules is excluded.
      for (j = 1; j <= 40; j++) {
        f = sprintf("node_modules/fastq/lib/part%02d.js", j)
        for (i = 1; i <= 160; i++)
          printf "function worker_%02d_%03d(task, cb) { setImmediate(function () { cb(null, task * %d) }) }\n", j, i, i > f
        close(f)
      }
    }'
  fi

  expect_line src/server.ts 12 'app.listen'
  expect_line src/config.ts 5 'port:'
  expect_line src/db/client.ts 8 'export const db = new Pool'
  expect_line src/db/queries.ts 21 'db.query(sql, [id])'
  expect_line src/db/queries.ts 34 'db.query(base + where + order)'
  expect_line src/auth/session.ts 40 'export function verifySession'
  expect_line src/auth/session.ts 48 'payload.exp <= now()'
  expect_line src/jobs/cleanup.ts 15 'export async function runCleanup'
  if [ "$size" = "full" ]; then
    expect_line src/server.ts 9 'registerUserRoutes, registerOrderRoutes, registerAdminRoutes'
    expect_line src/server.ts 11 'bootPlatform(app)'
    expect_line src/platform/boot.ts 11 'app.route('
    expect_line src/platform/policies.ts 14 'export function preHandlerFor'
    expect_line src/platform/scheduler.ts 8 'setInterval'
    expect_line src/db/queries.ts 44 'export async function runSql'
  fi
}

# ----------------------------------------------------------------- log ----
# make_log FILE: 6 000 lines, 873 at level ERROR. The same numbers as the
# benchmark in SKILL.md ("grep -c ERROR app.log" -> 873).
#   DB_TIMEOUT 191, RATE_LIMIT 187, NPE 172, DISK_FULL 162, AUTH_401 161.
# Some WARN lines contain a lowercase "error", so a case-insensitive count
# is wrong.
make_log() {
  mkdir -p "$(dirname "$1")"
  awk 'BEGIN {
    prev = 0
    for (i = 1; i <= 6000; i++) {
      ts = sprintf("2026-09-19T%02d:%02d:%02d.%03dZ", int(i / 3600) % 24, int(i / 60) % 60, i % 60, (i * 7) % 1000)
      e = int(i * 873 / 6000)
      if (e > prev) {
        prev = e
        p = (e * 37) % 873
        if (p < 191) code = "DB_TIMEOUT"
        else if (p < 378) code = "RATE_LIMIT"
        else if (p < 550) code = "NPE"
        else if (p < 712) code = "DISK_FULL"
        else code = "AUTH_401"
        printf "%s ERROR [svc-%d] code=%s request_id=r%05d\n", ts, (i % 5) + 1, code, i
      } else if (i % 11 == 0) {
        printf "%s WARN  [svc-%d] retrying after transient error, attempt %d\n", ts, (i % 5) + 1, (i % 3) + 1
      } else {
        printf "%s INFO  [svc-%d] handled request_id=r%05d in %dms\n", ts, (i % 5) + 1, i, (i * 13) % 900
      }
    }
  }' > "$1"
  local n
  n="$(grep -c ' ERROR ' "$1")"
  [ "$n" = "873" ] || { echo "scaffold: $1 has $n ERROR lines, expected 873" >&2; exit 1; }
}

# -------------------------------------------------------------- agents ----
# make_agents: seven agent definitions under agents/ (not .claude/, so the
# eval session does not load them). Three call scripts/ask-gemini.ps1:
# klapp-bug-hunt.md, klapp-code-review.md, klapp-second-opinion.md.
make_agents() {
  mkdir -p agents scripts
  printf '# Forwarder to the shared ask-gemini engine.\nparam([string]$Prompt)\n' > scripts/ask-gemini.ps1
  local name calls
  for name in klapp-commit-preparer klapp-doc-sync klapp-route-test-auditor klapp-migration-check \
              klapp-bug-hunt klapp-code-review klapp-second-opinion; do
    case "$name" in
      klapp-bug-hunt|klapp-code-review|klapp-second-opinion) calls=1 ;;
      *) calls=0 ;;
    esac
    {
      printf -- '---\nname: %s\ndescription: Project helper agent (%s).\ntools: Read, Grep, Glob, Bash\n---\n\n' "$name" "$name"
      printf 'You are the %s agent for this repository.\n\n## Steps\n\n' "$name"
      printf '1. Read CLAUDE.md and the files the caller names.\n'
      printf '2. Check each claim against the code before reporting it.\n'
      if [ "$calls" = 1 ]; then
        printf '3. Get the independent pass from Gemini:\n\n'
        printf '   ```powershell\n   pwsh -NoProfile -File scripts/ask-gemini.ps1 -Tier balanced -Prompt "<task>"\n   ```\n\n'
      else
        printf '3. Run the project checks yourself; no second model is involved.\n\n'
      fi
      printf '4. Report one line per finding: severity | path:line | what is wrong.\n'
    } > "agents/$name.md"
  done
}

# -------------------------------------------------------------- config ----
# make_config_dir: 30 heterogeneous files under config/, ~600 KB. Each file
# starts with a comment that says what it is for, followed by settings
# named after that purpose (a real-looking file, not obvious filler).
make_config_dir() {
  mkdir -p config
  awk 'BEGIN {
    n = split("app.yaml|HTTP server port, request timeouts and body size limits for orders-api|server" \
      ";database.yaml|Postgres connection pool sizes and statement timeouts|pool" \
      ";redis.conf|Redis cache server memory limit and eviction policy|maxmemory" \
      ";nginx.conf|reverse proxy in front of orders-api: TLS termination and /api routing|location" \
      ";logging.json|log levels per module and the JSON log format|logger" \
      ";feature-flags.json|feature flags that switch checkout and pricing experiments on per segment|flag" \
      ";i18n-en.json|English UI and email strings|msg" \
      ";i18n-de.json|German UI and email strings|msg" \
      ";i18n-fr.json|French UI and email strings|msg" \
      ";cron.yaml|schedule for the nightly cleanup and report jobs run by the platform cron|job" \
      ";queues.yaml|message queue names, visibility timeouts and dead-letter targets|queue" \
      ";rate-limits.yaml|requests per minute allowed per route and per API key|limit" \
      ";cors.json|origins allowed to call the API from a browser|origin" \
      ";csp.txt|Content-Security-Policy header served with the admin UI|directive" \
      ";mime-types.txt|file extensions accepted for uploads and their MIME types|mime" \
      ";geoip-overrides.csv|IP ranges forced to a country when GeoIP is wrong|range" \
      ";tax-rates.csv|VAT and sales-tax rates per country and region|rate" \
      ";currency.json|supported currencies, symbols and rounding rules|currency" \
      ";email-templates.yaml|transactional email templates: order confirmation, refund, password reset|template" \
      ";sms-templates.yaml|SMS templates for delivery updates and one-time codes|template" \
      ";webhooks.yaml|outgoing webhook endpoints per partner and their signing secrets by name|webhook" \
      ";retry-policy.yaml|retry counts and backoff for calls to payment and shipping providers|retry" \
      ";cache.yaml|cache TTLs per resource type|ttl" \
      ";search-synonyms.txt|synonym lists the product search expands queries with|synonym" \
      ";stopwords.txt|words the product search ignores|stopword" \
      ";sitemap.xml|public sitemap of catalogue pages for search engines|url" \
      ";robots.txt|crawler rules for the public catalogue site|rule" \
      ";healthchecks.yaml|liveness and readiness probes for the container platform|probe" \
      ";alerts.yaml|alerting thresholds for error rate, latency and queue depth|alert" \
      ";dashboards.json|monitoring dashboards and the panels on each|panel", e, ";")
    for (i = 1; i <= n; i++) {
      split(e[i], p, "|")
      f = "config/" p[1]
      big = (p[1] ~ /^(i18n-|feature-flags|geoip|tax-rates|search-synonyms)/)
      lines = big ? 2400 : 40
      printf "# %s: %s.\n", p[1], p[2] > f
      for (j = 1; j <= lines; j++)
        printf "%s.%s_%04d = %d\n", p[3], (j % 2 ? "primary" : "secondary"), j, (i * j) % 977 > f
      close(f)
    }
  }'
}

# -------------------------------------------------------------- corpus ----
# make_corpus: curated notes/ plus a raw course.txt (~400 KB) with page
# markers "=== pN ===". Ground truth for the absence case:
#   p12 Lambda max timeout 900 s   -> MISSING (compute.md has the topic, not the value)
#   p40 SQS retention up to 14 d   -> MISSING (messaging.md has 4-day default only)
#   p77 S3 object up to 5 TB       -> PRESENT at notes/storage.md:9
make_corpus() {
  mkdir -p notes
  cat > notes/storage.md <<'EOF'
# Storage

Exam notes. Numbers are the ones the exam asks about.

## S3

- Storage classes: Standard, IA, One Zone-IA, Glacier tiers.
- Lifecycle rules move objects between classes; they do not delete versions unless told.
- S3: a single object can be up to 5 TB; use multipart upload above 100 MB.
- Versioning cannot be disabled once enabled, only suspended.
EOF
  cat > notes/compute.md <<'EOF'
# Compute

## Lambda

- Lambda: set the timeout per function; the default is 3 seconds.
- Memory from 128 MB to 10 240 MB; CPU scales with memory.
- Provisioned concurrency removes cold starts for a fixed number of instances.
EOF
  cat > notes/messaging.md <<'EOF'
# Messaging

## SQS

- SQS: the default message retention is 4 days.
- Visibility timeout defaults to 30 seconds.
- FIFO queues guarantee order within a message group.
EOF
  printf '# Networking\n\n- A VPC spans all AZs of one region.\n' > notes/networking.md
  printf '# Security\n\n- KMS keys rotate yearly when rotation is enabled.\n' > notes/security.md
  printf '# Index\n\nstorage.md, compute.md, messaging.md, networking.md, security.md\n' > notes/README.md
  awk 'BEGIN {
    for (p = 1; p <= 90; p++) {
      printf "=== p%d ===\n", p
      if (p == 12) print "The maximum Lambda timeout is 900 seconds (15 minutes)."
      if (p == 40) print "SQS retains messages for up to 14 days; the default is 4 days."
      if (p == 77) print "A single S3 object can be up to 5 TB."
      for (l = 1; l <= 70; l++)
        printf "Course page %d, paragraph %d: architecture guidance on topic %d, with worked examples and trade-offs.\n", p, l, (p * l) % 41
    }
  }' > course.txt
  expect_line notes/storage.md 9 '5 TB'
}

# -------------------------------------------------------------- vendor ----
# make_vendor_workspace: a dashboard project with a vendored Python library
# and, at the top level, a token file that must never enter an agy scope.
#   vendor/garminconnect/garminconnect/exceptions.py:14  TooManyRequests class
#   vendor/garminconnect/garminconnect/client.py:20      429 -> that exception
make_vendor_workspace() {
  mkdir -p tokens dashboard/src vendor/garminconnect/garminconnect
  printf '{ "oauth1_token": "EVAL-FIXTURE-NOT-A-REAL-TOKEN", "oauth2_refresh": "EVAL-FIXTURE-NOT-A-REAL-REFRESH" }\n' > tokens/garmin_tokens.json
  printf 'export const API = "http://localhost:3000";\n' > dashboard/src/config.ts
  printf '# dashboard\n\nSelf-hosted dashboard. Reads data through vendor/garminconnect.\n' > README.md
  cat > vendor/garminconnect/garminconnect/exceptions.py <<'EOF'
"""Exceptions raised by the Garmin Connect client."""


class GarminConnectError(Exception):
    """Base class for every error this library raises."""


class GarminConnectConnectionError(GarminConnectError):
    """The request could not be completed."""


# Raised for HTTP 429. Callers should back off; the client does not retry.
# Kept separate from the connection error so callers can tell them apart.
class GarminConnectTooManyRequestsError(GarminConnectConnectionError):
    """Garmin Connect rate-limited the request (HTTP 429)."""


class GarminConnectAuthenticationError(GarminConnectError):
    """The session is invalid or expired (HTTP 401)."""
EOF
  cat > vendor/garminconnect/garminconnect/client.py <<'EOF'
"""HTTP client for Garmin Connect."""

import requests

from .exceptions import (
    GarminConnectAuthenticationError,
    GarminConnectConnectionError,
    GarminConnectTooManyRequestsError,
)


class Client:
    def __init__(self, session: requests.Session):
        self.session = session

    def request(self, method: str, path: str, **kwargs):
        response = self.session.request(method, "https://connectapi.garmin.com" + path, **kwargs)
        if response.ok:
            return response.json()
        if response.status_code == 429:
            raise GarminConnectTooManyRequestsError(response.text)
        if response.status_code == 401:
            raise GarminConnectAuthenticationError(response.text)
        raise GarminConnectConnectionError(f"{response.status_code}: {response.text}")
EOF
  awk 'BEGIN {
    for (m = 1; m <= 40; m++) {
      f = sprintf("vendor/garminconnect/garminconnect/endpoint_%02d.py", m)
      printf "\"\"\"Endpoint group %02d.\"\"\"\n\nfrom .client import Client\n\n", m > f
      for (k = 1; k <= 60; k++)
        printf "def get_metric_%02d_%02d(client: Client, day: str):\n    return client.request(\"GET\", f\"/metrics/%02d/%02d/{day}\")\n\n", m, k, m, k > f
      close(f)
    }
  }'
  expect_line vendor/garminconnect/garminconnect/exceptions.py 14 'class GarminConnectTooManyRequestsError'
  expect_line vendor/garminconnect/garminconnect/client.py 20 'status_code == 429'
}

# --------------------------------------------------------------- photo ----
# make_photo_repo: a git repo with one committed file and an uncommitted
# change to it, so `git diff` has something to review.
#   src/photo.service.ts:9  ALLOWED_LOADERS (added by the uncommitted change)
make_photo_repo() {
  git init -q .
  git config user.email eval@example.invalid
  git config user.name eval
  mkdir -p src node_modules/sharp/src
  printf '// Loader names libvips uses for Buffer input.\n// VipsForeignLoadJpegBuffer VipsForeignLoadPngBuffer VipsForeignLoadWebpBuffer\n// VipsForeignLoadGifBuffer VipsForeignLoadTiffBuffer VipsForeignLoadHeifBuffer\n' > node_modules/sharp/src/common.cc
  cat > src/photo.service.ts <<'EOF'
import sharp from 'sharp';

export async function render(bytes: Buffer, edgePx: number): Promise<Buffer> {
  return sharp(bytes).resize(edgePx, edgePx, { fit: 'cover' }).webp().toBuffer();
}
EOF
  git add -A
  git commit -qm 'photo: render avatars'
  cat > src/photo.service.ts <<'EOF'
import sharp from 'sharp';

// Only these three decoders may run, process-wide. Every other libvips
// loader (GIF, TIFF, HEIF, SVG, ...) is blocked before any byte is parsed.
// The names are the Buffer loaders, because render() only ever receives a
// Buffer. sharp ignores names it does not know, so a typo here fails open;
// the tests in photo.service.test.ts decode one image of each format.
// Placement: module load, so the block is in force wherever render() runs.
const ALLOWED_LOADERS = ['VipsForeignLoadJpegBuffer', 'VipsForeignLoadPngBuffer', 'VipsForeignLoadWebpBuffer'];
sharp.block({ operation: ['VipsForeignLoad'] });
sharp.unblock({ operation: ALLOWED_LOADERS });

export async function render(bytes: Buffer, edgePx: number): Promise<Buffer> {
  return sharp(bytes).resize(edgePx, edgePx, { fit: 'cover' }).webp().toBuffer();
}
EOF
  expect_line src/photo.service.ts 9 'const ALLOWED_LOADERS'
}
