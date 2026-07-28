from pydantic import BaseModel
from typing import Optional, List, Dict, Any

class Filters(BaseModel):
    __root__: Dict[str, Any]

class ProcessingParams(BaseModel):
    filters: Optional[Dict[str, Any]] = None
    columns: Optional[List[str]] = None
    grouping: Optional[List[str]] = None
    operations: Optional[Dict[str]] = None
