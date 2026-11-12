"""Build the demo story files in docs/samples/story/: one file per outcome.

The screenshots (and anyone trying the demo) use them to fill every page
with a realistic mix of change requests:

- story-1-price-update.xlsx: approved, then sent to the lakehouse;
- story-2-winter-range.xlsx: rejected with a note;
- story-3-bakery-prices.xlsx: left waiting for approval.

Each file changes different products, so approving one never makes another
stale, and none touches the three rows the AI agent is meant to find
(P-3005, P-4005, P-5005 in db/dev/seed.sql). Rebuild with:
    python docs/samples/make_story.py
"""

from pathlib import Path

import openpyxl

HEADER = ("product_code", "field", "new_value", "reason")

STORY = {
    "story-1-price-update.xlsx": [
        ("P-1001", "unit_price", "0.95", "Supplier price list December"),
        ("P-3001", "unit_price", "1.25", "Supplier price list December"),
        ("P-4001", "name", "Sea salt crisps 175 g", "Bigger bag from the supplier"),
    ],
    "story-2-winter-range.xlsx": [
        ("P-2004", "unit_price", "2.10", "Seasonal price for the winter range"),
        ("P-4003", "active", "false", "Out of the winter range"),
    ],
    "story-3-bakery-prices.xlsx": [
        ("P-2002", "unit_price", "1.35", "Butter cost went up"),
        ("P-3004", "unit_price", "3.19", "Butter cost went up"),
    ],
}


def main() -> None:
    out_dir = Path(__file__).with_name("story")
    out_dir.mkdir(exist_ok=True)
    for name, rows in STORY.items():
        workbook = openpyxl.Workbook()
        sheet = workbook.active
        sheet.title = "fixes"
        sheet.append(HEADER)
        for row in rows:
            sheet.append(row)
        workbook.save(out_dir / name)
        print(f"wrote {out_dir / name} ({len(rows)} lines)")


if __name__ == "__main__":
    main()
