# Révision : charger une page, pas tout l’historique

## Comportement

- `/review/bootstrap` retourne une page de 25 cartes pour l’onglet demandé, ses compteurs et les choix des filtres. Les filtres et le tri sont appliqués côté serveur, avant la projection des cartes.
- En attente et À vérifier couvrent toutes les dates par défaut, pour ne pas cacher une vieille demande oubliée. Approuvé et Rejeté ouvrent le mois courant. Les dates personnalisées et le bouton Toutes les dates restent disponibles.
- Changer de page ou d’onglet ne construit pas les cartes cachées. Le navigateur conserve jusqu’à 12 pages; les changements de données et la déconnexion invalident ce cache. Une réponse arrivée en retard ne remplace pas la dernière sélection.
- L’approbation en lot concerne tous les résultats filtrés, pas seulement la page visible. Le clic demande uniquement leurs identifiants; l’écriture utilise toujours la validation et les permissions du service d’approbation existant.

## Travail évité

`ReviewService.ps1` utilise les entrées normalisées existantes et des références en mémoire, par employé. Seule la page demandée est projetée pour le navigateur. Il ne construit pas de statistiques de Personnel et ne calcule aucun salaire. Les montants déjà sauvegardés restent visibles sur les cartes approuvées explicitement consultées; la page En attente n’a pas de projections monétaires inutiles. Les dépendances de cache existantes invalident les pages et la contribution de l’employé modifié. Il n’y a ni index persistant, ni nouvelle base, ni nouveau worker HTTP.

Au premier chargement, consulter les fichiers des employés reste nécessaire pour connaître les demandes et avertissements. Les JSON contiennent chacun l’historique complet : paginer la réponse ne transforme pas cette lecture en lecture partielle du disque.

## Mesures locales indicatives

Banc existant `scripts/benchmark-view-loading.ps1`, 40 employés, 160 entrées, 167 actions historiques, un processus neuf pour Révision, une itération. Ce n’est pas un test sur R:; les durées d’un seul essai ne prédisent pas la latence SMB réelle. Les lectures comptées sont des appels applicatifs FileStore, pas des paquets SMB.

| Mesure | Avant | Après |
| --- | ---: | ---: |
| Requêtes à l’ouverture | 1 | 1 |
| Réponse HTTP | 232 526 octets | 32 480 octets |
| Entrées projetées à froid | 160 | 25 |
| Lectures partagées à froid | 44 | 44 |
| Durée locale à froid | 1 285 ms | 1 084 ms |
| Même requête, cache chaud | 23 ms | 12 ms |

Le gain établi est surtout la réduction de la réponse (~86 %), des projections et du DOM. Le temps à froid reste en partie contraint par la consultation de tous les fichiers. Les retours vers une page déjà affichée n’envoient pas de requête tant qu’aucun changement n’a invalidé les données.

Tests : `test-review-pagination.ps1`, `test-review-pagination.js`, `tests/browser/review-cards.js`, plus les tests HTTP, de permissions et de cache existants.
