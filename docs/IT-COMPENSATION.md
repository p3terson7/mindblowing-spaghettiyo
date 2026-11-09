# Classification et rémunération IT

## Grille salariale

- Les profils et la GC179 acceptent `IT`, sous-groupes `01`, `02`, `03`, et les échelons `01` à `08`.
- Les huit salaires IT-02 fournis sont enregistrés dans `app/backend/defaults/compensation-grid.v1.json`, en vigueur le **22 décembre 2024** : 85 854, 88 603, 91 348, 94 095, 96 844, 99 589, 102 335 et 105 080 dollars annuels.
- Une installation neuve les reçoit dans sa grille initiale. Une installation existante conserve sa grille sans modification automatique. Un super admin peut ouvrir **Réglages → Grille salariale → Ajouter IT-02**, vérifier les lignes et enregistrer. Le bouton ne remplace pas les classifications déjà configurées, même si leur montant diffère.
- Les montants restent modifiables dans l'interface. Aucun salaire n'est intégré aux formules PowerShell ou JavaScript. Aucun montant n'est inventé pour IT-01 ou IT-03.

## Calculs et GC179

Source : [convention collective IT, articles 7 et 9](https://www.canada.ca/fr/secretariat-conseil-tresor/sujets/remuneration/conventions-collectives/it.html).

Le groupe de la classification choisit le moteur : `IT-MONETARY-v1` pour IT, règles PA existantes pour les autres classifications actuellement prises en charge. Le salaire annuel est divisé par 52,176 puis 37,5; les montants sont des estimations salariales seulement, sans primes de poste, indemnités de repas, de rappel ou de disponibilité.

- Codes 260 et 261 : 1,5× jusqu'à 7,5 heures admissibles, puis 2×. La semaine comprimée IT n'utilise pas le 1,75× PA.
- Code 262 : 2×, conformément à la catégorie de deuxième jour de repos travaillé choisie pour l'entrée.
- Code 263 : 1,5× jusqu'à 7,5 heures, puis 2×. L'exception IT 9.01(d) exige un férié non normalement prévu à l'horaire, accolé à un jour de repos travaillé (premier ou deuxième). SAPHIR ne déduit pas cet horaire du jour de semaine.
- Pour le cas précédent, un superviseur confirme la question **Férié IT : jour normalement prévu à l'horaire ?** dans Modifier une entrée. La valeur enregistrée `holidayNotScheduledWorkday` est `true` pour Non, `false` pour Oui, ou absente/null pour À confirmer. Sans réponse, l'estimation reste N/A et les colonnes de taux GC179 sont vides pour permettre la saisie manuelle; les dates, heures et codes restent exportés. Une réponse explicite recalcule le N/A lors de l'enregistrement.
- Selon IT 9.01(e), un travail continu ayant atteint 2× conserve ce taux. Les entrées accolées utilisent les heures exactes lorsqu'elles existent, sinon les heures enregistrées; une véritable interruption met fin à cette continuité. Cela ne change pas le comportement de punch après minuit, qui reste un chantier distinct.
- Les colonnes GC179 sont préparées avant le découpage en pages de 16 lignes : le seuil ne recommence pas à zéro sur une nouvelle page. Les répartitions explicites importées restent conservées.
- Quand une entrée approuvée possède une classification capturée, l'export la conserve aussi. Des classifications différentes produisent des parties GC179 séparées plutôt qu'un en-tête unique trompeur après une promotion.
- Les entrées divers gardent leur comportement séparé : 260 / Cash / D, colonnes de taux vides, découpage après 7 h 30.

Les lectures ne recalculent toujours rien et n'écrivent pas de DATA. Les montants approuvés déjà capturés restent inchangés lors d'une lecture, d'une mise à jour de grille ou d'une promotion; les nouveaux calculs et les corrections explicites utilisent le moteur correspondant à la classification capturée de l'entrée. Aucune migration destructive n'est requise.
