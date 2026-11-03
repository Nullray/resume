"""Verify the exported pages and preserve all visible resume text."""
import json
import re
import sys
import unicodedata
from pathlib import Path

from pypdf import PdfReader


def normalize(text):
    return re.sub(r"[\s\u200b\ufeff\u2022\u25cf]+", "", unicodedata.normalize("NFC", text))


directory = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "pdf"
report = json.loads((directory / "layout-report.json").read_text(encoding="utf-8"))
for item in report:
    reader = PdfReader(directory / item["pdfName"])
    assert len(reader.pages) == 1, f'{item["name"]}: expected exactly one page'
    page = reader.pages[0]
    assert abs(float(page.mediabox.width) - 595.28) < 1
    assert abs(float(page.mediabox.height) - 841.89) < 1
    assert normalize(page.extract_text()) == normalize(item["text"]), f'{item["name"]}: text mismatch'
    print(f'{item["name"]}: one A4 page; complete text verified')
