#!/usr/bin/env python3
"""Generate the French SAPHIR colleague testing guide."""

from __future__ import annotations

import argparse
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.platypus import (
    HRFlowable,
    KeepTogether,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)


PAGE_WIDTH, PAGE_HEIGHT = A4
MARGIN_X = 17 * mm
TOP_MARGIN = 22 * mm
BOTTOM_MARGIN = 16 * mm
CONTENT_WIDTH = PAGE_WIDTH - (2 * MARGIN_X)

INK = colors.HexColor("#172033")
MUTED = colors.HexColor("#667085")
BLUE = colors.HexColor("#2878FF")
BLUE_DARK = colors.HexColor("#175CD3")
BLUE_PALE = colors.HexColor("#EEF5FF")
VIOLET = colors.HexColor("#7A5AF8")
VIOLET_PALE = colors.HexColor("#F3F0FF")
MINT = colors.HexColor("#12B76A")
MINT_PALE = colors.HexColor("#ECFDF3")
AMBER = colors.HexColor("#F79009")
AMBER_PALE = colors.HexColor("#FFF7E8")
ROSE = colors.HexColor("#F04465")
ROSE_PALE = colors.HexColor("#FFF1F3")
SKY = colors.HexColor("#E6F4FF")
LINE = colors.HexColor("#DDE3EC")
SURFACE = colors.HexColor("#F8FAFC")
WHITE = colors.white


def paragraph_styles():
    base = getSampleStyleSheet()
    return {
        "cover_kicker": ParagraphStyle(
            "cover_kicker",
            parent=base["Normal"],
            fontName="Helvetica-Bold",
            fontSize=9.2,
            leading=11,
            textColor=colors.HexColor("#DDEBFF"),
            tracking=1.2,
            spaceAfter=4 * mm,
        ),
        "cover_title": ParagraphStyle(
            "cover_title",
            parent=base["Title"],
            fontName="Helvetica-Bold",
            fontSize=29,
            leading=31,
            textColor=WHITE,
            alignment=TA_LEFT,
            spaceAfter=4 * mm,
        ),
        "cover_subtitle": ParagraphStyle(
            "cover_subtitle",
            parent=base["Normal"],
            fontName="Helvetica",
            fontSize=12.5,
            leading=17,
            textColor=colors.HexColor("#EAF2FF"),
        ),
        "page_title": ParagraphStyle(
            "page_title",
            parent=base["Heading1"],
            fontName="Helvetica-Bold",
            fontSize=21,
            leading=25,
            textColor=INK,
            spaceAfter=2.2 * mm,
        ),
        "page_lead": ParagraphStyle(
            "page_lead",
            parent=base["Normal"],
            fontName="Helvetica",
            fontSize=10.2,
            leading=14.2,
            textColor=MUTED,
            spaceAfter=4.5 * mm,
        ),
        "section": ParagraphStyle(
            "section",
            parent=base["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=13.2,
            leading=16,
            textColor=INK,
            spaceBefore=2.2 * mm,
            spaceAfter=2.2 * mm,
        ),
        "body": ParagraphStyle(
            "body",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.15,
            leading=13.1,
            textColor=INK,
            spaceAfter=1.7 * mm,
        ),
        "small": ParagraphStyle(
            "small",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=8.05,
            leading=11.2,
            textColor=MUTED,
        ),
        "micro": ParagraphStyle(
            "micro",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=7.25,
            leading=9.4,
            textColor=MUTED,
        ),
        "card_title": ParagraphStyle(
            "card_title",
            parent=base["Heading3"],
            fontName="Helvetica-Bold",
            fontSize=10.1,
            leading=12.4,
            textColor=INK,
            spaceAfter=1.2 * mm,
        ),
        "callout": ParagraphStyle(
            "callout",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.1,
            leading=13.1,
            textColor=INK,
        ),
        "step": ParagraphStyle(
            "step",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=8.9,
            leading=12.6,
            textColor=INK,
        ),
        "step_number": ParagraphStyle(
            "step_number",
            parent=base["Normal"],
            fontName="Helvetica-Bold",
            fontSize=8.5,
            leading=10,
            alignment=TA_CENTER,
            textColor=WHITE,
        ),
        "table_head": ParagraphStyle(
            "table_head",
            parent=base["Normal"],
            fontName="Helvetica-Bold",
            fontSize=7.5,
            leading=9.4,
            textColor=colors.HexColor("#475467"),
        ),
        "table_cell": ParagraphStyle(
            "table_cell",
            parent=base["Normal"],
            fontName="Helvetica",
            fontSize=7.8,
            leading=10.2,
            textColor=INK,
        ),
        "table_cell_bold": ParagraphStyle(
            "table_cell_bold",
            parent=base["Normal"],
            fontName="Helvetica-Bold",
            fontSize=7.8,
            leading=10.2,
            textColor=INK,
        ),
        "quote": ParagraphStyle(
            "quote",
            parent=base["BodyText"],
            fontName="Helvetica-Oblique",
            fontSize=9.4,
            leading=13.4,
            textColor=colors.HexColor("#344054"),
        ),
        "center_small": ParagraphStyle(
            "center_small",
            parent=base["Normal"],
            fontName="Helvetica-Bold",
            fontSize=8.1,
            leading=10,
            alignment=TA_CENTER,
            textColor=INK,
        ),
    }


STYLES = paragraph_styles()


def p(text: str, style: str = "body") -> Paragraph:
    return Paragraph(text, STYLES[style])


def section(title: str, accent=BLUE):
    line = Table([["", p(title, "section")]], colWidths=[2.2 * mm, CONTENT_WIDTH - 2.2 * mm])
    line.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (0, 0), accent),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (0, 0), 0),
                ("RIGHTPADDING", (0, 0), (0, 0), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 1.5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 1.5),
                ("LEFTPADDING", (1, 0), (1, 0), 7),
                ("RIGHTPADDING", (1, 0), (1, 0), 0),
            ]
        )
    )
    return line


