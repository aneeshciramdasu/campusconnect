import os
from dotenv import load_dotenv
from supabase import Client, create_client

# Read backend/.env
load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL", "").strip()
SUPABASE_KEY = os.getenv("SUPABASE_KEY", "").strip()

if not SUPABASE_URL or not SUPABASE_KEY:
    raise RuntimeError("Missing SUPABASE_URL or SUPABASE_KEY in backend/.env")

# One shared connection used by the whole backend
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)


def create_user_scoped_supabase_client(access_token: str) -> Client:
    """Create a per-request client whose PostgREST identity is the verified JWT."""
    key = os.getenv("SUPABASE_USER_KEY", SUPABASE_KEY).strip()
    if key.lower().startswith("sb_secret") or "service_role" in key.lower():
        raise RuntimeError(
            "User-scoped operations require a publishable/anon Supabase key."
        )

    user_supabase = create_client(SUPABASE_URL, key)
    user_supabase.postgrest.auth(access_token)
    return user_supabase

 