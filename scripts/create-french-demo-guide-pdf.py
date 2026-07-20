#!/usr/bin/env python3
"""Generate the detailed French SAPHIR functional demo guide."""

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
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
)


PAGE_WIDTH, _ = A4
MARGIN = 18 * mm
BLACK = colors.black
TOTAL_PAGES = 6


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
            alignment=0,
            spaceAfter=2.5 * mm,
        ),
        "intro": ParagraphStyle(
            "intro",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=9.4,
            leading=13,
            textColor=BLACK,
            spaceAfter=2 * mm,
        ),
        "section": ParagraphStyle(
            "section",
            parent=base["Heading1"],
            fontName="Helvetica-Bold",
            fontSize=14,
            leading=17,
            textColor=BLACK,
            spaceBefore=1 * mm,
            spaceAfter=2 * mm,
        ),
        "test_title": ParagraphStyle(
            "test_title",
            parent=base["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=10.2,
            leading=12.5,
            textColor=BLACK,
            spaceAfter=1.1 * mm,
        ),
        "detail": ParagraphStyle(
            "detail",
            parent=base["BodyText"],
            fontName="Helvetica",
            fontSize=8.7,
            leading=11.7,
            textColor=BLACK,
            leftIndent=4 * mm,
            spaceAfter=0.8 * mm,
        ),
        "note": ParagraphStyle(
            "note",
            parent=base["BodyText"],
            fontName="Helvetica-Oblique",
            fontSize=8.5,
            leading=11.5,
            textColor=BLACK,
            leftIndent=4 * mm,
            spaceBefore=1 * mm,
            spaceAfter=2 * mm,
        ),
    }


STYLES = make_styles()


def p(text: str, style: str = "detail") -> Paragraph:
    return Paragraph(text, STYLES[style])


def page_header(title: str):
    return [
        p(title, "section"),
        HRFlowable(width="100%", thickness=0.7, color=BLACK, spaceBefore=0, spaceAfter=3 * mm),
    ]


def test_case(number: int, title: str, condition: str, action: str, expected: str, optional: bool = False):
    prefix = "Optionnel - " if optional else ""
    return KeepTogether(
        [
            p(f"[ ] Test {number} - {prefix}{title}", "test_title"),
            p(f"<b>Condition:</b> {condition}"),
            p(f"<b>À faire:</b> {action}"),
            p(f"<b>À vérifier:</b> {expected}"),
            Spacer(1, 1.3 * mm),
            HRFlowable(width="100%", thickness=0.3, color=BLACK, spaceBefore=0, spaceAfter=2.2 * mm),
        ]
    )


def draw_page(canvas, doc):
    page_number = canvas.getPageNumber()
    canvas.saveState()
    canvas.setTitle("SAPHIR - Parcours de démonstration détaillé")
    canvas.setAuthor("Équipe SAPHIR")
    canvas.setSubject("Tests fonctionnels guidés pour SAPHIR")
    canvas.setStrokeColor(BLACK)
    canvas.setLineWidth(0.3)
    canvas.line(MARGIN, 14 * mm, PAGE_WIDTH - MARGIN, 14 * mm)
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(BLACK)
    canvas.drawString(MARGIN, 9.5 * mm, "SAPHIR - Parcours de démonstration détaillé")
    canvas.drawRightString(PAGE_WIDTH - MARGIN, 9.5 * mm, f"Page {page_number} / {TOTAL_PAGES}")
    canvas.restoreState()


