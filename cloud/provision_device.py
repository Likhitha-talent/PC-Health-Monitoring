"""
Administrator Device Provisioning Utility
Generates cryptographically random, one-time enrollment tokens for new laptops.
Stores only SHA-256 hashes in Supabase.
"""

import sys
import hashlib
import secrets
import argparse

def generate_enrollment_token(token_name: str = "Provisioned Laptop", max_uses: int = 1, expires_in_hours: int = 72) -> tuple:
    """
    Generates a secure random enrollment token and its SHA-256 hash.
    Returns: (raw_token, token_hash, sql_insert)
    """
    raw_token = "ENROLL-" + secrets.token_hex(18).upper()
    token_hash = hashlib.sha256(raw_token.strip().encode("utf-8")).hexdigest()

    expiry_clause = f"NOW() + INTERVAL '{expires_in_hours} hours'" if expires_in_hours > 0 else "NULL"
    sql_insert = (
        f"-- Provisioning Token for '{token_name}' (Max Uses: {max_uses}, Expires: {expires_in_hours}h)\n"
        f"INSERT INTO public.device_enrollment_tokens (token_hash, token_name, max_uses, expires_at)\n"
        f"VALUES (\n"
        f"    '{token_hash}',\n"
        f"    '{token_name}',\n"
        f"    {max_uses},\n"
        f"    {expiry_clause}\n"
        f");"
    )
    return raw_token, token_hash, sql_insert

def main():
    parser = argparse.ArgumentParser(description="Provision a secure one-time enrollment token for a new laptop.")
    parser.add_argument("--name", default="Laptop Provisioning Token", help="Descriptive name for the device/user")
    parser.add_argument("--uses", type=int, default=1, help="Maximum number of enrollments allowed (default: 1)")
    parser.add_argument("--hours", type=int, default=72, help="Token validity in hours (default: 72)")
    args = parser.parse_args()

    raw_token, token_hash, sql = generate_enrollment_token(
        token_name=args.name,
        max_uses=args.uses,
        expires_in_hours=args.hours
    )

    print("=" * 70)
    print("AEROSYS SECURE DEVICE ENROLLMENT TOKEN GENERATOR")
    print("=" * 70)
    print(f"\n[1] ONE-TIME ENROLLMENT SECRET (Give this to the user for agent/.env):")
    print(f"    ENROLLMENT_TOKEN={raw_token}\n")
    print(f"[2] SHA-256 HASH (Persisted in Database):")
    print(f"    {token_hash}\n")
    print(f"[3] SQL COMMAND TO RUN IN SUPABASE SQL EDITOR:")
    print("-" * 70)
    print(sql)
    print("-" * 70)
    print("\nSecurity Notice:")
    print("- Plaintext token is never stored in Supabase (only the SHA-256 hash is saved).")
    print("- Once the laptop enrolls, this one-time token cannot be reused.")
    print("=" * 70)

if __name__ == "__main__":
    main()

