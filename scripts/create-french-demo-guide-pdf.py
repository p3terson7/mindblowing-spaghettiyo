#!/usr/bin/env python3
"""Generate the plain French SAPHIR functional demo guide."""

from __future__ import annotations

import argparse
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    HRFlowable,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


PAGE_WIDTH, PAGE_HEIGHT = A4
MARGIN = 20 * mm
CONTENT_WIDTH = PAGE_WIDTH - (2 * MARGIN)
BLACK = colors.black
GRAY = colors.HexColor("#555555")
LIGHT_GRAY = colors.HexColor("#BBBBBB")


def make_styles():
    base = getSampleStyleSheet()
    return {
        "title": ParagraphStyle(
            "title",
            parent=base["Title"],
            fontName="Helvetica-Bold",
            fontSize=18,
            leading=22,
            textColor=BLACK,
            spaceAfter=3 * mm,
        ),
        "intro": ParagraphStyle(
            "intro",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=10,
            leading=14,
            textColor=BLACK,
            spaceAfter=2.5 * mm,
        ),
        "section": ParagraphStyle(
            "section",
            parent=base["Heading1"],
            fontName="Helvetica-Bold",
            fontSize=14,
            leading=17,
            textColor=BLACK,
            spaceBefore=1 * mm,
            spaceAfter=3 * mm,
        ),
        "subsection": ParagraphStyle(
            "subsection",
            parent=base["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=11.5,
            leading=14,
            textColor=BLACK,
            spaceBefore=2.5 * mm,
            spaceAfter=1.5 * mm,
        ),
        "step_number": ParagraphStyle(
            "step_number",
            parent=base["Normal"],
            fontName="Helvetica-Bold",
            fontSize=9.5,
            leading=13.5,
            textColor=BLACK,
        ),
        "step": ParagraphStyle(
            "step",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.5,
            leading=13.5,
            textColor=BLACK,
        ),
        "note": ParagraphStyle(
            "note",
            parent=base["BodyText"],
            fontName="Helvetica-Oblique",
            fontSize=8.8,
            leading=12.2,
            textColor=GRAY,
            leftIndent=6 * mm,
            spaceBefore=2 * mm,
            spaceAfter=2 * mm,
        ),
        "footer": ParagraphStyle(
            "footer",
            parent=base["Normal"],
            fontName="Helvetica",
            fontSize=7.5,
            leading=9,
            textColor=GRAY,
        ),
    }


STYLES = make_styles()


def p(text: str, style: str = "step") -> Paragraph:
    return Paragraph(text, STYLES[style])


def steps(items: list[str]):
    flowables = []
    for number, item in enumerate(items, 1):
        row = Table(
            [[p(f"{number}.", "step_number"), p(item, "step")]],
            colWidths=[8 * mm, CONTENT_WIDTH - 8 * mm],
        )
        row.setStyle(
            TableStyle(
                [
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                    ("TOPPADDING", (0, 0), (-1, -1), 2.6),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 2.6),
                ]
            )
        )
        flowables.append(row)
    return flowables


def page_header(title: str):
    return [
        p(title, "section"),
        HRFlowable(width="100%", thickness=0.7, color=BLACK, spaceBefore=0, spaceAfter=4 * mm),
    ]


def draw_page(canvas, doc):
    page_number = canvas.getPageNumber()
    canvas.saveState()
    canvas.setTitle("SAPHIR - Parcours de démonstration")
    canvas.setAuthor("Équipe SAPHIR")
    canvas.setSubject("Étapes de démonstration des fonctionnalités SAPHIR")

    canvas.setStrokeColor(LIGHT_GRAY)
    canvas.setLineWidth(0.4)
    canvas.line(MARGIN, 14 * mm, PAGE_WIDTH - MARGIN, 14 * mm)
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(GRAY)
    canvas.drawString(MARGIN, 9.5 * mm, "SAPHIR - Parcours de démonstration")
    canvas.drawRightString(PAGE_WIDTH - MARGIN, 9.5 * mm, f"Page {page_number} / 3")
    canvas.restoreState()