def build_story():
    story = [
        p("SAPHIR - Parcours de démonstration détaillé", "title"),
        p(
            "Utilisez vos comptes habituels. Faites seulement les tests permis par votre rôle et ne modifiez que des entrées, employés ou projets réservés aux essais.",
            "intro",
        ),
        p(
            "Astuce: ajoutez <font name='Courier'>[TEST - vos initiales]</font> dans les notes et les noms créés. Les tests marqués Optionnel demandent un droit ou une configuration particulière.",
            "note",
        ),
    ]

    story.extend(page_header("1 - Employé: démarrer et terminer un pointage"))
    story.extend(
        [
            test_case(
                1,
                "Premier pointage sans historique",
                "Utilisez un compte de test qui ne possède encore aucune entrée et aucun pointage actif.",
                "Ouvrez <b>Mes heures supp.</b>, choisissez un projet et un paiement, puis démarrez un court pointage.",
                "Le pointage démarre sans erreur liée à une liste d'entrées vide. Une session active est créée et le bouton devient <b>Terminer heures supp.</b>",
            ),
            test_case(
                2,
                "Champs obligatoires et facultatifs",
                "Aucun pointage n'est en cours.",
                "Essayez d'abord sans projet, puis sans paiement. Recommencez avec projet et paiement, mais laissez <b>Code supp.</b> et <b>Code raison</b> vides.",
                "Sans projet ou paiement, le démarrage est bloqué. Le code supp. et le code raison sont facultatifs et ne doivent pas empêcher le pointage.",
            ),
            test_case(
                3,
                "Confirmation et conservation des choix",
                "Aucun pointage n'est en cours et tous les choix voulus sont remplis.",
                "Cliquez sur <b>Débuter heures supp.</b>, comparez le projet, le code, le paiement et la raison dans la confirmation, puis confirmez.",
                "La confirmation reprend exactement les choix. Après le démarrage, la page indique l'heure de début et les détails restent associés à la session.",
            ),
            test_case(
                4,
                "Session active après actualisation",
                "Le pointage du test précédent est encore ouvert.",
                "Actualisez la page, naviguez vers une autre section, puis revenez dans <b>Mes heures supp.</b>",
                "La même session est toujours active, sans doublon. La durée continue d'augmenter et les contrôles de démarrage sont remplacés par la fin du pointage.",
            ),
            test_case(
                5,
                "Fin du pointage et statut initial",
                "Une session d'heures supplémentaires est active.",
                "Cliquez sur <b>Terminer heures supp.</b>, confirmez, puis ouvrez l'entrée dans l'activité et le calendrier.",
                "La session disparaît des sessions actives. L'entrée possède une fin, une durée positive et le statut <b>En attente</b>.",
            ),
        ]
    )

    story.append(PageBreak())
    story.extend(page_header("1 - Employé: cas particuliers et consultation"))
    story.extend(
        [
            test_case(
                6,
                "Validation d'une entrée Divers",
                "Le compte autorise le type <b>Divers</b> et aucun pointage n'est actif.",
                "Choisissez Divers et essayez de démarrer sans raison. Ajoutez ensuite une raison, démarrez, puis essayez de terminer sans résumé avant d'en ajouter un.",
                "La raison est exigée au démarrage et le résumé à la fin. Une fois terminée, l'entrée conserve les deux textes sans projet, code supp., paiement ni code raison.",
                optional=True,
            ),
            test_case(
                7,
                "Filtres et remise à zéro des statistiques",
                "Le compte contient des entrées sur plusieurs dates, projets ou statuts.",
                "Essayez <b>Ce mois-ci</b>, <b>Cette année</b>, <b>Tout</b> et <b>Personnalisé</b>, puis filtrez par projet et statut. Terminez avec <b>Réinitialiser</b>.",
                "Le nombre d'entrées, le total, la moyenne, le maximum et la répartition changent avec les filtres. Réinitialiser revient au mois courant, tous projets et tous statuts.",
            ),
            test_case(
                8,
                "Mois vide, calendrier et heures exactes",
                "Le compte possède au moins une entrée et un mois sans entrée est disponible.",
                "Ouvrez d'abord le mois vide, puis un mois rempli. Ouvrez le détail d'une entrée dont l'heure exacte a été arrondie.",
                "Le mois vide affiche un message clair. Le mois rempli place l'entrée à la bonne date et le détail distingue, lorsqu'elles diffèrent, la plage exacte de la plage arrondie.",
            ),
            test_case(
                9,
                "Extraction mensuelle",
                "Choisissez un mois contenant des entrées approuvées, en attente, rejetées ou Divers si possible.",
                "Cliquez sur <b>Extraire le mois</b> et comparez les lignes et le total avec l'activité du même mois.",
                "Le nouvel onglet montre le bon employé et le bon mois. Les entrées d'heures supp. approuvées ou en attente sont incluses; les entrées rejetées et Divers sont exclues.",
            ),
            test_case(
                10,
                "Retour d'approbation ou de rejet",
                "Un superviseur a traité deux entrées de test, une approuvée et une rejetée avec une note.",
                "Actualisez <b>Mes heures supp.</b>, filtrez par statut et ouvrez les deux entrées.",
                "Les statuts <b>Approuvé</b> et <b>Rejeté</b> sont visibles. La note du superviseur apparaît sur l'entrée rejetée et les statistiques reflètent les nouveaux statuts.",
            ),
        ]
    )

    story.append(PageBreak())
    story.extend(page_header("2 - Superviseur: traitement d'une entrée"))
    story.extend(
        [
            test_case(
                11,
                "Passage de session active à approbation",
                "Gardez un compte employé et un compte superviseur ouverts dans deux navigateurs.",
                "Démarrez un pointage côté employé, actualisez la <b>Vue d'ensemble</b>, puis terminez le pointage et actualisez de nouveau.",
                "Pendant le pointage, l'entrée apparaît dans <b>Sessions actives</b> et n'est pas approvable. Après la fin, elle quitte cette liste et apparaît dans les approbations en attente.",
            ),
            test_case(
                12,
                "Approbation d'une entrée fermée",
                "Une entrée de test terminée est au statut En attente sur un projet modifiable.",
                "Cliquez sur <b>Approuver</b>, puis consultez les onglets En attente et Approuvé ainsi que le compte employé.",
                "L'entrée quitte En attente, apparaît dans Approuvé et porte le même statut chez l'employé. Les compteurs sont mis à jour après actualisation.",
            ),
            test_case(
                13,
                "Rejet avec note obligatoire",
                "Une autre entrée de test terminée est en attente.",
                "Cliquez sur <b>Rejeter</b> et essayez de continuer sans note. Recommencez avec une note <font name='Courier'>[TEST - initiales]</font>.",
                "Sans note, le rejet ne change rien. Avec la note, l'entrée passe à Rejeté, la note est visible chez l'employé et l'action est inscrite dans l'historique.",
            ),
            test_case(
                14,
                "Ajout manuel et validation des heures",
                "Un employé et un projet de test modifiable sont disponibles.",
                "Dans <b>Dossier employé</b>, ajoutez une entrée avec une fin égale ou antérieure au début. Corrigez ensuite avec 10:08 à 10:52, un projet et un paiement.",
                "La première saisie est refusée. La saisie valide produit une plage arrondie de 10:15 à 10:45, une durée de 00h 30 et conserve la plage exacte de 10:08 à 10:52.",
            ),
            test_case(
                15,
                "Modification avec justification",
                "Utilisez uniquement l'entrée manuelle créée pour le test.",
                "Ouvrez <b>Modifier</b>, essayez sans note superviseur, puis ajoutez une note et changez une heure ou une option. Essayez enfin d'enregistrer de nouveau sans changement.",
                "La note est obligatoire. Le changement valide est conservé et recalculé. Une deuxième sauvegarde identique indique qu'aucun changement n'a été détecté.",
            ),
        ]
    )

    story.append(PageBreak())
    story.extend(page_header("2 - Superviseur: révision, droits et historique"))
    story.extend(
        [
            test_case(
                16,
                "Suppression avec justification",
                "L'entrée visée a été créée uniquement pour ce parcours.",
                "Cliquez sur <b>Supprimer</b>, essayez sans note, puis recommencez avec une note et confirmez.",
                "Sans note, rien n'est supprimé. Avec la note, l'entrée disparaît de la fiche et des totaux, mais sa suppression reste visible dans l'historique.",
            ),
            test_case(
                17,
                "Onglets, recherche et filtres de Révision",
                "Des entrées de test existent dans au moins deux statuts ou pour deux employés.",
                "Ouvrez <b>Révision</b>, passez entre En attente, Rejeté et Approuvé, puis filtrez par employé, projet, dates et recherche avant de réinitialiser.",
                "Le nombre affiché sur chaque onglet correspond à sa liste. Les filtres se combinent et la remise à zéro restaure toutes les entrées accessibles.",
            ),
            test_case(
                18,
                "Approbation en lot limitée aux filtres",
                "Plusieurs entrées de test fermées et en attente sont disponibles.",
                "Filtrez sur un seul employé ou projet, cliquez sur <b>Approuver la sélection en lot</b> et vérifiez le nombre dans la confirmation.",
                "Seules les entrées filtrées, fermées, en attente et modifiables sont approuvées. Sans entrée admissible, l'application l'indique sans modifier de données.",
                optional=True,
            ),
            test_case(
                19,
                "Limites d'un compte admin",
                "Le compte admin supervise un projet, mais pas un autre; un employé ayant le rôle Admin est aussi visible.",
                "Comparez une entrée du projet supervisé avec une entrée d'un autre projet, puis ouvrez une entrée appartenant à l'employé Admin.",
                "Le projet non supervisé est en <b>Projet en lecture seule</b>, sans actions de modification. Le statut d'une entrée d'admin demande une <b>Approbation super admin</b>.",
            ),
            test_case(
                20,
                "Historique complet du parcours",
                "Des ajouts, modifications, approbations, rejets et suppressions de test ont été faits.",
                "Ouvrez <b>Historique</b>, essayez Tout, Ajoutées, Modifiées, Approuvées / rejetées et Supprimées, puis cherchez l'employé ou la note de test.",
                "Chaque action apparaît dans la bonne catégorie avec l'auteur, l'employé concerné, la date et les détails utiles.",
            ),
        ]
    )

    story.append(PageBreak())
    story.extend(page_header("3 - Personnel: recherche et gestion"))
    story.extend(
        [
            test_case(
                21,
                "Recherche et états du répertoire",
                "Le répertoire contient plusieurs employés et, si possible, un profil de test archivé.",
                "Recherchez par nom, SIGRH, projet et section. Essayez ensuite les états Actifs, Archivés et Tous ainsi que le filtre de projet.",
                "Chaque recherche retrouve seulement les profils correspondants. Les profils archivés sont absents d'Actifs, présents dans Archivés et clairement identifiés.",
            ),
            test_case(
                22,
                "Libellé SIGRH et HRMIS",
                "Une fiche employé est ouverte et le changement de langue est disponible.",
                "En français, repérez le libellé de l'identifiant dans la recherche et la fiche. Passez temporairement l'application en anglais.",
                "L'identifiant est nommé <b>SIGRH</b> en français et <b>HRMIS</b> en anglais, sans ancienne mention Code employé.",
            ),
            test_case(
                23,
                "Fiche employé, mois et projet",
                "L'employé choisi possède des entrées sur plusieurs mois ou projets.",
                "Comparez le résumé, le calendrier et la répartition par projet. Changez de mois, ouvrez un projet, puis ouvrez une entrée.",
                "Les totaux, le calendrier et les entrées suivent l'employé, le mois et le projet sélectionnés. La note superviseur apparaît lorsqu'elle existe.",
            ),
            test_case(
                24,
                "Droits de pointage et affectations",
                "Un super admin dispose d'un profil réservé aux essais.",
                "Modifiez le rôle, les projets assignés ou les droits Heures supp. / Divers, enregistrez, puis reconnectez le profil de test.",
                "Les changements restent après réouverture. Le profil voit seulement les projets et types de pointage autorisés. Remettez ensuite les valeurs originales.",
                optional=True,
            ),
            test_case(
                25,
                "Archivage et réactivation d'un employé",
                "Utilisez exclusivement un profil de test et un compte super admin.",
                "Archivez le profil, retrouvez-le dans Archivés, puis cliquez sur <b>Réactiver</b> et revenez à Actifs.",
                "Le profil quitte les employés actifs, apparaît comme Archivé, puis revient dans Actifs après réactivation. Les deux actions sont tracées dans l'historique.",
                optional=True,
            ),
        ]
    )

    story.append(PageBreak())
    story.extend(page_header("4 - Projets, réglages et GC179"))
    story.extend(
        [
            test_case(
                26,
                "Recherche, statistiques et navigation",
                "Plusieurs projets contiennent des entrées.",
                "Recherchez par numéro, nom, secteur et superviseur. Essayez Tout, 1 mois, 6 mois, 1 an et une période personnalisée, puis ouvrez un employé depuis la répartition.",
                "Les cartes, graphiques et totaux suivent la recherche et la période. <b>Ouvrir dans Personnel</b> mène à la bonne fiche filtrée sur le projet.",
            ),
            test_case(
                27,
                "Création d'un projet sans nom",
                "Un super admin a choisi un numéro de dossier unique réservé au test.",
                "Cliquez sur <b>Ajouter projet</b>, saisissez seulement le numéro de dossier et laissez <b>Nom du projet</b> vide.",
                "Le projet est créé. Dans les cartes, recherches et menus, son numéro sert de titre, sans zone vide ni répétition du numéro.",
                optional=True,
            ),
            test_case(
                28,
                "Validations du projet",
                "La fenêtre Ajouter projet est ouverte par un super admin.",
                "Essayez un numéro vide, un caractère interdit, puis un numéro déjà utilisé. Dans Admins, cherchez aussi un employé sans rôle admin.",
                "Chaque sauvegarde invalide est refusée sans créer de projet. Seuls les comptes Admin ou Super Admin peuvent être responsables ou remplaçants.",
                optional=True,
            ),
            test_case(
                29,
                "Projet utilisé: numéro verrouillé et suppression bloquée",
                "Le projet de test contient maintenant au moins une entrée d'heures supp.",
                "Essayez de changer son numéro de dossier, puis son nom. Essayez ensuite la suppression définitive et terminez par l'archivage.",
                "Le numéro ne peut plus changer, mais le nom reste modifiable. La suppression définitive est refusée. L'archivage réussit, conserve le projet avec le badge Archivé et le retire des choix de nouveau pointage.",
                optional=True,
            ),
            test_case(
                30,
                "Langue et thème conservés",
                "La page <b>Réglages</b> est accessible.",
                "Passez entre français et anglais, puis entre Système, Clair et Sombre. Actualisez la page et reconnectez-vous.",
                "La langue et le thème choisis sont conservés. Les textes, formulaires et graphiques restent lisibles dans chaque thème.",
            ),
            test_case(
                31,
                "Aperçu d'une importation GC179",
                "Le modèle GC179 et un fichier FDF d'essai sont disponibles.",
                "Ouvrez <b>Importer GC179</b>, choisissez l'employé, le projet et le FDF, puis lancez seulement l'aperçu. Vérifiez identité, lignes valides, doublons et lignes ignorées.",
                "L'aperçu bloque l'importation si l'identité ou les confirmations obligatoires ne sont pas valides. Aucun doublon n'est importé; n'importez que les lignes de test sélectionnées.",
                optional=True,
            ),
        ]
    )
    story.append(Spacer(1, 1 * mm))
    story.append(p("Pour signaler un problème", "test_title"))
    story.append(
        p(
            "Notez le numéro du test, le rôle utilisé, ce que vous avez fait, ce qui s'est passé, ce qui était attendu et le message d'erreur exact. Ajoutez une capture d'écran si elle aide.",
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
        topMargin=17 * mm,
        bottomMargin=20 * mm,
        title="SAPHIR - Parcours de démonstration détaillé",
        author="Équipe SAPHIR",
        subject="Tests fonctionnels guidés pour SAPHIR",
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
