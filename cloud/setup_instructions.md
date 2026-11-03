# Supabase Cloud Database Setup & Security Guide (Hardened Edition)

This guide walks you through setting up and verifying the cloud infrastructure in Supabase (free tier) for the **Cloud-Based PC Health Monitoring and Performance Analysis System (AEROSYS)**.

---

## 1. Security Architecture & Threat Defenses

The system implements strict defense-in-depth across database, agent, and dashboard layers to ensure production-grade security:

### A. Dynamic Cryptographic One-Time Enrollment (Anti-Squatting / Anti-Impersonation)
* **Zero Hardcoded Secrets**: No default or predictable enrollment tokens exist in the database schema or code.
* **On-Demand Admin Provisioning**: When an administrator approves a new laptop for enrollment, they generate a cryptographically random, one-time enrollment token (`ENROLL-...`).
* **Hashed Storage**: Supabase **only stores the SHA-256 hash** (`token_hash`) in `public.device_enrollment_tokens`. The raw token is never persisted in the database.
* **One-Time Provisioning**: The token is restricted to `max_uses = 1` and an expiration window (e.g., 72 hours). Once the authorized machine registers, the token is permanently exhausted (`uses_count >= max_uses`) and cannot be reused by any rogue machine.

### B. Safe Dashboard Token Delivery (No Query String Leakage)
* **The Vulnerability**: URL query strings (`?token=...`) are routinely logged in plaintext by web server access logs (e.g. Vercel, Nginx), CDN proxies, browser history databases, and transmitted in the HTTP `Referer` header to third-party assets.
* **The Defense (RFC 3986 Compliance)**:
  1. The agent NEVER puts sensitive read tokens into URL query parameters. Search parameters only contain non-sensitive hardware metadata (`device_id`, `hostname`, `cores`, etc.).
  2. For web dashboards, the token is passed exclusively in the **URL hash fragment** (`#token=...`).
  3. Per W3C specifications, fragment identifiers are processed exclusively on the client side and are **never transmitted in HTTP requests, server logs, or Referer headers**.
  4. The web dashboard immediately extracts the token upon page load and calls `window.history.replaceState(null, '', cleanUrl)` to strip the fragment from the address bar and browser history.
  5. For local dashboard runs, the agent bridges identity through `window.CURRENT_DEVICE.dashboard_token` without exposing any network URLs.

### C. Anti-IDOR Database-Level Authorization (REST & Realtime)
* **Database-Enforced Gatekeeper**: `public.check_device_read_authorization(device_id)` validates every `SELECT` query on `devices`, `metrics_raw`, `alerts`, and `metrics_hourly`.
* **Zero-Trust for WebSocket CDC**: Unauthenticated anonymous Realtime subscriptions cannot eavesdrop on active device feeds. Realtime packets are only broadcast to authorized sessions.
* **IDOR Immunity**: If a malicious viewer alters `?device_id=` to target another student's or colleague's laptop, PostgreSQL checks the token against `public.device_auth.dashboard_token_hash`. The hash mismatch results in an immediate `FALSE` evaluation, and PostgreSQL returns **0 rows (`[]`)**.

### D. Cryptographic Key Separation
* **Write Key (`device_api_key`)**: A 256-bit cryptographic key stored locally on the laptop in `agent/device_identity.json`. Used exclusively by the agent in `ingest_readings()` RPC. Never shared with the browser.
* **Read Key (`dashboard_token`)**: A distinct 192-bit cryptographic key used by viewers to query the database.
* **Public Gateway Key (`anon key`)**: Standard Supabase routing key conferring zero write or bypass privileges.

### E. Instant Revocation & Zero Direct Anonymous Writes
* Direct anonymous REST `INSERT` onto `metrics_raw` and `alerts` is revoked.
* Direct anonymous REST `UPDATE` on `devices` is revoked.
* If a machine is lost or compromised, administrators can immediately revoke it via `SELECT public.revoke_device('DEVICE-UUID');` or setting `device_auth.status = 'revoked'`, instantly halting all telemetry ingestion and dashboard access.

---

## 2. Supabase Cloud Database Setup

