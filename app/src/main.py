"""
Minimal FastAPI service — placeholder for the actual application.
Replace with real business logic.
"""
import os
from fastapi import FastAPI

app = FastAPI(title="app", version=os.getenv("APP_VERSION", "dev"))


@app.get("/healthz")
def liveness():
    return {"status": "ok"}


@app.get("/readyz")
def readiness():
    return {"status": "ready"}


@app.get("/")
def root():
    return {"service": "app", "version": os.getenv("APP_VERSION", "dev"), "gitops": True}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("src.main:app", host="0.0.0.0", port=8080, reload=False)
