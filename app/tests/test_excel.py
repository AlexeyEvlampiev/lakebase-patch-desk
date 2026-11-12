import datetime
import io

import excel
import openpyxl
import pytest


def xlsx(*rows) -> bytes:
    wb = openpyxl.Workbook()
    for row in rows:
        wb.active.append(row)
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


HEADER = ("product_code", "field", "new_value", "reason")


def test_good_file_keeps_excel_row_numbers():
    lines = excel.read_lines(xlsx(HEADER, ("P-1", "unit_price", "2.50", "list"), ("P-2", "name", "Tea", "rename")))
    assert lines == [
        {"line_no": 2, "product_code": "P-1", "field": "unit_price", "new_value": "2.50", "reason": "list"},
        {"line_no": 3, "product_code": "P-2", "field": "name", "new_value": "Tea", "reason": "rename"},
    ]


def test_header_is_found_in_any_order_case_and_spacing_and_extra_columns_are_ignored():
    lines = excel.read_lines(
        xlsx((" Reason", "note", "NEW_VALUE", "field ", "Product_Code"), ("r", "x", "v", "f", "P"))
    )
    assert lines == [{"line_no": 2, "product_code": "P", "field": "f", "new_value": "v", "reason": "r"}]


def test_missing_column_is_named():
    with pytest.raises(excel.FileProblem, match="Missing: reason"):
        excel.read_lines(xlsx(("product_code", "field", "new_value"), ("P", "f", "v")))


def test_not_an_xlsx():
    with pytest.raises(excel.FileProblem, match="not an Excel file"):
        excel.read_lines(b"product_code,field\nP,f\n")


def test_empty_rows_are_skipped_but_row_numbers_stay_true():
    lines = excel.read_lines(xlsx(HEADER, (None, None, None, None), ("P", "f", "v", "r"), ("  ", "", None, None)))
    assert [line["line_no"] for line in lines] == [3]


def test_short_rows_fill_missing_cells_with_none():
    lines = excel.read_lines(xlsx(HEADER, ("P", "f")))
    assert lines[0]["new_value"] is None and lines[0]["reason"] is None


def test_no_lines():
    with pytest.raises(excel.FileProblem, match="no lines"):
        excel.read_lines(xlsx(HEADER))


def test_values_become_text_as_typed():
    when = datetime.datetime(2026, 11, 9, 12, 30)
    lines = excel.read_lines(
        xlsx(HEADER, (1001, "unit_price", 2.5, 3), ("P", "price", 3.0, True), ("P", "d", when, 0.1))
    )
    assert (lines[0]["product_code"], lines[0]["new_value"], lines[0]["reason"]) == ("1001", "2.5", "3")
    assert (lines[1]["new_value"], lines[1]["reason"]) == ("3", "true")
    assert (lines[2]["new_value"], lines[2]["reason"]) == ("2026-11-09T12:30:00", "0.1")


def test_row_cap():
    rows = [("P", "f", "v", "r")] * (excel.MAX_LINES + 1)
    with pytest.raises(excel.FileProblem, match="more than"):
        excel.read_lines(xlsx(HEADER, *rows))
    assert len(excel.read_lines(xlsx(HEADER, *rows[: excel.MAX_LINES]))) == excel.MAX_LINES


def test_sample_file_reads_back():
    lines = excel.read_lines(excel.sample_file())
    assert [(line["product_code"], line["field"]) for line in lines] == [r[:2] for r in excel.SAMPLE_ROWS]
    assert all(line["reason"] for line in lines)
