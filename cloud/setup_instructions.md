# Supabase Cloud Database Setup Guide

This guide walks you through setting up the cloud infrastructure in Supabase (free tier) for the **Cloud-Based PC Health Monitoring and Performance Analysis System**.

---

### Step 1: Create a Free Supabase Project
1. Go to [https://supabase.com](https://supabase.com) and sign in.
2. Click **"New Project"**.
3. Enter:
   - **Name**: `PC-Health-Monitor`
   - **Database Password**: Choose a strong password (save this securely).
   - **Region**: Choose the closest region (e.g., `South Asia (Mumbai)`).
4. Click **Create new project** and wait ~1-2 minutes for provisioning.

---

### Step 2: Run the SQL Scripts in the Supabase SQL Editor
In your Supabase project dashboard, navigate to the **SQL Editor** (icon with `>_` on the left sidebar) and execute each file in order:

1. **`01_schema.sql`**: Creates tables (`devices`, `metrics_raw`, `alerts`, `metrics_hourly`) and indexes.
2. **`02_rls_policies.sql`**: Enables Row Level Security (RLS) for multi-tenancy and data isolation.
3. **`03_ingest_function.sql`**: Deploys the `ingest_readings()` RPC function (enabling loose coupling).
4. **`04_triggers.sql`**: Configures threshold-checking triggers and enables Supabase Realtime broadcast.
5. **`05_cron_jobs.sql`**: Schedules hourly aggregation rollups and 7-day data retention pruning.

---

### Step 3: Copy Your Project Credentials
From your Supabase Project Settings:
1. Go to **Project Settings** -> **API**.
2. Copy:
   - **Project URL** (e.g., `https://abcdefghijkl.supabase.co`)
   - **anon / public key** (e.g., `eyJhbGciOi...`)

You will paste these into:
- `agent/.env` (or configure via the Agent GUI)
- Web Dashboard (Settings modal or direct config)
