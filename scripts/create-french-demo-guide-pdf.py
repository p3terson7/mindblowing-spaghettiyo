#!/usr/bin/env python3
"""Generate the one-page French SAPHIR test checklist."""

from __future__ import annotations

import argparse
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    HRFlowable,
    KeepTogether,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


PAGE_WIDTH, _ = A4
MARGIN = 20 * mm
CONTENT_WIDTH = PAGE_WIDTH - (2 * MARGIN)

INK = colors.HexColor("#1D2939")
MUTED = colors.HexColor("#667085")
BLUE = colors.HexColor("#175CD3")
LINE = colors.HexColor("#D0D5DD")


def make_styles():
    base = getSampleStyleSheet()
    return {
        "title": ParagraphStyle(
            "title",
            parent=base["Title"],
            fontName="Helvetica-Bold",
            fontSize=21,
            leading=25,
            textColor=INK,
            spaceAfter=2.5 * mm,
        ),
        "lead": ParagraphStyle(
            "lead",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=10.2,
            leading=14.5,
            textColor=MUTED,
            spaceAfter=3 * mm,
        ),
        "number": ParagraphStyle(
            "number",
            parent=base["Normal"],
            fontName="Helvetica-Bold",
            fontSize=13,
            leading=16,
            textColor=BLUE,
        ),
        "heading": ParagraphStyle(
            "heading",
            parent=base["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=12.2,
            leading=15.5,
            textColor=INK,
            spaceAfter=1.2 * mm,
        ),
        "body": ParagraphStyle(
            "body",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.4,
            leading=13.3,
            textColor=INK,
        ),
        "check": ParagraphStyle(
            "check",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.35,
            leading=13.1,
            textColor=INK,
        ),
        "box": ParagraphStyle(
            "box",
            parent=base["Normal"],
            fontName="Courier-Bold",
            fontSize=8.8,
            leading=12,
            textColor=MUTED,
        ),
        "expected": ParagraphStyle(
            "expected",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.2,
            leading=13,
            textColor=colors.HexColor("#344054"),
            leftIndent=7 * mm,
            spaceBefore=1.2 * mm,
        ),
        "footer": ParagraphStyle(
            "footer",
            parent=base["Normal"],
            fontName="Helvetica",
            fontSize=7.5,
            leading=9,
            textColor=MUTED,
        ),
    }


STYLES = make_styles()


def paragraph(text: str, style: str = "body") -> Paragraph:
    return Paragraph(text, STYLES[style])


def checklist_line(text: str):
    table = Table(
        [[paragraph("[ ]", "box"), paragraph(text, "check")]],
        colWidths=[8 * mm, CONTENT_WIDTH - 18 * mm],
    )
    table.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 1.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 1.5),
            ]
        )
    )
    return table


def test_section(number: int, title: str, checks: list[str], expected: str):
    heading = Table(
        [[paragraph(f"{number}.", "number"), paragraph(title, "heading")]],
        colWidths=[9 * mm, CONTENT_WIDTH - 9 * mm],
    )
    heading.setStyle(
        TableStyle(
            [
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )

    content = [heading]
    content.extend(checklist_line(item) for item in checks)
    content.append(paragraph(f"<b>Résultat attendu:</b> {expected}", "expected"))
    content.append(Spacer(1, 2.5 * mm))
    content.append(HRFlowable(width="100%", thickness=0.45, color=LINE, spaceBefore=0, spaceAfter=3.5 * mm))
    return KeepTogether(content)


def draw_page(canvas, doc):
    canvas.saveState()
    canvas.setTitle("SAPHIR - vérifications rapides")
    canvas.setAuthor("Équipe SAPHIR")
    canvas.setSubject("Mini-checklist de validation SAPHIR")
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.45)
    canvas.line(MARGIN, 14 * mm, PAGE_WIDTH - MARGIN, 14 * mm)
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(MARGIN, 9.5 * mm, "SAPHIR - mini-checklist de test")
    canvas.drawRightString(PAGE_WIDTH - MARGIN, 9.5 * mm, "Juillet 2026")
    canvas.restoreState()


def build_story():
    story = [
        paragraph("SAPHIR - vérifications rapides", "title"),
        paragraph(
            "Pas besoin de refaire tout le parcours ni d'utiliser des comptes particuliers. Merci de vérifier seulement ces quelques cas faciles à manquer.",
            "lead",
        ),
        HRFlowable(width="100%", thickness=1.1, color=BLUE, spaceBefore=0, spaceAfter=5 * mm),
    ]

    story.append(
        test_section(
            1,
            "Premier pointage sans historique",
            [
                "Avec un employé qui n'a encore aucune entrée, démarrez des heures supplémentaires.",
                "Rechargez la page pendant le pointage, puis arrêtez-le normalement.",
            ],
            "aucune erreur ne s'affiche, le pointage actif revient après le rechargement et la nouvelle entrée apparaît <b>En attente</b>.",
        )
    )

    story.append(
        test_section(
            2,
            "Projet sans nom",
            [
                "Ajoutez un projet avec un code unique, mais laissez le nom vide.",
                "Vérifiez ce projet dans sa carte, ses détails et au moins un menu de sélection.",
                "Modifiez-le une fois sans ajouter de nom, puis ajoutez un nom et enregistrez de nouveau.",
            ],
            "le projet est accepté et son code s'affiche seul. Aucun titre vide, <font name='Courier'>CODE | CODE</font> ou doublon visuel ne devrait apparaître.",
        )
    )

    story.append(
        test_section(
            3,
            "Libellé SIGRH / HRMIS",
            [
                "Ouvrez une fiche employé en français, puis la même fiche en anglais.",
                "Essayez aussi de retrouver l'employé avec son identifiant dans la recherche.",
            ],
            "l'identifiant s'appelle <b>SIGRH</b> en français et <b>HRMIS</b> en anglais. « Code employé » et « Employee Code » ne devraient plus apparaître dans la fiche.",
        )
    )

    story.append(
        test_section(
            4,
            "Petit contrôle visuel",
            [
                "Ouvrez une entrée <b>En attente</b> en thème clair, puis en thème sombre.",
                "Jetez aussi un coup d'oeil aux cartes du tableau de bord.",
            ],
            "le statut reste facile à repérer sans colorer agressivement toute la ligne, et aucune décoration ronde inutile ne devrait apparaître dans les cartes.",
        )
    )

    story.extend(
        [
            paragraph("Si quelque chose coince", "heading"),
            paragraph(
                "Notez simplement la vue, l'étape, ce que vous attendiez et ce qui s'est passé. Une capture d'écran aide, mais pas besoin d'un long rapport.",
                "body",
            ),
        ]
    )
    return story


def generate_pdf(output_path: Path):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    document = SimpleDocTemplate(
        str(output_path),
        pagesize=A4,
        leftMargin=MARGIN,
        rightMargin=MARGIN,
        topMargin=18 * mm,
        bottomMargin=20 * mm,
        title="SAPHIR - vérifications rapides",
        author="Équipe SAPHIR",
        subject="Mini-checklist de validation SAPHIR",
        pageCompression=1,
    )
    document.build(build_story(), onFirstPage=draw_page, onLaterPages=draw_page)


def main():
    repo_root = Path(__file__).resolve().parents[1]
    default_output = repo_root / "output" / "pdf" / "SAPHIR-guide-demo-fr.pdf"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=default_output)
    args = parser.parse_args()
    generate_pdf(args.output.resolve())
    print(args.output.resolve())


if __name__ == "__main__":
    main()