def callout(title: str, body: str, background=BLUE_PALE, border=BLUE):
    content = p(f"<b>{title}</b><br/>{body}", "callout")
    table = Table([[content]], colWidths=[CONTENT_WIDTH])
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), background),
                ("BOX", (0, 0), (-1, -1), 0.8, border),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 8),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
            ]
        )
    )
    return table


def compact_card(title: str, body: str, background=SURFACE, border=LINE, width=None):
    width = width or CONTENT_WIDTH
    table = Table([[p(title, "card_title")], [p(body, "small")]], colWidths=[width])
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), background),
                ("BOX", (0, 0), (-1, -1), 0.65, border),
                ("LEFTPADDING", (0, 0), (-1, -1), 9),
                ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                ("TOPPADDING", (0, 0), (-1, 0), 7),
                ("BOTTOMPADDING", (0, 0), (-1, 0), 2),
                ("TOPPADDING", (0, 1), (-1, 1), 0),
                ("BOTTOMPADDING", (0, 1), (-1, 1), 7),
            ]
        )
    )
    return table


def step_rows(items, accent=BLUE, start=1, compact=False):
    rows = []
    number_width = 7.5 * mm
    for offset, item in enumerate(items):
        number = start + offset
        badge = Table([[p(str(number), "step_number")]], colWidths=[5.5 * mm], rowHeights=[5.5 * mm])
        badge.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, -1), accent),
                    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                    ("TOPPADDING", (0, 0), (-1, -1), 0),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
                ]
            )
        )
        row = Table([[badge, p(item, "step")]], colWidths=[number_width, CONTENT_WIDTH - number_width])
        pad = 2.0 if compact else 2.8
        row.setStyle(
            TableStyle(
                [
                    ("VALIGN", (0, 0), (-1, -1), "TOP"),
                    ("LEFTPADDING", (0, 0), (-1, -1), 0),
                    ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                    ("TOPPADDING", (0, 0), (-1, -1), pad),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), pad),
                    ("LINEBELOW", (1, 0), (1, 0), 0.35, colors.HexColor("#E8ECF2")),
                ]
            )
        )
        rows.append(row)
    return rows


def expected(items, title="Ce qu'on devrait voir", accent=MINT):
    rows = [[p(title, "card_title")]]
    for item in items:
        rows.append([p(f"<font color='{accent.hexval()}'>●</font>&nbsp;&nbsp;{item}", "small")])
    table = Table(rows, colWidths=[CONTENT_WIDTH])
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), MINT_PALE),
                ("BOX", (0, 0), (-1, -1), 0.7, colors.HexColor("#A6F4C5")),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                ("TOPPADDING", (0, 0), (0, 0), 7),
                ("BOTTOMPADDING", (0, -1), (0, -1), 7),
            ]
        )
    )
    return table


def page_intro(kicker: str, title: str, lead: str, accent=BLUE):
    chip = Table([[p(kicker.upper(), "table_head")]], colWidths=[44 * mm])
    chip.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.Color(accent.red, accent.green, accent.blue, alpha=0.1)),
                ("BOX", (0, 0), (-1, -1), 0.55, accent),
                ("LEFTPADDING", (0, 0), (-1, -1), 7),
                ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return [chip, Spacer(1, 3.2 * mm), p(title, "page_title"), p(lead, "page_lead")]


