# Contrat des règles métier SAPHIR

Ce document décrit les valeurs stables introduites avant les prochains écrans et migrations. Il ne contient volontairement aucun salaire, aucune date budgétaire et aucune formule monétaire : ces valeurs doivent rester configurables par les super administrateurs.

## Entrées

- `entryType` accepte `overtime` ou `diverse`. Une ancienne entrée sans valeur reste interprétée comme `overtime`.
- Une entrée `diverse` créée manuellement exige une raison et un résumé du travail. Elle ne porte ni projet, ni code d’heures supplémentaires, ni option de paiement.
- La création d’une entrée `diverse` exige que le profil de l’employé contienne le privilège `diverse` dans `timeEntryTypes`. La vérification est faite dans l’interface et de nouveau avant toute écriture côté serveur.
- Comme les entrées `diverse` n’ont aucun projet permettant de limiter leur portée, leur gestion demeure réservée aux super administrateurs.
- `workSchedule` accepte `regular`, `compressed` ou `unconfirmed`.
- Une ancienne entrée sans horaire est projetée comme `unconfirmed`; le fichier partagé n’est pas réécrit automatiquement.
- `workScheduleSource` est réservé à la provenance de la classification, par exemple une sélection manuelle ou un import GC179.

## Classification

- Groupe : lettres majuscules seulement, par exemple `CR` ou `AS`.
- Sous-groupe : deux chiffres, par exemple `03` ou `04`.
- Échelon : deux chiffres, par exemple `01`, `02` ou `03`.

La lecture des anciens formats restera compatible jusqu’à la migration supervisée. Les règles strictes ne doivent pas réécrire les profils ou la grille salariale silencieusement.

## Périodes budgétaires

Les identifiants reconnus sont `P1`, `P2`, `P3` et `P4`. Leurs dates sont configurées par un super admin dans **Réglages → Périodes budgétaires**, puis stockées dans `budget-periods.json` sur le dossier partagé. Le code ne contient donc aucune date budgétaire fixe. La vue **Projets** permet ensuite aux gestionnaires de choisir une ou plusieurs périodes et de comparer les heures approuvées, la part de chaque projet et l’écart entre la première et la dernière période sélectionnée.

## Compatibilité

Ces nouveaux champs sont optionnels dans la version 1 du dossier de données. L’ajout du contrat ne change donc pas `data-schema.json` et ne bloque pas les versions déjà déployées.
