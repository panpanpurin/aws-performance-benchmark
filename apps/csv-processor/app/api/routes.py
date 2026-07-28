from fastapi import APIRouter, UploadFile, File, Form
from fastapi.responses import StreamingResponse, JSONResponse
import json
import io
import time

from app.services.csv_service import process_csv
from app.metrics import (
    maybe_record_cold_start,
    observe_csv_duration,
    begin_cpu_sample,
    end_cpu_sample_and_record,
)

router = APIRouter()


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
    except Exception as e:
        status = "error"
        return JSONResponse(status_code=400, content={"error": str(e)})
    finally:
        observe_csv_duration(time.perf_counter() - t0, status=status, fmt="csv")
        end_cpu_sample_and_record()
