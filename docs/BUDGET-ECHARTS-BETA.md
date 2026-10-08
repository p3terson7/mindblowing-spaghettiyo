# Comparaison des périodes — bêta ECharts

Dans **Projets**, ouvrir **Comparer les périodes budgétaires**, puis sélectionner
**Graphiques ECharts · Bêta**. La **Vue classique** reste accessible au même endroit.

- **Vue du cycle** : barres par période, curseur de zoom, sélection d’une période
  pour consulter ses projets et tableau de valeurs exactes repliable.
- **Comparer A / B** : deux périodes, barres par projet, écart absolu et relatif,
  tri par écart ou valeur en B, recherche et inversion des périodes.
- **Heures / Montants estimés** : les montants viennent des snapshots approuvés
  du backend. La vue du cycle distingue l’argent et le congé compensatoire.
- **Export** : l’icône du graphique produit une image PNG. La légende permet de
  masquer une série; la barre latérale permet de parcourir les grands portefeuilles.
- **Données fictives** : jeu de démonstration généré en mémoire, clairement
  identifié. Aucune entrée, classification ou configuration partagée n’est modifiée.

Une entrée sans montant ne devient pas un coût nul. La couverture manquante est
indiquée et un écart monétaire n’est pas calculé lorsque la couverture est incomplète.
Les données restent limitées aux projets que l’utilisateur peut consulter.

ECharts 6.1.0 et ses fichiers LICENSE / NOTICE sont inclus dans l’application.
La bibliothèque est chargée seulement quand la bêta est ouverte; aucune connexion
Internet ou installation supplémentaire n’est requise sur le poste de travail.

Le clic sur une barre de projet ouvre sa fiche avec les dates de la période choisie.
Les choix de la bêta sont temporaires et restent dans le navigateur pour cette session.

## Vérification

Le test standard `tests/frontend/test-budget-echarts-beta.js` utilise le vrai
runtime ECharts en rendu SVG. Il vérifie les séries, le zoom disponible, le tri,
les montants manquants et l’absence de calcul salarial côté JavaScript.

Le test visuel optionnel `tests/browser/budget-echarts-beta.js` utilise Playwright
avec une API fictive en lecture seule. Il vérifie le chargement différé, les
interactions, le passage classique / bêta et le rendu clair, sombre et mobile.
Configurer `NODE_PATH` vers les packages Playwright disponibles; `BETA_CHROME_PATH`
permet de fournir le chemin d’un navigateur Chromium installé.
