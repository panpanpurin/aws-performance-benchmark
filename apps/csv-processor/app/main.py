# Same FastAPI app for EC2/ECS and Lambda.
# - long running: uvicorn app.main:app --host 0.0.0.0 --port 8000
# - lambda:       CMD points to app.main.handler (Mangum)
from fastapi import FastAPI
from fastapi.responses import Response
from prometheus_client import generate_latest, CONTENT_TYPE_LATEST
from mangum import Mangum

from app.api.routes import router
from app.metrics import REGISTRY

app = FastAPI(title="CSV Pokémon Processor")
app.include_router(router)


@app.get("/health")
def health_check():
    return {"status": "ok"}


@app.get("/metrics")
def metrics():
    data = generate_latest(REGISTRY)
    return Response(content=data, media_type=CONTENT_TYPE_LATEST)


# Mangum is only used when the container is a Lambda image
handler = Mangum(app)
