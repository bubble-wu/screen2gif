"""Regenerate bundled AppKit vector assets from the original Lucide SVGs.

Requires ReportLab only at asset-generation time, not to build or run the app.
"""
from pathlib import Path
import xml.etree.ElementTree as ET
from reportlab.graphics import renderPDF
from reportlab.graphics.shapes import Circle, Drawing, Rect
from reportlab.graphics.svgpath import SvgPath
from reportlab.lib.colors import black

for source in (Path(__file__).resolve().parents[1] / "Resources/Lucide").glob("*.svg"):
    drawing = Drawing(24, 24)
    for element in ET.fromstring(source.read_text()):
        tag, attrs = element.tag.split("}")[-1], element.attrib
        if tag == "path":
            shape = SvgPath(attrs["d"], fillColor=None)
        elif tag == "circle":
            shape = Circle(float(attrs["cx"]), float(attrs["cy"]), float(attrs["r"]))
        elif tag == "rect":
            radius = float(attrs.get("rx", 0))
            shape = Rect(float(attrs["x"]), float(attrs["y"]),
                         float(attrs["width"]), float(attrs["height"]), rx=radius, ry=radius)
        else:
            raise ValueError(f"Unsupported SVG element: {tag}")
        shape.fillColor, shape.strokeColor = None, black
        shape.strokeWidth, shape.strokeLineCap, shape.strokeLineJoin = 2, 1, 1
        drawing.add(shape)
    drawing.transform = (1, 0, 0, -1, 0, 24)
    renderPDF.drawToFile(drawing, str(source.with_suffix(".pdf")))
