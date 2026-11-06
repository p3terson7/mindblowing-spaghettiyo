# Projets : éviter de préparer des données qui ne seront pas affichées

Premier lot d’optimisations, 3 novembre 2026. Aucun changement aux fichiers DATA,
au calcul des salaires, aux écritures atomiques ou au protocole de synchronisation.

## Ce qui change

### Liste et graphiques

`refreshProjectsView` → `/projects/bootstrap?includeDetail=false` →
`Get-ProjectSummaryList` / `Get-ProjectTrendModel` → agrégats de la période →
références internes par employé → cache des entrées normalisées → FileStore.

Avant, le serveur construisait une projection publique complète pour chaque
entrée de tout l’historique : permissions, notes, alertes de révision et montant.
Il filtrait ensuite les dates pour faire les sommes de la liste.

Maintenant, `ProjectEntryReadService.ps1` conserve des références légères dans le
cache existant, par employé. Les dates et les droits de lecture sont appliqués
avant les projections détaillées. La liste ne prépare aucune carte d’entrée,
aucune permission d’approbation individuelle et aucun avertissement de révision.
Les sommes monétaires utilisent seulement les résultats sauvegardés des entrées
approuvées et fermées de la période; un montant absent reste N/A.

Les tendances mensuelles réutilisent les mêmes sommes, plutôt que de parcourir
les entrées une deuxième fois. La sélection de la période est également mise en
cache. Aucun appel HTTP supplémentaire n’est ajouté.

### Projet ouvert

`loadProjectDetailStats` → `/stats/projects/{code}` → `Get-ProjectDetailModel` →
résumé global déjà en cache + ventilation du seul projet demandé.

Les totaux et contributions couvrent toujours toute la période. Seules les
20 entrées récentes retournées sont transformées en détails publics. Les listes
d’entrées complètes ne sont plus répétées dans chaque contributeur et dans
`breakdownByEmployee`. Les deux noms de listes de contributeurs restent acceptés
pour compatibilité; ils ne contiennent que des résumés. Les six entrées visibles
initialement et le bouton pour voir davantage conservent leur comportement.

Le résultat du détail est mis en cache avec ses dépendances existantes. Une
modification d’entrée, de profil, de permissions ou de projet l’invalide; modifier
un ticket ne l’invalide pas. Les références des autres employés restent réutilisables.
Les références internes et les données privées de salaire ne sont jamais sérialisées.

Le service générique de statistiques garde son mode détaillé existant pour les
autres consommateurs. Le mode sans détails d’entrées est interne au workspace.

### Formulaire de projet

`openProjectEditorModal` → `/employees?scope=all&includeStats=false` → annuaire
en mode métadonnées → fichiers de comptes/noms/projets, sans fichiers d’heures.

Le paramètre utilise le mode léger de l’annuaire existant, sans nouveau endpoint.
Les rôles sont rafraîchis à l’ouverture du formulaire. Les références archivées
restent disponibles pour afficher les affectations existantes; les contrôles
d’admissibilité et les validations d’écriture restent inchangés. Les anciens
appels `/employees` sans ce paramètre conservent leurs statistiques.

## Mesures avant / après

Même banc `scripts/benchmark-view-loading.ps1`, 40 employés × 120 entrées =
4 800 entrées réparties sur environ un an, 2 projets, plus un compte superviseur
sans entrées. Période demandée : 1 au 14 octobre 2026. Trois processus neufs par
requête, médiane des trois temps, PowerShell 7 sur macOS, disque local.
Connexion et démarrage exclus; instrumentation « summary », pas de purge du
cache du système et pas de suite de tests concurrente pendant les mesures.

**Ce ne sont pas des mesures du disque R:.** Les lectures sont les appels
FileStore sur DATA, pas des paquets SMB. Le jeu de performance contient des
montants N/A; les tests fonctionnels couvrent séparément les montants sauvegardés.

| Requête | Nombre HTTP | Réponse, octets | Temps à froid, ms | Lectures DATA |
| --- | ---: | ---: | ---: | ---: |
| Liste des projets | 1 → 1 | 4 920 → 4 920 | 11 405 → 4 378 | 46 → 45 |
| Détail P1, chargé directement à froid | 1 → 1 | 652 173 → 107 425 | 11 592 → 4 631 | 46 → 45 |
| Choix des administrateurs | 1 → 1 | 80 448 → 22 124 | 5 390 → 222 | 44 → 3 |

La liste gagne environ 62 % de temps local **sans réduire sa réponse HTTP** :
le gain vient du travail évité. Le détail gagne environ 60 % de temps et 84 %
de réponse. Pour le formulaire, on évite réellement les 41 lectures de fichiers
d’entrées, y compris celle du compte superviseur vide.

Le détail ne projette plus que 20 entrées, contre les 4 800 projections publiques
préparées par l’ancien snapshot avant même de sélectionner la période/projet.
Les totaux couvrent toujours toutes les entrées pertinentes, pas seulement ces 20.

Les 41 fichiers d’heures restent nécessaires au premier calcul du portefeuille.
Les chiffres 46 → 45 reflètent surtout une vérification de synchronisation de
moins pendant la requête raccourcie, pas l’élimination d’un fichier employé.
On observe 5 → 4 appels de métadonnées et une énumération dans les deux versions.
Le formulaire passe de 44 à 3 métadonnées, sans énumération dans les deux versions.

Cache chaud : liste 8,53 → 8,65 ms, détail 122,52 → 9,71 ms. Le gain principal
recherché reste le chargement à froid, pas une différence de quelques millisecondes.

