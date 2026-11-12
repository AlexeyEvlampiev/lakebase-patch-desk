"""Reading an uploaded patch file, and the sample file.

Only the shape is checked here: a readable .xlsx whose first row names the
four columns. Every value goes to the database as text, as typed; the
database checks the content (fn_patch_line_problems).
"""

from __future__ import annotations

import datetime
import decimal
import io
import zipfile

import openpyxl
from openpyxl.utils.exceptions import InvalidFileException

COLUMNS = ("product_code", "field", "new_value", "reason")
MAX_LINES = 1000

SAMPLE_ROWS = (
    ("P-1002", "unit_price", "2.59", "New list price from the supplier"),
    ("P-2001", "name", "Sourdough loaf 800 g", "Bigger loaf from next week"),
    ("P-1004", "active", "false", "Discontinued"),
)


class FileProblem(ValueError):
    """The file cannot be read as a patch file; the message says why."""


def cell_text(value: object) -> str | None:
    """A cell value as the text a person typed: 2.5 -> "2.5", 3.0 -> "3"."""
    if value is None:
        return None
    if isinstance(value, bool):  # before int: bool is an int
        return "true" if value else "false"
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else repr(value)
    if isinstance(value, (int, decimal.Decimal)):
        return str(value)
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    return str(value)


def read_lines(data: bytes) -> list[dict[str, object]]:
    """The file's lines as fn_submit_patch expects them: line_no is the
    Excel row number; fully empty rows are skipped."""
    try:
        workbook = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    except (InvalidFileException, zipfile.BadZipFile, KeyError, OSError) as e:
        raise FileProblem("This is not an Excel file (.xlsx).") from e
    try:
        rows = workbook.worksheets[0].iter_rows(values_only=True)
        header = next(rows, None)
        names = [str(v).strip().lower() if v is not None else "" for v in (header or ())]
        missing = [c for c in COLUMNS if c not in names]
        if missing:
            raise FileProblem(
                "The first row must name the columns " + ", ".join(COLUMNS) + ". Missing: " + ", ".join(missing) + "."
            )
        index = {c: names.index(c) for c in COLUMNS}

        lines: list[dict[str, object]] = []
        for row_number, values in enumerate(rows, start=2):
            cells = {c: cell_text(values[i]) if i < len(values) else None for c, i in index.items()}
            if all(v is None or not v.strip() for v in cells.values()):
                continue
            if len(lines) == MAX_LINES:
                raise FileProblem(f"The file has more than {MAX_LINES} lines. Split it into smaller files.")
            lines.append({"line_no": row_number, **cells})
    finally:
        workbook.close()
    if not lines:
        raise FileProblem("The file has no lines below the header.")
    return lines


def sample_file() -> bytes:
    """A small patch file on demo products, to download and try."""
    workbook = openpyxl.Workbook()
    sheet = workbook.active
    sheet.title = "fixes"
    sheet.append(COLUMNS)
    for row in SAMPLE_ROWS:
        sheet.append(row)
    out = io.BytesIO()
    workbook.save(out)
    return out.getvalue()
