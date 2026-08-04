import pandas as pd
from typing import Optional, List, Dict, Any
from app.utils.filters import apply_filters
from app.utils.validator import validate_csv
import time
from app.metrics import observe_csv_internal_duration

_ALLOWED_AGGS = {"sum", "mean", "count", "max", "min"}

def process_csv(
    file,
    filters: Optional[Dict[str, Any]] = None,
    columns: Optional[List[str]] = None,
    grouping: Optional[List[str]] = None,
    operations: Optional[Dict[str, str]] = None,
):
    t0 = time.perf_counter()
    status = "success"

    try:
        try:
            file.seek(0)
        except Exception:
            pass

        # stable dtype inference on larger CSVs
        df = pd.read_csv(file, encoding="utf-8", on_bad_lines="error", low_memory=False)
        csv_columns = set(df.columns)

        validate_csv(df)

        if filters:
            df = apply_filters(df, filters)

        if grouping:
            missing_grouping = set(grouping) - csv_columns
            if missing_grouping:
                raise ValueError(f"Grouping columns not found: {missing_grouping}")

        if grouping and operations:
            if not isinstance(operations, dict):
                raise ValueError("Operations must be a dict of {column: agg}.")
            norm_ops: Dict[str, str] = {}
            for col, agg in operations.items():
                if col not in csv_columns:
                    raise ValueError(f"Aggregation column not found: {col}")
                if isinstance(agg, str):
                    agg_l = agg.strip().lower()
                    if agg_l not in _ALLOWED_AGGS:
                        raise ValueError(
                            f"Unsupported aggregation '{agg}' for column '{col}'. "
                            f"Allowed: {sorted(_ALLOWED_AGGS)}"
                        )
                    norm_ops[col] = agg_l
                else:
                    raise ValueError(f"Aggregation for '{col}' must be a string.")
            df = df.groupby(grouping, dropna=False).agg(norm_ops).reset_index()

        if columns:
            missing = [c for c in columns if c not in df.columns]
            if missing:
                raise ValueError(f"Requested columns not found after processing: {missing}")
            df = df[columns]

        num_cols = df.select_dtypes(include="number").columns
        if len(num_cols) > 0:
            df.loc[:, num_cols] = df.loc[:, num_cols].round(2)

        return df

    except ValueError:
        # Bad input: malformed CSV, unknown column, unsupported aggregation.
        # pandas raises ParserError, which is a ValueError. 
        status = "error"
        raise
    except Exception:
        # Anything else is a server-side failure - MemoryError under load being
        # the one that matters here. Re-raised unchanged so the route returns
        # 500.
        status = "error"
        raise
    finally:
        observe_csv_internal_duration(time.perf_counter() - t0, status=status)
