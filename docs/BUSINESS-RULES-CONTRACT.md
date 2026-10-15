# Contrat des règles métier SAPHIR

Ce document décrit les valeurs stables introduites avant les prochains écrans et migrations. Il ne contient volontairement aucun salaire ni aucune date budgétaire : ces valeurs restent configurables par les super administrateurs. Les multiplicateurs d'heures supplémentaires imposés par la convention sont toutefois des règles métier versionnées dans le programme.

## Entrées

- `entryType` accepte `overtime` ou `diverse`. Une ancienne entrée sans valeur reste interprétée comme `overtime`.
- Une entrée `diverse` créée manuellement exige une raison et un résumé du travail. Elle ne porte ni projet, ni code d’heures supplémentaires, ni option de paiement.
- La création d’une entrée `diverse` exige que le profil de l’employé contienne le privilège `diverse` dans `timeEntryTypes`. La vérification est faite dans l’interface et de nouveau avant toute écriture côté serveur.
- Comme les entrées `diverse` n’ont aucun projet permettant de limiter leur portée, leur gestion demeure réservée aux super administrateurs.
- `workSchedule` accepte `regular`, `compressed` ou `unconfirmed`.
- Une ancienne entrée sans horaire est projetée comme `unconfirmed`; le fichier partagé n’est pas réécrit automatiquement.
- `workScheduleSource` est réservé à la provenance de la classification, par exemple une sélection manuelle ou un import GC179.

## Export GC179

- `260` remplit la catégorie **Jour ouvrable régulier**.
- `261` remplit la catégorie **Premier jour de repos**.
- `262` remplit la catégorie **Deuxième jour de repos subséquent**.
- `263` remplit la catégorie **Congé férié**.
- En horaire régulier, les codes `260`, `261` et `263` utilisent 1,5× pour les premières 7,5 heures admissibles de la journée et 2× ensuite; `262` utilise 2×.
- En horaire comprimé, les codes `260`, `261` et `262` utilisent 1,75×. Le code `263` utilise la colonne 1,5×, sauf lorsqu'il est adjacent à un deuxième jour de repos travaillé au code `262`, auquel cas il utilise 2×.
- La table centrale `Saphir.OvertimeCompensation` expose les catégories, seuils et multiplicateurs sous forme décimale. L'export GC179 et les futurs calculs monétaires doivent obligatoirement utiliser cette table au lieu de recopier les taux.
- Le salaire annuel et le taux horaire ne font pas partie de cette table : ils proviennent toujours de la grille salariale modifiable par les super administrateurs.
- Les répartitions de taux explicites provenant d'une GC179 importée sont conservées lors d'un nouvel export.
- Référence : convention collective PA, articles 25.27, 28.05, 28.06 et 30.08, publiée par le Secrétariat du Conseil du Trésor du Canada.

## Classification

- Groupe : lettres majuscules seulement, par exemple `CR` ou `AS`.
- Sous-groupe : deux chiffres, par exemple `03` ou `04`.
- Échelon : deux chiffres, par exemple `01`, `02` ou `03`.

La lecture des anciens formats restera compatible jusqu’à la migration supervisée. Les règles strictes ne doivent pas réécrire les profils ou la grille salariale silencieusement.

## Montants de temps supplémentaire

- La conversion officielle utilise `salaire annuel ÷ 52,176 ÷ 37,5`, soit un diviseur annuel de `1 956,6`.
- Le moteur `Saphir.OvertimeCompensation` calcule les valeurs en décimal à partir d’un salaire annuel en cents et arrondit une seule fois le total de l’entrée au cent.
- Le moteur pur retourne `estimated`. Une entrée approuvée conserve un snapshot `final`, mais celui-ci garde `estimateOnly = true` et ne constitue pas une paie officielle.
- Une option `cash` produit une valeur monétaire immédiate. Une option `leave` produit une valeur de congé compensatoire distincte.
- Un horaire `unconfirmed` ne produit aucun montant.
- Les trois champs de classification du profil GC179 sont aussi utilisés pour les montants. L’employé a une classe courante, sans période à configurer. Les entrées déjà chiffrées conservent leur salaire capturé même après une promotion.
- Une approbation ne doit pas échouer parce qu’une classification ou une échelle manque : elle conserve alors un snapshot `unavailable` avec une raison auditable.
- Une entrée `pending` ou `rejected` ne conserve jamais un ancien snapshot final.
- Le JavaScript ne doit jamais reproduire la formule. Les données sensibles de salaire et de taux doivent être retirées des projections selon le rôle.
- Le contrat détaillé se trouve dans `docs/OVERTIME-MONETARY-CONTRACT.md`.

## Périodes budgétaires

Une nouvelle installation contient `P1` à `P12` sans dates prédéfinies. Un super admin peut ensuite ajouter ou supprimer des périodes (jusqu’à 60) dans **Réglages → Périodes budgétaires**. Les identifiants suivent le format `P` + numéro. À la lecture, une ancienne configuration de schéma 1 contenant P1–P4 est complétée avec P5–P12 vides; elle passe au schéma dynamique 2 seulement au prochain enregistrement.

Les dates peuvent être saisies à la main ou générées par mois à partir d’un mois, d’un jour de début et d’un nombre de périodes. Si le jour demandé n’existe pas dans un mois, le générateur utilise le dernier jour de ce mois. La configuration est stockée dans `budget-periods.json` sur le dossier partagé; aucune date budgétaire n’est codée en dur. La vue **Projets** affiche la liste réellement configurée et permet de comparer les heures approuvées, la part de chaque projet et l’écart entre la première et la dernière période sélectionnée.

## Compatibilité

Ces nouveaux champs sont optionnels dans la version 1 du dossier de données. L’ajout du contrat ne change donc pas `data-schema.json` et ne bloque pas les versions déjà déployées.