def build_story():
    story = [
        p("SAPHIR - Parcours de démonstration", "title"),
        p(
            "Faites les parcours permis par votre compte. Utilisez vos comptes habituels et créez seulement des éléments de test. Le but est simplement d'essayer les principales fonctionnalités de l'application.",
            "intro",
        ),
        p(
            "Pour faciliter le ménage, ajoutez <font name='Courier'>[TEST - vos initiales]</font> dans les notes ou les noms des éléments créés.",
            "note",
        ),
        Spacer(1, 2 * mm),
    ]

    story.extend(page_header("Parcours 1 - Employé"))
    story.extend(
        steps(
            [
                "Connectez-vous, puis ouvrez <b>Mes heures supp.</b>",
                "Si le choix est offert, sélectionnez la catégorie <b>Heures supp.</b>",
                "Choisissez un projet, un code d'heures supplémentaires, un mode de paiement et une raison.",
                "Cliquez sur <b>Débuter heures supp.</b>, vérifiez le résumé présenté, puis confirmez.",
                "Vérifiez que l'entrée est affichée comme active. Rechargez la page et confirmez qu'elle est toujours en cours.",
                "Cliquez sur <b>Terminer heures supp.</b>, puis confirmez.",
                "Retrouvez l'entrée dans l'activité et dans le calendrier. Vérifiez la plage horaire, la durée et le statut <b>En attente</b>.",
                "Essayez les filtres de période, de projet et de statut. Vérifiez que la liste, les totaux et les statistiques changent avec les filtres.",
                "Choisissez un mois qui contient des entrées et cliquez sur <b>Extraire le mois</b>. Vérifiez que le rapport s'ouvre dans un nouvel onglet.",
            ]
        )
    )
    story.append(p("Optionnel - si votre compte permet le type Divers", "subsection"))
    story.extend(
        steps(
            [
                "Choisissez <b>Divers</b>, écrivez une courte raison et démarrez l'entrée.",
                "Terminez l'entrée en ajoutant un résumé du travail effectué.",
                "Vérifiez que l'entrée apparaît dans votre activité sans projet, code, paiement ou code de raison.",
            ]
        )
    )
    story.append(PageBreak())

    story.extend(page_header("Parcours 2 - Superviseur"))
    story.extend(
        steps(
            [
                "Connectez-vous avec un compte admin et ouvrez <b>Vue d'ensemble</b>.",
                "Vérifiez les compteurs d'heures, les approbations en attente, les sessions actives et le nombre d'employés suivis.",
                "Consultez les projets supervisés, la file des approbations, les sessions actives et l'activité récente.",
                "Dans <b>Dossier employé</b>, cherchez une personne par son nom ou son SIGRH, puis ouvrez sa chronologie.",
                "Filtrez la chronologie par projet et par période.",
                "Ouvrez une entrée de test en attente et cliquez sur <b>Approuver</b>. Vérifiez que son statut change.",
                "Ouvrez une autre entrée de test, cliquez sur <b>Rejeter</b> et ajoutez une note de superviseur.",
                "Modifiez une entrée de test: changez une heure ou une option, enregistrez et vérifiez le résultat.",
                "Ajoutez manuellement une entrée de test pour l'employé sélectionné.",
                "Supprimez uniquement une entrée créée pour ce test et ajoutez la note demandée.",
            ]
        )
    )

    story.append(p("Révision et historique", "subsection"))
    story.extend(
        steps(
            [
                "Ouvrez <b>Révision</b> et passez entre les listes <b>En attente</b>, <b>Rejeté</b> et <b>Approuvé</b>.",
                "Filtrez par employé, projet, dates et recherche. Vérifiez que les résultats correspondent aux filtres.",
                "Approuvez une entrée depuis cette vue. Utilisez l'approbation en lot seulement sur des entrées prévues pour le test.",
                "Ouvrez <b>Historique</b> et retrouvez les approbations, rejets, modifications, ajouts et suppressions effectués pendant le parcours.",
            ]
        )
    )
    story.append(p("Un admin peut consulter largement, mais les actions de modification doivent respecter les projets dont il est responsable ou remplaçant.", "note"))
    story.append(PageBreak())

    story.extend(page_header("Parcours 3 - Personnel et projets"))
    story.append(p("Personnel", "subsection"))
    story.extend(
        steps(
            [
                "Ouvrez <b>Personnel</b> et cherchez des employés par nom, SIGRH, projet ou secteur.",
                "Ouvrez une fiche employé et consultez le résumé, les statistiques, le calendrier, les projets et les entrées.",
                "Changez de mois et de projet dans la fiche pour vérifier que les détails affichés suivent la sélection.",
                "Si votre rôle le permet, ajoutez ou modifiez un employé de test. Vérifiez le rôle, les projets assignés et les types d'entrée autorisés.",
                "Si nécessaire, testez l'archivage et la réactivation uniquement avec un profil créé pour la démonstration.",
            ]
        )
    )

    story.append(p("Projets", "subsection"))
    story.extend(
        steps(
            [
                "Ouvrez <b>Projets</b>, utilisez la recherche et changez la période affichée.",
                "Ouvrez un projet existant et consultez ses statistiques, ses graphiques et sa répartition par employé.",
                "Depuis la répartition, ouvrez une fiche employé filtrée sur ce projet.",
                "Avec un super admin, ajoutez un projet de test avec un code unique, un secteur, un admin et un admin remplaçant. Le nom peut être laissé vide.",
                "Vérifiez que le nouveau projet apparaît dans les cartes et les menus de sélection. Sans nom, son code doit servir de titre.",
                "Modifiez le projet, ajoutez ou changez son nom et ses responsables, puis enregistrez.",
                "À la fin, archivez ou supprimez uniquement le projet créé pour la démonstration.",
            ]
        )
    )

    story.append(p("Réglages et vérifications optionnelles", "subsection"))
    story.extend(
        steps(
            [
                "Ouvrez <b>Réglages</b>, changez la langue et le thème, puis rechargez la page pour vérifier que les choix sont conservés.",
                "Vérifiez l'état du système si cette section est disponible.",
                "Si GC179 est configuré, enregistrez l'en-tête de l'employé et essayez l'export d'un mois qui contient des entrées.",
                "Déconnectez-vous et reconnectez-vous pour terminer le parcours.",
            ]
        )
    )
    story.append(Spacer(1, 3 * mm))
    story.append(HRFlowable(width="100%", thickness=0.7, color=BLACK, spaceBefore=0, spaceAfter=3 * mm))
    story.append(p("Pour signaler un problème", "subsection"))
    story.append(
        p(
            "Indiquez le parcours et l'étape, votre rôle, ce que vous vouliez faire, ce qui s'est passé et, si possible, ajoutez une capture d'écran.",
            "intro",
        )
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
        title="SAPHIR - Parcours de démonstration",
        author="Équipe SAPHIR",
        subject="Étapes de démonstration des fonctionnalités SAPHIR",
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
