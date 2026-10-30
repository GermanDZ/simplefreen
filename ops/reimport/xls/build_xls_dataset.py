#!/usr/bin/env python3
"""Combine ING XLS exports for cash + CC into a single dataset, ready
for xls_diff_full.rb to consume.

Why this exists (the dedup bug that motivated it):

Naive across-file dedup by (date, amount, description) drops legitimate
bank-side twin postings. For example, the bank may post 4 distinct
fees on the same day with the same description "Recibo ACME, S.L." —
one per line item. They share (date, amount, description) but are 4
real postings; the bank's internal `store` field
disambiguates but the XLS export doesn't surface it. Dedup-by-key
would collapse them and the diff would report 3 "extra in bridge".

Strategy used here: use the OLDER export for its full date range; only
fall back to the NEWER export for dates AFTER older's max date. This
avoids dedup within a single export, and avoids double-counting across
the overlap window (the older export already captured those dates).

Usage:
  python3 build_xls_dataset.py \
      --cash older.xls newer.xls \
      --cc older-cc.xls newer-cc.xls \
      --cutoff 2026-01-01 \
      --cash-app-id <cash-account-uuid-prefix> --cc-app-id <cc-account-uuid-prefix> \
      --out /tmp/xls_rows_full.json
"""
import argparse
import json
from datetime import date, timedelta

import xlrd  # 1.2.0 — BIFF / JasperReports compatible

EXCEL_EPOCH = date(1899, 12, 30)


def excel_date_to_iso(serial):
    if not isinstance(serial, (int, float)) or serial <= 0:
        return None
    return (EXCEL_EPOCH + timedelta(days=int(serial))).isoformat()


def parse_cash_xls(path):
    """ING cash account export. Headers row 3, data row 4. Amount col 5."""
    rows = []
    wb = xlrd.open_workbook(path)
    sheet = wb.sheet_by_index(0)
    for i in range(4, sheet.nrows):
        d = excel_date_to_iso(sheet.cell_value(i, 0))
        amt = sheet.cell_value(i, 5)
        if d is None or amt == "":
            continue
        rows.append({
            "date": d,
            "amount": float(amt),
            "description": str(sheet.cell_value(i, 3)).strip(),
        })
    return rows


def parse_cc_xls(path):
    """ING CC export. Headers row 4, data row 5. Amount col 7, status col 6."""
    rows = []
    wb = xlrd.open_workbook(path)
    sheet = wb.sheet_by_index(0)
    for i in range(5, sheet.nrows):
        d = excel_date_to_iso(sheet.cell_value(i, 0))
        amt = sheet.cell_value(i, 7)
        if d is None or amt == "":
            continue
        rows.append({
            "date": d,
            "amount": float(amt),
            "description": str(sheet.cell_value(i, 3)).strip(),
            "status": str(sheet.cell_value(i, 6)).strip(),
        })
    return rows


def partitioned_combine(older_path, newer_path, parser, cutoff):
    older = [r for r in parser(older_path) if r["date"] >= cutoff] if older_path else []
    newer = [r for r in parser(newer_path) if r["date"] >= cutoff] if newer_path else []
    if not older:
        return newer
    older_max = max(r["date"] for r in older)
    return older + [r for r in newer if r["date"] > older_max]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cash", nargs="+", help="cash XLS file(s), older first")
    ap.add_argument("--cc", nargs="+", help="CC XLS file(s), older first")
    ap.add_argument("--cutoff", default="2026-01-01", help="ISO date; rows < cutoff are dropped")
    ap.add_argument("--cash-app-id", required=True, help="Sure cash Account.id prefix (8 chars)")
    ap.add_argument("--cc-app-id", required=True, help="Sure CC Account.id prefix (8 chars)")
    ap.add_argument("--out", default="/tmp/xls_rows_full.json")
    args = ap.parse_args()

    cash_files = args.cash or []
    cc_files = args.cc or []

    def reduce_combine(files, parser):
        if not files:
            return []
        result = [r for r in parser(files[0]) if r["date"] >= args.cutoff]
        for nxt in files[1:]:
            result = partitioned_combine(None, None, parser, args.cutoff) if not result else \
                     result + [r for r in parser(nxt) if r["date"] >= args.cutoff and
                              r["date"] > max(x["date"] for x in result)]
        return result

    cash = reduce_combine(cash_files, parse_cash_xls)
    cc = reduce_combine(cc_files, parse_cc_xls)

    cash.sort(key=lambda r: (r["date"], r["amount"]))
    cc.sort(key=lambda r: (r["date"], r["amount"]))

    out = {
        "cutoff_from": args.cutoff,
        "cash_account_app_id": args.cash_app_id,
        "cc_account_app_id": args.cc_app_id,
        "cash_rows": cash,
        "cc_rows": cc,
    }
    with open(args.out, "w") as f:
        json.dump(out, f, indent=2)

    print(f"wrote {args.out}")
    if cash:
        print(f"  cash: {len(cash)} rows, {cash[0]['date']}..{cash[-1]['date']}")
    if cc:
        print(f"  cc:   {len(cc)} rows, {cc[0]['date']}..{cc[-1]['date']}")


if __name__ == "__main__":
    main()
