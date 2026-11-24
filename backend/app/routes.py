import os
import logging
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from app.auth import get_authenticated_user
from app.supabase_client import (
    create_public_supabase_client,
    create_user_scoped_supabase_client,
    supabase,
)

logger = logging.getLogger(__name__)


router = APIRouter(
    prefix="/api",
    tags=["CampusConnect API"]
)


def get_authenticated_user_ids(user_id: str) -> list[str]:
    user_ids = {user_id}

    try:
        mapping_res = (
            supabase.table("auth_user_mappings")
            .select("legacy_user_id")
            .eq("auth_user_id", user_id)
            .execute()
        )
        for mapping in mapping_res.data or []:
            legacy_id = mapping.get("legacy_user_id")
            if legacy_id:
                user_ids.add(str(legacy_id))
    except Exception:
        # A missing or not-yet-migrated mapping table must not grant extra access.
        pass

    return list(user_ids)


class RegistrationRequest(BaseModel):
    event_id: str


# ============================================================
# FR-02: Browse events (optional search by title)
# ============================================================

@router.get("/events", summary="Browse all campus events")
def list_events(search: Optional[str] = None):
    try:
        public_supabase = create_public_supabase_client()
        query = public_supabase.table("events").select(
            "id, title, capacity, status, organizer_id"
        ).eq("status", "open")

        if search:
            query = query.ilike("title", f"%{search}%")

        response = query.execute()
        return response.data
    except RuntimeError as error:
        logger.error("Public Supabase event client configuration error")
        raise HTTPException(
            status_code=503,
            detail="Event service configuration is incomplete",
        ) from error
    except Exception as error:
        logger.exception("Failed to fetch public events")
        raise HTTPException(
            status_code=502,
            detail="Unable to load events",
        ) from error


# ============================================================
# FR-03: Get event details and available seats
# ============================================================

@router.get("/events/{event_id}", summary="Get single event details")
def get_event_details(event_id: str):
    try:
        public_supabase = create_public_supabase_client()
        event_res = (
            public_supabase.table("events")
            .select("*")
            .eq("id", event_id)
            .eq("status", "open")
            .execute()
        )
    except RuntimeError as error:
        raise HTTPException(
            status_code=503,
            detail="Event service configuration is incomplete",
        ) from error
    except Exception as error:
        logger.exception("Failed to fetch event details")
        raise HTTPException(
            status_code=502,
            detail="Unable to load event details",
        ) from error

    if not event_res.data:
        raise HTTPException(
            status_code=404,
            detail="Event not found"
        )

    event = event_res.data[0]

    count_res = (
        supabase.table("registrations")
        .select("id", count="exact")
        .eq("event_id", event_id)
        .execute()
    )

    booked = count_res.count or 0

    return {
        **event,
        "booked_seats": booked,
        "seats_left": max(0, event["capacity"] - booked)
    }


# ============================================================
# FR-04: Register student for an event
# Registration remains disabled until the database migration is reviewed and tested.
# ============================================================

@router.post(
    "/registrations",
    status_code=status.HTTP_201_CREATED,
    summary="Register for an event"
)
def register_for_event(
    payload: RegistrationRequest,
    authenticated_user=Depends(get_authenticated_user)
):
    registration_enabled = os.getenv("REGISTRATION_ENABLED", "false").strip().lower()
    if registration_enabled not in {"1", "true", "yes"}:
        raise HTTPException(
            status_code=503,
            detail="Registration is temporarily disabled",
        )

    try:
        user_supabase = create_user_scoped_supabase_client(
            authenticated_user.access_token
        )
    except RuntimeError:
        raise HTTPException(
            status_code=503,
            detail="Registration service configuration is incomplete",
        )

    try:
        response = user_supabase.rpc(
            "register_for_event",
            {"p_event_id": payload.event_id},
        ).execute()
    except Exception as error:
        code = str(getattr(error, "code", "")).upper()
        message = str(getattr(error, "message", error)).lower()

        if code == "23505" or "duplicate" in message:
            raise HTTPException(status_code=409, detail="DUPLICATE_REGISTRATION")
        if code in {"P0001", "EVENT_FULL"} or "event full" in message:
            raise HTTPException(status_code=409, detail="EVENT_FULL")
        if code == "P0002" or "not found" in message:
            raise HTTPException(status_code=404, detail="Event not found")
        if code == "22023" or "closed" in message:
            raise HTTPException(status_code=400, detail="Event is closed for registration")
        if code == "42501" or "auth" in message or "profile" in message:
            raise HTTPException(status_code=403, detail="Forbidden")

        raise HTTPException(
            status_code=502,
            detail="Registration service is unavailable",
        )

    if not response.data:
        raise HTTPException(
            status_code=502,
            detail="Registration service returned no result",
        )

    new_registration = response.data
    if isinstance(new_registration, list):
        new_registration = new_registration[0] if new_registration else None

    if not new_registration:
        raise HTTPException(
            status_code=502,
            detail="Registration service returned no result",
        )

    return {
        "id": new_registration.get("id"),
        "event_id": payload.event_id,
        "status": "REGISTERED",
    }


# ============================================================
# FR-06: Get current student's registrations
# ============================================================

@router.get("/me/registrations", summary="My registrations")
def get_my_registrations(
    authenticated_user=Depends(get_authenticated_user)
):
    user_ids = get_authenticated_user_ids(authenticated_user.id)

    query = (
        supabase.table("registrations")
        .select("id, created_at, events(id, title, capacity, status)")
    )

    if len(user_ids) == 1:
        query = query.eq("user_id", user_ids[0])
    else:
        query = query.in_("user_id", user_ids)

    return query.execute().data


# ============================================================
# FR-07: Get attendees for an event owned by the organizer
# ============================================================

@router.get(
    "/events/{event_id}/registrations",
    summary="Attendees for an event you own"
)
def get_event_attendees(
    event_id: str,
    authenticated_user=Depends(get_authenticated_user)
):
    user_ids = get_authenticated_user_ids(authenticated_user.id)

    # Guard 2: Check event ownership
    event_res = (
        supabase.table("events")
        .select("organizer_id")
        .eq("id", event_id)
        .execute()
    )

    if not event_res.data:
        raise HTTPException(
            status_code=404,
            detail="Event not found"
        )

    organizer_id = str(event_res.data[0]["organizer_id"])
    if organizer_id not in user_ids:
        raise HTTPException(
            status_code=403,
            detail="Forbidden: you can only view attendees for events you own"
        )

    # Guard 3: Fetch attendees
    res = (
        supabase.table("registrations")
        .select("id, created_at, users(id, email, role)")
        .eq("event_id", event_id)
        .execute()
    )

    return res.data