### Step 1: Open Your Supabase Project
1. Log in to [https://supabase.com](https://supabase.com).
2. Select your project: **`PC-Health-Monitor`**.

### Step 2: Execute `cloud/full_database_setup.sql` in the SQL Editor
1. In the Supabase project sidebar, click the **SQL Editor** (`>_` icon).
2. Click **"+ New Query"**.
3. Open the file **`cloud/full_database_setup.sql`** in this project:
   - Copy the entire SQL content.
   - Paste the SQL into the Supabase SQL Editor.
4. Click the green **"Run"** button (or press `Ctrl+Enter`).
5. Verify the query finishes with `Success. No rows returned`.

> **What this executes in order:**
> 1. `01_schema.sql`: Core tables (`devices`, `device_enrollment_tokens`, `device_auth`, `metrics_raw`, `alerts`, `metrics_hourly`), UUID generation, and indexes. (No hardcoded tokens).
> 2. `02_rls_policies.sql`: Enables RLS on all tables and deploys `check_device_read_authorization()` with Anti-IDOR header inspection.
> 3. `03_ingest_function.sql`: Deploys `ingest_readings()`, `get_authorized_device_telemetry()`, `create_device_enrollment_token()`, and `revoke_device()`.
> 4. `04_triggers.sql`: Threshold evaluation trigger (`evaluate_reading_thresholds`) and Supabase Realtime publication setup.
> 5. `05_cron_jobs.sql`: Hourly rollups and 7-day retention cleanup scheduled with `pg_cron`.

---

## 3. Provisioning Your First Laptop (Administrator Step)

Because there are **no hardcoded default enrollment secrets**, you must provision a one-time enrollment token for your laptop before first launch:

### Method A: Using the Python Helper (Recommended)
In your terminal, run:
```bash
python cloud/provision_device.py --name "My Primary Laptop"
```
This generates:
- A random one-time enrollment token (e.g., `ENROLL-9DBCB25419FA5C95536EE6C82BC6975F3789`)
- The exact SQL command to run in the Supabase SQL Editor:
  ```sql
  INSERT INTO public.device_enrollment_tokens (token_hash, token_name, max_uses, expires_at)
  VALUES (
      '54ce60bc019920f6231abe55b3fd9fa625dccb1a731e67c74e30197846bb0ad9',
      'My Primary Laptop',
      1,
      NOW() + INTERVAL '72 hours'
  );
  ```
Paste and run that SQL in your Supabase SQL Editor.

### Method B: Directly in the Supabase SQL Editor
In the Supabase SQL Editor, run:
```sql
SELECT public.create_device_enrollment_token('My Primary Laptop', 1, 72);
```
Supabase returns the plaintext token `ENROLL-...`.

---

## 4. Configure the Desktop Agent

1. In the Supabase Dashboard, click **Project Settings** (gear icon) -> **API**.
2. Copy:
   - **Project URL** (e.g., `https://xyzprojectref.supabase.co`)
   - **Project API keys -> `anon` / public** (e.g., `eyJhbGciOi...`)
3. Open `agent/.env` in your local project and configure:
   ```env
   SUPABASE_URL=https://xyzprojectref.supabase.co
   SUPABASE_KEY=your-actual-anon-key-here
   ENROLLMENT_TOKEN=ENROLL-YOUR-TOKEN-FROM-STEP-3
   DASHBOARD_URL=
   ```
   *(Keep `DASHBOARD_URL` blank until you deploy to Vercel later. While blank, the agent automatically opens your local dashboard.)*
4. Start the agent:
   ```bash
   python -m agent.main
   ```
   *(Or double-click `run_agent.bat`)*
5. The agent will sample your hardware, register itself using the one-time token, permanently bind its credentials in `public.device_auth`, and begin streaming 60-second telemetry batches to your cloud database!

---

## 5. Later: Connecting the Vercel Production URL

When you deploy the dashboard to Vercel in the future:
1. Copy your Vercel URL (e.g., `https://pc-health-monitoring.vercel.app`).
2. Open `agent/.env` and update:
   ```env
   DASHBOARD_URL=https://pc-health-monitoring.vercel.app
   ```
3. When you click **"VIEW IN WEB DASHBOARD"** in the agent, it will open your live Vercel web app with your machine's identity and pass the read token securely via URL hash fragment, leaving no token footprints in web logs or history.
