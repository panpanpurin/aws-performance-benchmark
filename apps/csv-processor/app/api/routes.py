from fastapi import APIRouter, UploadFile, File, Form
from fastapi.responses import StreamingResponse, JSONResponse
import json
import io
import logging
import time

from app.services.csv_service import process_csv
from app.metrics import (
    maybe_record_cold_start,
    observe_csv_duration,
    begin_cpu_sample,
    end_cpu_sample_and_record,
)

logger = logging.getLogger(__name__)

router = APIRouter()

# Upload ceiling. The Function URL is reachable without authentication, so an
# unbounded upload would be read straight into pandas on a 1 GB Lambda. The
# benchmark fixtures are far below this, so the limit does not affect results.
MAX_UPLOAD_BYTES = 16 * 1024 * 1024


@router.post("/process")
async def process(
    file: UploadFile = File(...),
    filters: str = Form(default=None),
    columns: str = Form(default=None),
    grouping: str = Form(default=None),
    operations: str = Form(default=None),
):
    maybe_record_cold_start()
    begin_cpu_sample()
    t0 = time.perf_counter()
    status = "success"

    try:
        size = getattr(file, "size", None)
        if size is not None and size > MAX_UPLOAD_BYTES:
            raise ValueError(
                f"Upload exceeds the {MAX_UPLOAD_BYTES // (1024 * 1024)} MB limit"
            )

        filters_dict = json.loads(filters) if filters else None
        columns_list = json.loads(columns) if columns else None
        grouping_list = json.loads(grouping) if grouping else None
        operations_list = json.loads(operations) if operations else None

        df = process_csv(
            file.file,
            filters=filters_dict,
            columns=columns_list,
            grouping=grouping_list,
            operations=operations_list,
        )

        stream = io.StringIO()
        df.to_csv(stream, index=False)
        stream.seek(0)

        return StreamingResponse(
            stream,
            media_type="text/csv",
            headers={"Content-Disposition": "attachment; filename=processed.csv"},
        )
    except ValueError as e:
        # Validation failures are meaningful to the caller and are returned as-is.
        status = "error"
        return JSONResponse(status_code=400, content={"error": str(e)})
    except Exception:
        # Unexpected failures are logged server-side; the response stays generic
        # so internal details are not exposed on a public endpoint.
        status = "error"
        logger.exception("Unhandled error while processing CSV")
        return JSONResponse(
            status_code=500, content={"error": "Internal processing error"}
        )
    finally:
        observe_csv_duration(time.perf_counter() - t0, status=status, fmt="csv")
        end_cpu_sample_and_record()
