# Validation fonctionnelle SAPHIR - 20 juillet 2026

## Résumé

- 31 scénarios du guide vérifiés dans une copie isolée de l'application.
- 24 scénarios conformes.
- 5 scénarios révèlent une anomalie reproductible.
- 2 scénarios sont seulement partiellement conclusifs dans le navigateur de test.
- 15 suites automatisées sur 16 passent.
- Les fichiers `data/` du dépôt de travail n'ont pas été utilisés ni modifiés par ces essais.

## Anomalies reproduites

1. **Ajout manuel après une première entrée**
   - Après le tout premier pointage d'un employé sans historique, son fichier contient un objet unique au lieu d'une liste JSON.
   - L'ajout manuel suivant échoue avec : `PSObject does not contain a method named 'op_Addition'`.
   - Le même ajout fonctionne pour un employé qui possède déjà plusieurs entrées.

2. **Admin principal et admin remplaçant d'un projet**
   - Choisir un admin principal et un remplaçant distincts fait échouer l'enregistrement.
   - Le serveur concatène les deux identifiants et répond que `000100001000100002` n'est pas un admin.
   - Avec un seul admin, l'enregistrement réussit, mais la valeur est stockée comme chaîne plutôt que comme liste et la case n'est plus cochée à la réouverture.

3. **Total mensuel de l'employé**
   - La carte annonce les heures approuvées et en attente combinées.
   - Elle additionne aussi les entrées rejetées : 3 h affichées dans le test, contre 2 h approuvées et 0 h en attente.

4. **Compteur d'approbations pendant une session active**
   - La session ouverte est correctement absente de la file d'approbation du superviseur.
   - Chez l'employé, elle augmente tout de même le compteur `Approbations en attente` à 1 avant la fin du pointage.

5. **Périodes des statistiques de projets**
   - Le total `6 mois` affichait 127 h 15, alors que `Tout` et `1 an` affichaient 119 h 45.
   - Une période incluse dans `Tout` ne devrait pas produire un total supérieur.

6. **Invalidation ciblée du cache**
   - La suite `test-targeted-cache-invalidation.ps1` échoue sur deux exécutions.
   - Le changement de fichier n'invalide pas toujours le cache serveur avant la fin du délai de vie.
   - Les tests de synchronisation côté client et de publication des changements passent.

## Résultat des 31 scénarios

| Test | Résultat | Observation |
|---:|:---:|---|
| 1 | Conforme | Premier pointage sans historique réussi, sans erreur `Entries = null`. |
| 2 | Conforme | Projet et paiement obligatoires; code supp. et raison facultatifs. |
| 3 | Conforme | Confirmation, projet et paiement conservés pendant la session. |
| 4 | Conforme | Session conservée après actualisation et reconnexion, sans doublon. |
| 5 | Conforme | Fin enregistrée au statut En attente; une courte session a donné 00 h 00 après arrondi. |
| 6 | Conforme | Raison et résumé Divers obligatoires; aucun projet, code ni paiement enregistré. |
| 7 | Conforme | Périodes, projet, statut, personnalisé et réinitialisation fonctionnent. |
| 8 | Conforme | Mois vide, mois rempli, heures arrondies et plage exacte vérifiés. |
| 9 | Partiel | L'ouverture du nouvel onglet a été bloquée par la sécurité du navigateur de test; les règles d'inclusion ont été vérifiées dans le code. |
| 10 | Échec | Statuts, filtres et note visibles, mais le total mensuel inclut l'entrée rejetée. |
| 11 | Échec partiel | La file superviseur est correcte, mais le compteur employé inclut la session active. |
| 12 | Conforme | Approbation individuelle visible dans Révision et chez l'employé. |
| 13 | Conforme | Note vide refusée par le serveur; rejet et note ensuite visibles dans l'interface et l'historique. |
| 14 | Échec | Validation des heures correcte, mais ajout valide impossible pour un employé ayant exactement une entrée. |
| 15 | Conforme | Note obligatoire, recalcul réussi et message `Aucun changement détecté`. |
| 16 | Conforme | Note vide refusée; suppression avec note visible dans l'historique. |
| 17 | Conforme | Onglets et filtres combinés retournent les nombres attendus, puis se réinitialisent. |
| 18 | Conforme | Deux entrées admissibles approuvées en lot; cas sans entrée admissible correctement signalé. |
| 19 | Conforme | Projet non supervisé en lecture seule et entrée d'admin réservée au super admin. |
| 20 | Conforme | Ajouts, modification, approbations, rejet et suppression dans les bonnes catégories. |
| 21 | Conforme | Recherche par nom, SIGRH et projet; états Actifs, Archivés et Tous. |
| 22 | Conforme | SIGRH en français et HRMIS en anglais. |
| 23 | Conforme | Mois du calendrier, total mensuel, filtre projet et entrées développées vérifiés. |
| 24 | Conforme | Droit Divers appliqué; les affectations d'un Admin définissent sa supervision, pas ses choix de pointage. |
| 25 | Conforme | Employé archivé, retrouvé dans Archivés, puis réactivé. |
| 26 | Échec | Recherche et navigation correctes, mais les totaux des périodes sont incohérents. |
| 27 | Conforme | Projet sans nom créé et affiché seulement par son numéro. |
| 28 | Échec | Validations de numéro correctes, mais admin principal + remplaçant ne peuvent pas être enregistrés ensemble. |
| 29 | Conforme | Numéro et suppression refusés après utilisation; nom modifiable; archivage et retrait des pointages confirmés. |
| 30 | Conforme | Français/anglais et thème sombre conservés après actualisation. |
| 31 | Partiel | Aperçu API conforme : identité reconnue, doublons exacts marqués et non importables. Le sélecteur de fichier UI n'a pas pu être piloté par le navigateur de test. |

## Limites du banc de test

Les confirmations JavaScript natives et le sélecteur de fichier ne sont pas pilotables dans le navigateur intégré utilisé ici. Pour les tests 13, 16, 18, 29 et 31, les validations ont donc été exécutées sur l'API locale de la même copie, puis leur résultat a été contrôlé dans l'interface et dans l'historique. Aucune donnée réelle n'a été touchée.
