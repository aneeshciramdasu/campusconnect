import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.routes import router

app = FastAPI(
    title="CampusConnect API",
    description="Backend for the CampusConnect event registration app",
    version="1.0.0",
)

def get_allowed_origins():
    configured = os.getenv("CORS_ALLOWED_ORIGINS", "").strip()
    if configured:
        return [origin.strip() for origin in configured.split(",") if origin.strip()]

    return [
        "http://127.0.0.1:5500",
        "http://localhost:5500",
        "https://campusconnect-frontend-alpha-sand.vercel.app",
    ]


app.add_middleware(
    CORSMiddleware,
    allow_origins=get_allowed_origins(),
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept"],
    allow_credentials=True,
)

# Plug in all /api endpoints from routes.py
app.include_router(router)


@app.get("/", summary="Health check")
def health_check():
    return {"status": "ok", "service": "CampusConnect API", "docs_url": "/docs"}