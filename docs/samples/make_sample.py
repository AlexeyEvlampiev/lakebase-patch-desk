"""Build docs/samples/product-fixes.xlsx: a patch file for the demo.

Four valid fixes, one per field, then one line for each problem the
database reports. Upload it to see every check at work; because it has
problems, it is stored as "Has problems" and cannot be approved. The app's
own "Download a sample file" gives a clean file to approve.

Values match the demo seed (db/dev/seed.sql). Rebuild with:
    python docs/samples/make_sample.py
"""

from pathlib import Path

import openpyxl

ROWS = [
    ("product_code", "field", "new_value", "reason"),
    ("P-2002", "name", "Butter croissant XL", "Bigger size from December"),  # fine
    ("P-3003", "category", "SNACK", "Sold as a snack cheese now"),  # fine
    ("P-4004", "unit_price", "1.09", "Supplier price list November"),  # fine
    ("P-5004", "active", "false", "Discontinued"),  # fine
    ("P-9999", "unit_price", "1.00", "Typo in the code"),  # product.not_found
    ("P-1003", "colour", "black", "Not a field we keep"),  # field.unknown
    ("P-4004", "unit_price", "1.19", "Second line for the same field"),  # line.duplicate
    ("P-2003", "unit_price", "2.25", ""),  # reason.required
    ("P-4002", "unit_price", "-1", "A price must be positive"),  # value.invalid
    ("P-3002", "unit_price", "2.79", "Same as today"),  # value.unchanged
]


def main() -> None:
    workbook = openpyxl.Workbook()
    sheet = workbook.active
    sheet.title = "fixes"
    for row in ROWS:
        sheet.append(row)
    out = Path(__file__).with_name("product-fixes.xlsx")
    workbook.save(out)
    print(f"wrote {out} ({len(ROWS) - 1} lines)")


if __name__ == "__main__":
    main()
