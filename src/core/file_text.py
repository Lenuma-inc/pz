"""Bounded, text-only Office/OpenDocument/EPUB extraction and ZIP listing.

Invoked by attach.zig with isolated Python. Never extracts files or executes content.
"""
import io
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

LIMIT = 4 * 1024 * 1024
MAX_ENTRIES = 2048


def extract(source):
    with zipfile.ZipFile(source) as archive:
        entries = archive.infolist()
        if len(entries) > MAX_ENTRIES or sum(e.file_size for e in entries) > 32 * LIMIT:
            raise ValueError("document/archive exceeds extraction limits")
        names = {e.filename for e in entries}
        total = 0

        def read(name):
            nonlocal total
            info = archive.getinfo(name)
            if info.file_size > LIMIT or total + info.file_size > 8 * LIMIT:
                raise ValueError("document text exceeds extraction limits")
            total += info.file_size
            raw = archive.read(name)
            if b"<!DOCTYPE" in raw.upper() or b"<!ENTITY" in raw.upper():
                raise ValueError("XML entities are not supported")
            return ET.fromstring(raw)

        def text(root):
            out = []
            for node in root.iter():
                tag = node.tag.rsplit("}", 1)[-1]
                if tag in {"t", "p", "span", "h", "td", "th", "li", "title"} and node.text:
                    out.append(node.text)
                if tag in {"p", "row", "tr", "br", "h", "li"}:
                    out.append("\n")
            return " ".join(out)

        if "word/document.xml" in names:
            result = text(read("word/document.xml"))
        elif "xl/workbook.xml" in names:
            strings = []
            if "xl/sharedStrings.xml" in names:
                strings = ["".join(n.itertext()) for n in read("xl/sharedStrings.xml")]
            sheets = sorted(n for n in names if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n))
            out = []
            for name in sheets:
                out.append("\n" + name)
                for row in read(name).iter():
                    if row.tag.rsplit("}", 1)[-1] != "row":
                        continue
                    cells = []
                    for cell in row:
                        value = "".join(n.text or "" for n in cell.iter() if n.tag.rsplit("}", 1)[-1] in {"v", "t"})
                        if cell.get("t") == "s":
                            value = strings[int(value)]
                        cells.append(cell.get("r", "?") + "=" + value)
                    out.append("\t".join(cells))
            result = "\n".join(out)
        elif "ppt/presentation.xml" in names:
            slides = sorted((n for n in names if re.fullmatch(r"ppt/slides/slide\d+\.xml", n)),
                            key=lambda n: int(re.search(r"slide(\d+)", n).group(1)))
            result = "\n".join(name + "\n" + text(read(name)) for name in slides)
        elif "content.xml" in names and "mimetype" in names:
            result = text(read("content.xml"))
        elif "META-INF/container.xml" in names:
            result = "\n".join(name + "\n" + " ".join(read(name).itertext())
                               for name in sorted(names) if name.endswith((".xhtml", ".html", ".htm")))
        else:
            result = "ZIP directory only (entry contents not read):\n" + "\n".join(
                f"{e.filename!r}\t{e.file_size} bytes" for e in entries)
        if len(result.encode("utf-8")) > LIMIT:
            raise ValueError("extracted text exceeds limit")
        return result


def self_test():
    def packed(files):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            for name, value in files.items():
                archive.writestr(name, value)
        stream.seek(0)
        return stream

    assert "hello" in extract(packed({"word/document.xml": "<doc><p><t>hello</t></p></doc>"}))
    sheet = '<ws><row><c r="A1" t="s"><v>0</v></c><c r="C1"><v>42</v></c></row></ws>'
    assert "A1=name\tC1=42" in extract(packed({"xl/workbook.xml": "<w/>",
        "xl/sharedStrings.xml": "<s><si><t>name</t></si></s>", "xl/worksheets/sheet1.xml": sheet}))
    assert "directory only" in extract(packed({"../escape": "ignored"}))
    try:
        extract(packed({"word/document.xml": '<!DOCTYPE x [<!ENTITY e "bad">]><x>&e;</x>'}))
    except ValueError:
        pass
    else:
        raise AssertionError("accepted XML entities")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    else:
        print(extract(sys.argv[1]))