def two_columns(left, right, gap=5 * mm, widths=None):
    if widths is None:
        col_width = (CONTENT_WIDTH - gap) / 2
        widths = [col_width, gap, col_width]
    table = Table([[left, "", right]], colWidths=widths)
    table.setStyle(
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
    return table


def credentials_table():
    rows = [
        [p("PARCOURS", "table_head"), p("SIGRH / UTILISATEUR", "table_head"), p("MOT DE PASSE", "table_head")],
        [p("Employé avec historique<br/><b>Alice Johnson</b>", "table_cell"), p("<font name='Courier'>000200001</font>", "table_cell_bold"), p("<font name='Courier'>Demo123!</font>", "table_cell")],
        [p("Premier punch, aucune entrée<br/><b>Liam Clark</b>", "table_cell"), p("<font name='Courier'>000200025</font>", "table_cell_bold"), p("<font name='Courier'>Demo123!</font>", "table_cell")],
        [p("Admin de projets<br/><b>Camille Tremblay</b>", "table_cell"), p("<font name='Courier'>000100001</font>", "table_cell_bold"), p("<font name='Courier'>Demo123!</font>", "table_cell")],
        [p("Super admin avec fiche<br/><b>Alexandre Roy</b>", "table_cell"), p("<font name='Courier'>000100000</font>", "table_cell_bold"), p("<font name='Courier'>Demo123!</font>", "table_cell")],
        [p("Super admin technique<br/><b>Sans fiche personnelle</b>", "table_cell"), p("<font name='Courier'>admin</font>", "table_cell_bold"), p("<font name='Courier'>ChangeMe123!</font>", "table_cell")],
    ]
    table = Table(rows, colWidths=[75 * mm, 57 * mm, CONTENT_WIDTH - 132 * mm], repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#EEF2F7")),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, SURFACE]),
                ("BOX", (0, 0), (-1, -1), 0.7, LINE),
                ("INNERGRID", (0, 0), (-1, -1), 0.35, LINE),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 7),
                ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]
        )
    )
    return table


PAGE_LABELS = [
    "Bienvenue",
    "Accès et réglages",
    "Espace employé",
    "Essai à deux",
    "Supervision",
    "Fiche employé",
    "Projets et bonus",
    "Retour d'essai",
]


def draw_page(canvas, doc):
    page_number = canvas.getPageNumber()
    canvas.saveState()
    canvas.setTitle("SAPHIR - Guide d'essai entre collègues")
    canvas.setAuthor("Équipe SAPHIR")
    canvas.setSubject("Parcours de démonstration et de validation de SAPHIR")

    canvas.setFillColor(WHITE)
    canvas.rect(0, 0, PAGE_WIDTH, PAGE_HEIGHT, fill=1, stroke=0)

    if page_number == 1:
        canvas.setFillColor(colors.HexColor("#1155CC"))
        canvas.rect(0, PAGE_HEIGHT - 105 * mm, PAGE_WIDTH, 105 * mm, fill=1, stroke=0)
        canvas.setFillColor(colors.HexColor("#6941C6"))
        canvas.roundRect(PAGE_WIDTH - 58 * mm, PAGE_HEIGHT - 92 * mm, 72 * mm, 14 * mm, 7 * mm, fill=1, stroke=0)
        canvas.setFillColor(colors.HexColor("#2E90FA"))
        canvas.roundRect(PAGE_WIDTH - 78 * mm, PAGE_HEIGHT - 74 * mm, 92 * mm, 9 * mm, 4.5 * mm, fill=1, stroke=0)
    else:
        canvas.setFillColor(colors.HexColor("#F4F7FB"))
        canvas.rect(0, PAGE_HEIGHT - 11 * mm, PAGE_WIDTH, 11 * mm, fill=1, stroke=0)
        canvas.setFillColor(BLUE)
        canvas.roundRect(MARGIN_X, PAGE_HEIGHT - 7.4 * mm, 22 * mm, 2.2 * mm, 1.1 * mm, fill=1, stroke=0)
        canvas.setFont("Helvetica-Bold", 7.7)
        canvas.setFillColor(MUTED)
        canvas.drawRightString(PAGE_WIDTH - MARGIN_X, PAGE_HEIGHT - 7.2 * mm, PAGE_LABELS[page_number - 1].upper())

    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.45)
    canvas.line(MARGIN_X, 11.2 * mm, PAGE_WIDTH - MARGIN_X, 11.2 * mm)
    canvas.setFont("Helvetica", 7.3)
    canvas.setFillColor(MUTED)
    canvas.drawString(MARGIN_X, 7.1 * mm, "SAPHIR  |  Guide d'essai entre collègues  |  Juillet 2026")
    footer = f"{page_number} / {len(PAGE_LABELS)}"
    canvas.drawRightString(PAGE_WIDTH - MARGIN_X, 7.1 * mm, footer)
    canvas.restoreState()


