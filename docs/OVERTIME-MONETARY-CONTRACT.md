# Contrat des montants de temps supplémentaire

Ce contrat couvre le moteur de calcul, la classification courante des employés, les snapshots des entrées approuvées et leurs modèles de lecture sécurisés. Les résultats sont des estimations analytiques pour la gestion et la justification des projets; ils ne remplacent pas le calcul officiel du système de paie.

La base de coût est `salary-only`. Les montants excluent les avantages sociaux, cotisations de l’employeur, primes, impôts et autres charges. Le moteur expose donc aussi `includesEmployerCosts = false` afin qu’un futur écran ne puisse pas présenter ces valeurs comme un coût employeur complet.

## Source et version

- Convention : groupe Services des programmes et de l’administration (`PA`).
- Version de calcul : `PA-MONETARY-v1`.
- Devise : `CAD`.
- Source officielle : [Convention collective PA du Secrétariat du Conseil du Trésor](https://www.tbs-sct.canada.ca/agreements-conventions/download-fra.aspx?id=56).

La convention définit le taux hebdomadaire comme le salaire annuel divisé par `52,176`, puis le taux horaire comme le taux hebdomadaire divisé par `37,5`. SAPHIR utilise donc le diviseur annuel exact `1 956,6`.

## Calcul

1. Le salaire annuel est reçu en cents entiers depuis la grille salariale administrable.
2. Le taux horaire interne en cents est `salaire annuel en cents ÷ 1 956,6`.
3. Ce taux demeure un nombre décimal non arrondi pendant le calcul.
4. Les minutes déjà créditées par la règle des tranches de quinze minutes sont séparées selon le code GC179, l’horaire et le seuil quotidien.
5. Chaque segment applique le multiplicateur central `1,5`, `1,75` ou `2`.
6. Le total de l’entrée est arrondi au cent avec les demis arrondis en s’éloignant de zéro.
7. Les montants de segment sont ajustés sur le dernier segment afin que leur somme soit toujours identique au total arrondi.

Le moteur accepte seulement des minutes créditées multiples de quinze. Il ne réinterprète pas les heures de punch et ne duplique donc pas la règle « au moins dix minutes travaillées dans une tranche » déjà détenue par `Saphir.EntryDuration`.

## États du résultat

- `estimated` : le moteur possède les données nécessaires et retourne une valeur analytique.
- `unavailable` : une donnée déterminante manque. Dans la première version, un horaire `unconfirmed` produit `work-schedule-unconfirmed` et aucun montant.
- `final` : le calcul a été figé dans le snapshot privé d’une entrée approuvée. Il demeure une estimation (`estimateOnly = true`), pas un résultat officiel de paie.

Chaque résultat expose `estimateOnly = true`. Aucun écran ne doit présenter ces valeurs comme un montant officiel de paie.

## Argent et congé compensatoire

- `cash` : la valeur est classée dans `cashAmountCents`.
- `leave` : la même valeur économique est classée dans `compensatoryLeaveValueCents`, tandis que `cashAmountCents` reste à zéro.
- `totalAmountCents` représente la valeur économique totale dans les deux cas.

Les rapports devront afficher séparément le coût payé en argent et la valeur du congé compensatoire afin de ne pas présenter ce dernier comme une dépense immédiate.

## Accès et confidentialité

- Le JavaScript ne recalcule jamais les montants; il affiche seulement une projection préparée par le backend.
- Les détails de salaire et de taux sont réservés aux super admins.
- Les admins voient les montants d’entrées et les agrégations uniquement dans leur portée de projets autorisée.
- Les employés ne voient pas de valeur monétaire dans cette version.
- Les projections normales d’entrées retirent toujours le snapshot complet. Les modèles de lecture de gestion exposent seulement l’état du calcul, la devise, la base de coût et la répartition valeur totale / argent / congé compensatoire.
- Le salaire annuel, le taux horaire, la classification, les identifiants RH et l’empreinte de calcul ne sont jamais copiés dans les modèles de Révision ou Projets.
- Les agrégations indiquent leur couverture (`calculatedEntryCount` et `unavailableEntryCount`) afin qu’un montant partiel ne soit jamais présenté comme complet.

## Une seule classification par employé

Les champs `group`, `subGroup` et `level` de `gc179Profile` sont la source commune pour l’en-tête GC179 et les montants. Le formulaire « Profil et classification » contient une seule valeur courante pour chaque champ. Une promotion se fait simplement en changeant ces valeurs; aucune période de classification n’est à saisir.

Le lecteur accepte encore l’ancien `compensationAssignments` comme fallback si le profil ne possède pas de classification complète. Au prochain enregistrement du profil, seule la classification courante est conservée. Les montants déjà calculés gardent la classification et le salaire capturés dans leur snapshot.

## Snapshot à l’approbation

Quand une entrée de temps supplémentaire est approuvée, le backend enregistre `compensationSnapshot` dans la même écriture atomique que le changement de statut. Il utilise la classification courante de l’employé et l’échelle salariale applicable à la date de l’entrée. Le snapshot contient notamment la version du calcul, l’identifiant de l’échelle, la classification, le salaire annuel interne, les segments de taux, la répartition argent/congé et l’heure du calcul. Une modification ultérieure de la classification ou de la grille ne remplace pas le salaire capturé d’une entrée déjà chiffrée. Une modification de durée recalcule le montant avec ce salaire capturé.

Les approbations simples, les approbations en lot, les modifications d’entrées et les imports GC179 approuvés utilisent tous la même fonction. Une donnée manquante ne bloque pas l’approbation : le snapshot prend l’état `unavailable` avec une raison stable (`employee-classification-missing`, `salary-band-missing`, `work-schedule-unconfirmed`, etc.). Une entrée qui repasse à `pending` ou `rejected` perd son ancien snapshot pour éviter d’afficher un montant périmé.

## Affichage de gestion

Personnel affiche la valeur estimée sur les cartes employé, dans le résumé du mois affiché, dans les statistiques de la fiche (total, argent, valeur du congé), par projet et dans les lignes d’entrée. Le filtre projet utilise uniquement les montants de ce projet. Projets affiche le total de la période du portefeuille, une valeur bien visible sur chaque carte, le détail d’un projet, la répartition par contributeur et les entrées récentes. Révision conserve la valeur sur les entrées approuvées. La valeur en argent et celle du congé compensatoire restent séparées dans le détail. Les chiffres sont des estimations salariales, sans charges employeur.

Une ancienne entrée approuvée sans snapshot final est chiffrée à la lecture avec la classification configurée. Le calcul s’effectue sur une copie en mémoire de toutes les entrées de l’employé, avant les filtres de date ou de projet : les seuils journaliers restent donc corrects. Ce cache dérivé est invalidé lors d’une révision partagée, notamment une mise à jour de la grille. Aucune écriture ni verrou d’écriture sur les fichiers employés n’est nécessaire pour consulter ces estimations; les snapshots finalisés restent inchangés. L’enregistrement du profil continue de tenter le remplissage des snapshots manquants.

Les entrées non approuvées et « divers » sont exclues des montants. Une classification, un salaire applicable ou un horaire manquant reste explicitement indisponible : jamais un faux 0 $. Si toutes les approbations sont chiffrées, un total nul est réellement 0 $. Sinon l’interface affiche « À compléter » ou un total « Partiel », accompagné du nombre d’entrées manquantes et des raisons principales. Les permissions des projets et l’absence de montants dans les réponses employé `/self/*` sont conservées.