Temps à froid des trois essais, en ms :

- Liste : avant 12 600 / 11 405 / 11 067; après 5 775 / 4 378 / 4 172.
- Détail : avant 11 592 / 11 546 / 11 655; après 4 640 / 4 631 / 4 531.
- Formulaire : avant 5 390 / 5 345 / 5 426; après 235 / 220 / 222.

Reproduction : utiliser `-EntriesPerEmployee 120 -Iterations 3` et les requêtes
`projects/bootstrap?scope=all&includeDetail=false&startDate=2026-10-01&endDate=2026-10-14`,
`stats/projects/P1?startDate=2026-10-01&endDate=2026-10-14`, puis
`employees?scope=all&includeStats=false`. Pour reproduire le dernier « avant »,
omettre `includeStats=false` sur l’ancienne version. `-FixtureParent` permet de
placer les données synthétiques sur un vrai partage; le banc crée son propre
dossier et ne touche pas aux données de production.

## Période globale dans la vue

Le graphique principal utilise maintenant ECharts local (la même bibliothèque
que la comparaison budgétaire) : survol par mois avec durées exactes, légende
défilante pour afficher/masquer les projets, zoom par curseur et Ctrl + molette.
Les couleurs et marqueurs restent liés aux projets; les graphiques secondaires
restent en Chart.js. Le rendu réutilise la réponse existante, sans nouvelle
requête DATA. Le script local est chargé une fois à la première utilisation;
les réponses de chargement périmées sont ignorées et le graphique est libéré
avant remplacement. Les tests UI et navigateur couvrent le zoom et la légende.

Lisibilité : la hauteur du tracé principal varie de 560 à 800 px sur ordinateur
et de 420 à 540 px sur petit écran. Les dates aux extrémités restent dans le
tracé; l’axe Y propose davantage de repères. Le chargement utilise une grille
fine et un petit indicateur, ou un anneau de 104 px pour les camemberts, sans
aplats étirés. Les animations respectent la préférence de mouvement réduit.
Le chargement de la bibliothèque garde l’indicateur visible jusqu’au rendu;
les anciens camemberts et les rendus en attente sont libérés avant remplacement.
Le test navigateur retient la première réponse pour vérifier cet état à froid,
les dimensions stables et l’absence de débordement avant/après chargement.

Le sélecteur est maintenant une barre commune au-dessus de la liste et du
workspace, détachée du graphique. Elle reste sous la navigation principale
pendant le défilement et disparaît lorsqu’on quitte Projets. Son décalage suit
la hauteur réelle de la navigation, y compris sur mobile et après traduction.
La barre prend seulement la largeur de ses contrôles, regroupés à gauche avec
les dates personnalisées; le calendrier remplace le libellé « Période ».

Le résumé des projets est affiché directement sur le fond de la page, sans
panneau coloré ni cartes individuelles. Les cinq indicateurs et les deux exports
sont conservés dans une disposition compacte; sur mobile, les indicateurs passent
sur deux colonnes. Les descriptions d’export restent accessibles aux lecteurs
d’écran et les précisions monétaires restent disponibles au survol.

Les raccourcis et les dates personnalisées utilisent toujours le même état et
la même requête. Les dates personnalisées sont donc accessibles dans un projet
ouvert, sans retour à la liste. La période reste sélectionnée en revenant au
portefeuille et s’applique aussi aux exports. Les périodes de comparaison
budgétaires restent indépendantes, avec leur propre sélection P1–P12.

`test-project-period-nav.js` et `tests/browser/project-period-nav.js` couvrent la
barre unique, les dates exactes, les états actifs, les permissions de navigation
existantes, la validation, Échap, le retour à la liste, le maintien du défilement,
une requête par changement et l’absence de chargement budgétaire optionnel.
Le test navigateur utilise seulement une API fictive et n’écrit aucune donnée.
Il alterne aussi les tailles d’écran et les rafraîchissements : les graphiques
Projets n’utilisent plus de mise à jour de redimensionnement retardée qui pouvait
s’exécuter après leur destruction. Le redimensionnement natif reste réactif.

## Validation et limites

`test-project-loading-laziness.ps1` vérifie l’absence de projections dans la
liste, les dates, les employés archivés, la part du département, les montants
sauvegardés/N/A, les oublis de punch out, la limite de 20 projections, les
permissions et l’invalidation du cache. Le test UI vérifie le chargement tardif
des choix d’administrateurs. Les tests HTTP couvrent les réponses, les montants,
la confidentialité et les refus aux employés/non-connectés. Les tests existants
de navigation, rapports, périodes budgétaires et modifications distantes restent actifs.

Premier lot : suite complète de 147 tests sélectionnés, aucun échec. Les deux tests d’exécution
du launcher réservés à Windows sont ignorés sur macOS; l’audit de compatibilité
PowerShell 5.1 et les tests HTTP passent. La validation sur Windows et SMB réel
reste à faire.

Barre de période : 52 tests frontend et les régressions navigateur de période,
de montants et de comparaison budgétaire. Les tests backend ciblés (projets,
montants et compatibilité) restent inchangés et passent.

Restent pour un prochain lot : charger les projets archivés sur demande, rendre
les graphiques optionnels et conserver davantage les caches côté navigateur lors
d’une actualisation ciblée. Ce lot n’ajoute ni pagination des cartes projet,
ni nouvelle base, ni index persistant, ni worker supplémentaire.