def build_story():
    story = []

    # Page 1 - cover and ground rules.
    cover = Table(
        [[
            p("GUIDE DE DÉMONSTRATION", "cover_kicker"),
        ], [
            p("SAPHIR<br/>Guide d'essai entre collègues", "cover_title"),
        ], [
            p("Un tour guidé de l'application en 35 à 45 minutes, avec juste assez de structure pour bien tester sans transformer ça en examen.", "cover_subtitle"),
        ]],
        colWidths=[CONTENT_WIDTH - 8 * mm],
    )
    cover.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.Color(0, 0, 0, alpha=0)),
                ("LEFTPADDING", (0, 0), (-1, -1), 0),
                ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                ("TOPPADDING", (0, 0), (-1, -1), 0),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
            ]
        )
    )
    story.extend([cover, Spacer(1, 29 * mm)])

    story.append(callout(
        "Merci de donner un petit coup de main!",
        "Le but n'est pas seulement de vérifier que les boutons fonctionnent. On veut surtout savoir si l'application est claire sans explication. Si quelque chose vous fait hésiter, notez-le: c'est déjà une bonne observation.",
        background=VIOLET_PALE,
        border=VIOLET,
    ))
    story.append(Spacer(1, 5 * mm))
    story.append(section("Avant de commencer", BLUE))
    story.extend(step_rows([
        "Faites les essais dans <b>l'environnement de démonstration</b>, jamais dans les vraies données.",
        "Choisissez <b>Français</b> à l'écran de connexion. On vérifiera l'anglais un peu plus tard.",
        "Pour tester deux rôles, utilisez deux navigateurs ou une fenêtre privée. Une nouvelle connexion dans le même profil peut remplacer la session déjà ouverte.",
        "Ajoutez <font name='Courier'>[TEST - vos initiales]</font> dans les notes que vous créez. On les retrouvera plus facilement.",
        "Ne supprimez ou n'archivez que les éléments créés pour l'essai. Et aucun mot de passe dans les captures d'écran, s'il vous plaît.",
    ], accent=BLUE, compact=True))
    story.append(Spacer(1, 3 * mm))
    story.append(p("Le premier démarrage peut être un peu plus lent pendant que SAPHIR prépare sa copie locale. Fermer le navigateur n'arrête pas forcément le petit serveur local: c'est normal.", "small"))
    story.append(PageBreak())

    # Page 2 - credentials, roles, language and theme.
    story.extend(page_intro(
        "Départ",
        "Choisir son accès et prendre ses repères",
        "Les comptes ci-dessous existent seulement lorsque le jeu de présentation a été chargé. Votre responsable d'essai peut aussi vous attribuer un accès différent.",
        VIOLET,
    ))
    story.append(credentials_table())
    story.append(Spacer(1, 3.5 * mm))
    story.append(callout(
        "Attention au jeu de données",
        "Le script de présentation efface et recrée les fichiers JSON du dossier de données. Les collègues n'ont pas à l'exécuter eux-mêmes, surtout pas près des vraies données.",
        background=ROSE_PALE,
        border=ROSE,
    ))
    story.append(Spacer(1, 4 * mm))
    story.append(section("Parcours 1 - Connexion et confort visuel", VIOLET))
    story.extend(step_rows([
        "Ouvrez SAPHIR, passez l'écran de connexion en <b>Français</b>, puis connectez-vous.",
        "Ouvrez <b>Réglages</b> et essayez les thèmes <b>Système</b>, <b>Clair</b> et <b>Sombre</b>.",
        "Revenez à <b>Système</b>, rechargez la page et vérifiez que le choix est conservé.",
        "Regardez les vues disponibles dans le menu: elles doivent correspondre au rôle utilisé.",
    ], accent=VIOLET, compact=True))
    story.append(Spacer(1, 3 * mm))
    story.append(expected([
        "La langue et le thème restent choisis après le rechargement.",
        "Les textes, champs et boutons restent faciles à lire dans les trois thèmes.",
        "L'état de synchronisation finit par indiquer <b>Actif</b>.",
    ]))
    story.append(PageBreak())

    # Page 3 - employee punch and personal history.
    story.extend(page_intro(
        "Employé",
        "Faire un premier punch, même sans historique",
        "Commencez avec Liam Clark. Son compte de démonstration n'a aucune entrée: c'est le meilleur moyen de vérifier que le tout premier punch fonctionne proprement.",
        BLUE,
    ))
    story.append(callout(
        "Accès conseillé",
        "Liam Clark - SIGRH <font name='Courier'>000200025</font> - mot de passe <font name='Courier'>Demo123!</font>",
        background=BLUE_PALE,
        border=BLUE,
    ))
    story.append(Spacer(1, 3.2 * mm))
    story.extend(step_rows([
        "Ouvrez <b>Mes heures supp.</b> et choisissez le projet <font name='Courier'>OPS-410</font>.",
        "Choisissez un code d'heures supplémentaires, par exemple <font name='Courier'>260</font>, puis le paiement et la raison.",
        "Cliquez sur <b>Débuter heures supp.</b>, relisez la confirmation et confirmez.",
        "Rechargez la page pendant que le punch est encore actif. L'entrée doit toujours être là.",
        "Cliquez sur <b>Terminer heures supp.</b>, puis confirmez le punch-out.",
    ], accent=BLUE))
    story.append(Spacer(1, 3 * mm))
    story.append(expected([
        "Aucune erreur ne parle d'un paramètre <font name='Courier'>Entries</font> nul.",
        "La carte principale indique clairement que les heures sont en cours.",
        "Après le punch-out, l'entrée apparaît avec le statut <b>En attente</b>.",
        "Pour un essai très court, une durée arrondie de <font name='Courier'>00h 00</font> est possible; l'heure exacte reste enregistrée.",
    ]))
    story.append(Spacer(1, 4 * mm))
    story.append(section("Parcours 3 - Consulter ses heures", BLUE_DARK))
    story.extend(step_rows([
        "Reconnectez-vous avec Alice Johnson (<font name='Courier'>000200001</font>) et essayez <b>Ce mois-ci</b>, <b>Cette année</b> et <b>Tout</b>.",
        "Filtrez par projet et par statut. Vérifiez que le résumé et les statistiques suivent.",
        "Ouvrez un mois qui contient des entrées, puis cliquez sur <b>Extraire le mois</b>.",
    ], accent=BLUE_DARK, compact=True))
    story.append(p("L'extraction devrait s'ouvrir dans un nouvel onglet et exclure les entrées rejetées. Si rien ne s'ouvre, vérifiez simplement si le navigateur bloque les fenêtres contextuelles.", "small"))
    story.append(PageBreak())

    # Page 4 - two-role live flow.
    story.extend(page_intro(
        "Synchronisation",
        "Tester employé et superviseur en même temps",
        "Ce scénario se fait bien à deux. Sinon, ouvrez l'employé dans un navigateur et l'admin dans un autre.",
        MINT,
    ))
    left_width = (CONTENT_WIDTH - 5 * mm) / 2
    employee_lane = compact_card(
        "Côté employé",
        "<b>1.</b> Faites un nouveau punch-in.<br/><br/><b>2.</b> Terminez le punch.<br/><br/><b>3.</b> Gardez l'onglet ouvert.<br/><br/><b>4.</b> Observez le statut sans recharger manuellement.<br/><br/><b>5.</b> Recommencez avec une deuxième entrée.",
        background=BLUE_PALE,
        border=BLUE,
        width=left_width,
    )
    manager_lane = compact_card(
        "Côté superviseur",
        "<b>1.</b> Ouvrez <b>Vue d'ensemble</b> ou <b>Révision</b>.<br/><br/><b>2.</b> Trouvez la nouvelle entrée.<br/><br/><b>3.</b> Approuvez-la.<br/><br/><b>4.</b> Pour la deuxième entrée, choisissez <b>Rejeter</b>.<br/><br/><b>5.</b> Ajoutez une note <font name='Courier'>[TEST - vos initiales]</font>.",
        background=VIOLET_PALE,
        border=VIOLET,
        width=left_width,
    )
    story.append(two_columns(employee_lane, manager_lane))
    story.append(Spacer(1, 5 * mm))
    story.append(expected([
        "La nouvelle entrée arrive chez le superviseur après quelques secondes.",
        "Après l'approbation, le statut change aussi dans l'espace de l'employé.",
        "Un rejet demande une note du superviseur, et cette note reste visible dans la fiche ou l'activité.",
        "L'historique indique qui a fait l'action et quel employé est concerné.",
    ]))
    story.append(Spacer(1, 5 * mm))
    story.append(section("Petit contrôle de synchronisation", MINT))
    status_rows = [
        [p("ACTION", "table_head"), p("EMPLOYÉ", "table_head"), p("SUPERVISEUR", "table_head")],
        [p("Punch-in", "table_cell_bold"), p("Entrée active", "table_cell"), p("Session active", "table_cell")],
        [p("Punch-out", "table_cell_bold"), p("En attente", "table_cell"), p("À approuver", "table_cell")],
        [p("Approbation", "table_cell_bold"), p("Approuvé", "table_cell"), p("File mise à jour", "table_cell")],
        [p("Rejet", "table_cell_bold"), p("Rejeté + note", "table_cell"), p("Action dans l'historique", "table_cell")],
    ]
    status_table = Table(status_rows, colWidths=[43 * mm, 62 * mm, CONTENT_WIDTH - 105 * mm])
    status_table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), SURFACE),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, colors.HexColor("#FBFCFE")]),
        ("BOX", (0, 0), (-1, -1), 0.6, LINE),
        ("INNERGRID", (0, 0), (-1, -1), 0.3, LINE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    story.append(status_table)
    story.append(Spacer(1, 4 * mm))
    story.append(callout(
        "Pas de panique si ça prend un moment",
        "Attendez quelques secondes avant de rafraîchir. Notez le délai observé: c'est une information très utile pour l'équipe.",
        background=AMBER_PALE,
        border=AMBER,
    ))
    story.append(PageBreak())

    # Page 5 - supervisor path.
    story.extend(page_intro(
        "Admin",
        "Faire le tour du superviseur",
        "Utilisez Camille Tremblay. L'objectif est de vérifier les filtres, les permissions et la clarté des actions quotidiennes.",
        VIOLET,
    ))
    story.extend(step_rows([
        "Dans <b>Vue d'ensemble</b>, vérifiez les compteurs, les approbations, les sessions actives et l'activité récente.",
        "Cherchez un employé dans <b>Dossier employé</b>, puis filtrez sa chronologie par projet et par période.",
        "Ouvrez <b>Révision</b> et essayez les onglets <b>En attente</b>, <b>Rejeté</b> et <b>Approuvé</b>.",
        "Filtrez par employé, projet et dates. Le nombre d'entrées visible doit vraiment changer.",
        "Approuvez une entrée, puis rejetez-en une autre avec une note <font name='Courier'>[TEST - vos initiales]</font>.",
        "Ouvrez ensuite <b>Historique</b> et retrouvez les deux actions.",
        "Ouvrez un projet dont Camille n'est pas responsable et vérifiez que les actions sensibles restent en lecture seule.",
    ], accent=VIOLET))
    story.append(Spacer(1, 4 * mm))
    role_width = (CONTENT_WIDTH - 8 * mm) / 3
    role_cards = Table([[
        compact_card("Employé", "Voit son espace personnel et ses propres entrées.", BLUE_PALE, BLUE, role_width),
        "",
        compact_card("Admin", "Agit sur ses projets principaux et ses projets de remplacement.", VIOLET_PALE, VIOLET, role_width),
        "",
        compact_card("Super admin", "Gère les employés, les projets et les entrées sensibles.", MINT_PALE, MINT, role_width),
    ]], colWidths=[role_width, 4 * mm, role_width, 4 * mm, role_width])
    role_cards.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 0),
        ("RIGHTPADDING", (0, 0), (-1, -1), 0),
        ("TOPPADDING", (0, 0), (-1, -1), 0),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 0),
    ]))
    story.append(role_cards)
    story.append(Spacer(1, 4 * mm))
    story.append(expected([
        "Les compteurs se mettent à jour après une action.",
        "Les filtres réduisent réellement les résultats, sans perdre le contexte choisi.",
        "Les actions disponibles respectent la responsabilité de projet.",
        "L'historique relie clairement l'auteur, l'action et l'employé touché.",
    ]))
    story.append(Spacer(1, 3 * mm))
    story.append(p("<b>Essai bonus:</b> l'approbation en lot est utile, mais gardez-la pour la fin puisqu'elle modifie plusieurs entrées d'un coup.", "small"))
    story.append(PageBreak())

    # Page 6 - employee sheet and terminology.
    story.extend(page_intro(
        "Personnel",
        "Vérifier la fiche employé et le vocabulaire",
        "Cette partie teste autant la recherche que la lisibilité d'une fiche avec beaucoup d'information - et d'une fiche complètement vide.",
        BLUE_DARK,
    ))
    story.extend(step_rows([
        "Ouvrez <b>Personnel</b> et cherchez Alice Johnson par son nom.",
        "Refaites la recherche avec son SIGRH <font name='Courier'>000200001</font>.",
        "Ouvrez sa fiche et consultez le résumé, les statistiques, le calendrier et les projets.",
        "Ajoutez une entrée manuellement avec une note de test, si votre rôle permet cette action.",
        "Ouvrez ensuite Liam Clark ou Mila Roberts, qui n'ont aucune entrée dans le jeu initial.",
        "Passez temporairement l'application en anglais et rouvrez la même fiche.",
    ], accent=BLUE_DARK))
    story.append(Spacer(1, 4 * mm))
    terminology = Table(
        [
            [p("FRANÇAIS", "table_head"), p("ANGLAIS", "table_head"), p("À VÉRIFIER", "table_head")],
            [p("<b>SIGRH</b>", "table_cell"), p("<b>HRMIS</b>", "table_cell"), p("Aucune mention « Code employé » dans la fiche.", "table_cell")],
            [p("Nom du projet", "table_cell"), p("Project Name", "table_cell"), p("Le code prend la place du nom quand celui-ci est vide.", "table_cell")],
            [p("En attente", "table_cell"), p("Pending", "table_cell"), p("Le statut reste visible sans dominer toute la ligne.", "table_cell")],
        ],
        colWidths=[42 * mm, 42 * mm, CONTENT_WIDTH - 84 * mm],
    )
    terminology.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), SKY),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, SURFACE]),
        ("BOX", (0, 0), (-1, -1), 0.7, LINE),
        ("INNERGRID", (0, 0), (-1, -1), 0.35, LINE),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7),
        ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
    ]))
    story.append(terminology)
    story.append(Spacer(1, 4 * mm))
    story.append(expected([
        "La recherche fonctionne avec le nom et avec le SIGRH.",
        "En français, l'identifiant s'appelle <b>SIGRH</b>; en anglais, il s'appelle <b>HRMIS</b>.",
        "Le calendrier et les totaux correspondent aux entrées visibles.",
        "Une personne sans entrée obtient un état vide propre, sans erreur ni carte cassée.",
    ]))
    story.append(Spacer(1, 4 * mm))
    story.append(callout(
        "Question simple à se poser",
        "Est-ce que vous savez quoi regarder en premier dans cette fiche, sans que quelqu'un vous l'explique? Si la réponse est non, dites-nous ce qui attire votre attention à la place.",
        background=VIOLET_PALE,
        border=VIOLET,
    ))
    story.append(PageBreak())

    # Page 7 - nameless project and optional bonus flows.
    story.extend(page_intro(
        "Super admin",
        "Créer un projet sans nom",
        "Le numéro de dossier est obligatoire. Le nom, lui, est maintenant facultatif. On veut s'assurer que le code prend naturellement le relais partout.",
        AMBER,
    ))
    story.extend(step_rows([
        "Ouvrez <b>Projets</b>, puis cliquez sur <b>Ajouter projet</b>.",
        "Utilisez un numéro unique, par exemple <font name='Courier'>DEMO-AB-01</font>, et laissez <b>Nom du projet (facultatif)</b> vide.",
        "Ajoutez le secteur <font name='Courier'>Essais</font>, puis enregistrez.",
        "Recherchez le projet par son numéro, ouvrez ses détails et vérifiez un menu de sélection de projet.",
        "Modifiez-le pour lui ajouter un nom, puis enregistrez de nouveau.",
        "Quand l'essai est fini, archivez <b>seulement</b> ce projet de démonstration.",
    ], accent=AMBER, compact=True))
    story.append(Spacer(1, 3 * mm))
    story.append(expected([
        "Le projet est créé même si son nom est vide.",
        "Son numéro sert de titre partout où un nom est nécessaire.",
        "Aucun blanc, <font name='Courier'>undefined</font>, parenthèse inutile ou doublon <font name='Courier'>CODE | CODE</font> n'apparaît.",
        "Un numéro vide, invalide ou déjà utilisé demeure refusé.",
    ]))
    story.append(Spacer(1, 4 * mm))
    story.append(section("Deux essais bonus, si votre environnement est prêt", AMBER))
    bonus_width = (CONTENT_WIDTH - 5 * mm) / 2
    diverse = compact_card(
        "Temps « Divers »",
        "Un super admin active d'abord le droit <b>Divers</b> dans la fiche de l'employé. L'employé entre une raison au départ, puis un résumé au punch-out. Les champs de projet, code, paiement et raison d'heures supp. doivent disparaître.",
        background=VIOLET_PALE,
        border=VIOLET,
        width=bonus_width,
    )
    gc179 = compact_card(
        "Export GC179",
        "À faire seulement si Acrobat et le modèle sont configurés. Remplissez l'en-tête dans <b>Réglages</b>, choisissez un mois avec des entrées, lancez l'export et vérifiez l'identité ainsi que les lignes du mois.",
        background=BLUE_PALE,
        border=BLUE,
        width=bonus_width,
    )
    story.append(two_columns(diverse, gc179))
    story.append(Spacer(1, 4 * mm))
    story.append(p("Le jeu de présentation n'accorde pas automatiquement le droit <b>Divers</b>. Si personne ne l'a activé, passez simplement au retour d'essai.", "small"))
    story.append(PageBreak())

    # Page 8 - feedback and troubleshooting.
    story.extend(page_intro(
        "Fin",
        "Envoyer un retour qui aide vraiment",
        "Pas besoin d'écrire un roman. Quelques détails précis nous font gagner beaucoup de temps et permettent souvent de reproduire le problème du premier coup.",
        MINT,
    ))
    story.append(section("Pour chaque problème, notez ceci", MINT))
    story.extend(step_rows([
        "Votre rôle et le compte de démonstration utilisé.",
        "Le numéro du parcours et de l'étape.",
        "Ce que vous pensiez voir, puis ce qui s'est réellement passé.",
        "Si le problème arrive chaque fois ou seulement parfois.",
        "Le navigateur, l'heure approximative et une capture sans mot de passe ni donnée sensible.",
    ], accent=MINT, compact=True))
    story.append(Spacer(1, 4 * mm))
    story.append(callout(
        "Exemple de retour",
        "<b>Parcours 7, étape 4 - Super admin, Edge</b><br/>J'ai créé <font name='Courier'>DEMO-AB-01</font> sans nom. Le projet s'enregistre, mais sa carte n'a aucun titre après un rechargement. Ça arrive chaque fois.",
        background=BLUE_PALE,
        border=BLUE,
    ))
    story.append(Spacer(1, 5 * mm))
    story.append(section("Cinq questions pour terminer", VIOLET))
    questions = [
        "À quel endroit avez-vous hésité?",
        "Quelle action vous a semblé la plus naturelle?",
        "Y a-t-il trop d'information quelque part?",
        "Les couleurs et les statuts sont-ils clairs sans prendre toute la place?",
        "Feriez-vous confiance à SAPHIR pour votre vrai suivi d'heures? Pourquoi?",
    ]
    question_rows = []
    for number, question in enumerate(questions, 1):
        question_rows.append([p(str(number), "center_small"), p(question, "body"), ""])
    qtable = Table(question_rows, colWidths=[8 * mm, 92 * mm, CONTENT_WIDTH - 100 * mm])
    qstyle = [
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("LEFTPADDING", (0, 0), (-1, -1), 4),
        ("RIGHTPADDING", (0, 0), (-1, -1), 4),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("BACKGROUND", (0, 0), (0, -1), VIOLET_PALE),
        ("BOX", (0, 0), (-1, -1), 0.6, LINE),
        ("INNERGRID", (0, 0), (-1, -1), 0.3, LINE),
    ]
    for row_index in range(len(question_rows)):
        qstyle.append(("LINEBELOW", (2, row_index), (2, row_index), 0.7, colors.HexColor("#C8CFDA")))
    qtable.setStyle(TableStyle(qstyle))
    story.append(qtable)
    story.append(Spacer(1, 5 * mm))
    story.append(callout(
        "Si SAPHIR ne démarre pas",
        "Vérifiez le réseau, relancez le raccourci, puis essayez <font name='Courier'>Stop SAPHIR.bat</font> suivi de <font name='Courier'>Launch SAPHIR.bat</font>. Si ça bloque encore, transmettez le dossier <font name='Courier'>%LOCALAPPDATA%\\SAPHIR\\runtime\\logs</font> au soutien.",
        background=AMBER_PALE,
        border=AMBER,
    ))
    story.append(Spacer(1, 6 * mm))
    story.append(p("Merci! Votre hésitation, votre idée ou votre petit détail visuel peut être aussi utile qu'un bogue évident.", "quote"))

    return story


def generate_pdf(output_path: Path):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    doc = SimpleDocTemplate(
        str(output_path),
        pagesize=A4,
        leftMargin=MARGIN_X,
        rightMargin=MARGIN_X,
        topMargin=TOP_MARGIN,
        bottomMargin=BOTTOM_MARGIN,
        title="SAPHIR - Guide d'essai entre collègues",
        author="Équipe SAPHIR",
        subject="Parcours de démonstration et de validation de SAPHIR",
        pageCompression=1,
    )
    doc.build(build_story(), onFirstPage=draw_page, onLaterPages=draw_page)


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
