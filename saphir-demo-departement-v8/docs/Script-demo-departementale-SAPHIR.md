# Script de la démonstration départementale de SAPHIR

**90 minutes : 80 minutes de démonstration, 10 minutes de questions.** Le fil rouge : Élodie déclare du temps supplémentaire, Émile le valide, puis Élodie prépare sa GC179. On élargit ensuite aux corrections, aux projets et au rapport que la direction peut utiliser pour expliquer les heures.

## Mise en scène

**Deux sessions, un seul SAPHIR.** Lance une seule fois la démo v7 avec `Demarrer-demo.command` sur Mac ou `Demarrer-demo.cmd` sur Windows. Elle répond à `http://localhost:8097/`. Ouvre une fenêtre Chrome normale pour Élodie et une fenêtre de navigation privée pour Émile. Les deux utilisent le même serveur local, mais des sessions différentes. Deux onglets ordinaires, ou deux fenêtres privées dans le même profil, ne suffisent pas pour isoler les connexions. Prépare Maëlle dans un autre profil si tu veux éviter une déconnexion au milieu; sinon, remplace Émile par Maëlle après le bloc Admin.

Garde les deux fenêtres prêtes, mais **projette une seule fenêtre en grand à la fois**. Bascule quand l’action passe à l’autre personne. Un écran partagé côte à côte est utile pendant quelques secondes pour comparer les deux états, pas pour lire un formulaire ou un graphique.

| Fenêtre | Compte fictif | Rôle |
|---|---|---|
| Employé | Élodie Desmarais — `880000007` | Pointage, suivi, temps divers et GC179 |
| Supervision | Émile Durocher — `880000002` | Admin ordinaire, affecté notamment à `DEMO-01` |
| À garder en réserve | Maëlle Verville — `880000001` | Super admin |

Mot de passe de la démo : `DemoSAPHIR2026!`. Ne saisis pas d’identifiants réels devant le groupe. Fais les manipulations sur une copie extraite du ZIP; garde le ZIP intact pour repartir d’une démo propre après la répétition.

### À préparer avant d’entrer dans la salle

1. **Prépare l’entrée du fil rouge.** Dans la session Émile, ouvre **Personnel → Élodie Desmarais → Ajouter une entrée**. Saisis le **24 novembre 2026, 17h00 à 18h30**, projet **DEMO-01 — Modernisation du portail**, code **260**, paiement **En espèce**, motif **D**. Mets `Validation du portail – démo` en commentaire et `Entrée préparée pour la démonstration` en note superviseur. Laisse l’entrée **En attente**. Ouvre Révision, filtre Élodie et DEMO-01, puis vérifie qu’elle apparaît dans **À traiter par moi**. Ne l’approuve pas avant la présentation.
2. **Configure les périodes dans la copie de présentation.** Avec Maëlle : **Réglages → Périodes budgétaires**. Nomme le cycle `Démo 2026–2027`, génère **12 périodes**, premier mois **avril 2026**, premier jour **1**, puis enregistre. **P7 = octobre**, **P8 = novembre**. Vérifie que les deux ont de l’activité dans **Projets → Afficher la comparaison**. La copie d’origine n’a pas de dates budgétaires configurées.
3. Garde le [FDF de démo d’Élodie](880000007_DESMARAIS_E_GC179_2026-10.fdf) et une capture fictive à portée de main pour l’import et le signalement. **Ne renomme pas le FDF** : SAPHIR utilise notamment le SIGRH dans le nom pour vérifier l’identité. Lance une fois l’export GC179 et le rapport départemental avant la présentation. Garde une GC179 déjà ouverte dans Acrobat si possible et un rapport HTML déjà exporté en réserve.
4. Vérifie sur l’écran de la salle que les deux sessions sont lisibles et qu’elles communiquent avec **la même** copie de SAPHIR. Le ZIP est autonome; le disque partagé n’est pas utilisé. Si tu changes de machine, confirme que le raccourci et Acrobat démarrent sur cette machine avant de projeter.

## 00 à 05 minutes — Pourquoi SAPHIR

**À dire :** « Je vais suivre une vraie question de bout en bout : si quelqu’un a fait du temps supplémentaire, comment on le déclare, qui le vérifie et comment on s’en sert ensuite? Tout ce que vous voyez aujourd’hui est fictif : 40 employés, 20 projets, des entrées sur 12 mois. »

**À l’écran :** montre brièvement la connexion, le bandeau **DÉMO · DONNÉES FICTIVES**, puis **Mes heures supp.**. Explique la différence entre la copie locale utilisée ici et l’installation de travail : au bureau, le lanceur sert à démarrer, ouvrir ou mettre à jour SAPHIR et distingue l’état de l’application de celui des données partagées. Ne lance ni mise à jour ni réparation pendant la présentation.

**Transition :** « On commence avec la personne qui fait les heures. Elle n’a pas à passer par les écrans de supervision. »

## 05 à 14 minutes — Déclarer ses heures comme employé

1. Dans **Mes heures supp.**, montre le projet, le code d’heures supplémentaires, le paiement et le motif. Choisis **DEMO-01**, **260**, **En espèce**, **D**. Explique qu’on montre un exemple de saisie; les codes doivent refléter la situation réelle.
2. Montre **Horaire** : le switch passe de **Régulier** à **Comprimé** et affiche le petit calendrier fuchsia. Laisse-le sur **Comprimé** pour le pointage fictif. « Le réglage s’applique aux prochaines entrées. Il ne change pas rétroactivement l’horaire déjà enregistré sur une entrée. »
3. **Démarre un pointage en direct**, confirme et montre le compteur. Tu peux laisser cette entrée ouverte pendant que tu présentes le calendrier et la supervision. Montre que les statistiques personnelles sont distinctes du calendrier et que le mois sélectionné dans le calendrier détermine le mois de la GC179.
4. Dans **À suivre**, ouvre le motif du refus du **30 octobre** et clique **Voir l’entrée**. Dans les notes de l’entrée, montre le commentaire d’origine, le complément daté et la note d’Émile avec la date et l’heure. Élodie peut ajouter un complément sans réécrire le commentaire d’origine. Reviens à novembre. Survole une icône fuchsia dans le calendrier si elle est visible.
5. Montre le choix **Temps divers** avant le démarrage, ou explique-le à partir de l’entrée du **23 novembre** si tu as déjà démarré : le type est réservé aux comptes autorisés, sans projet, avec un motif au départ et un résumé à la fin.

**À dire :** « Le pointage exact est gardé. Les heures affichées sont arrondies et le temps crédité répond à une règle différente : il faut avoir travaillé au moins 10 minutes dans une tranche fixe de 15 pour que cette tranche compte. »

## 14 à 28 minutes — Du pointage vers la Révision puis la GC179

1. **Passe à Émile.** Dans **Vue d’ensemble**, montre la différence entre **sessions actives** et **approbations en attente**. Si le pointage d’Élodie est visible, montre-le comme session active; il n’est pas encore à approuver. Ouvre Révision depuis l’aperçu ou la navigation.
2. Ouvre **En attente**, puis **À traiter par moi**. Filtre **Élodie** et **DEMO-01**. Montre l’entrée préparée du **24 novembre, 17h00–18h30** : date, durée, projet, ligne code/paiement/motif, commentaire et note. Clique **Approuver** sur cette seule carte.
3. **Reviens à Élodie.** Dans le calendrier de novembre, montre la même entrée devenue **Approuvée**. Laisse quelques secondes à la synchronisation entre les sessions; actualise la page si besoin. Si un écran tarde, continue la narration au lieu de répéter l’action.
4. Clique **Exporter GC179 · novembre 2026**. Montre le reçu : période, nombre d’entrées et formulaires, indication des entrées en attente si applicable, **Copier le chemin**. Si Acrobat s’ouvre, montre seulement le mois, l’en-tête et les lignes d’heures. L’entrée **Divers** du 23 novembre est un exemple pour expliquer le découpage après 7h30 et les colonnes de taux laissées manuelles. **Une GC179 préparée dans SAPHIR n’est pas une transmission à la paie; le reçu ne prouve pas non plus qu’Acrobat a ouvert le fichier.**
5. Reviens au pointage démarré en direct. Entre `Vérification du portail avant fermeture` et montre la confirmation de fin. Si la session est encore très courte, dis-le : tu peux la terminer comme exemple de temps non crédité, ou la terminer plus tard pour éviter un doublon avec le cas Noé. Survole son calendrier fuchsia pour faire apparaître **Temps comprimé**, puis remets la préférence à **Régulier** et montre que cette entrée reste comprimée.

**À dire :** « On vient de suivre la même opération des deux côtés. Élodie n’a pas besoin de demander par courriel si ça a été approuvé; le résultat et les remarques sont visibles dans sa fiche. »

## 28 à 39 minutes — Traiter les exceptions et montrer les limites du rôle Admin

1. **Pointage trop court.** Émile → **Révision → À vérifier** → cherche **Noé Bellemare**, **23 novembre**, projet `2025-1352851`. Montre **14h04–14h08** comme temps exact et **0 min créditée**. « Le pointage ne disparaît pas. Il reste visible pour qu’on puisse l’examiner sans inventer quinze minutes. »
2. **Sortie oubliée.** Garde **Inès Laurent**, **23 novembre à 22h00**, pour Maëlle si Émile ne la voit pas : l’entrée est dans `2022-1596783` (COINCIDENCE), hors de ses affectations. Explique que l’heure de fin doit être vérifiée par un superviseur. Ne tranche pas la question des quarts légitimes après minuit pendant la démo; c’est une règle métier distincte.
3. **Droits du superviseur.** Montre une entrée en attente d’**Émile lui-même sur DEMO-01**, le **9 novembre**. Il ne peut pas l’approuver lui-même. Maëlle peut traiter les entrées d’un admin, et elle peut voir les cas **Divers**. Un admin peut consulter les statistiques des projets, mais agir seulement sur les entrées admissibles de ses projets assignés, y compris comme remplaçant.
4. **Rejet et approbation en lot.** Montre la fenêtre **Rejeter l’entrée** sur une entrée test, avec le motif obligatoire; confirme seulement si tu as prévu une entrée jetable. Puis montre la confirmation du lot sur un filtre étroit, avec le nombre d’entrées et la portée sur toutes les pages. Annule si tu ne veux pas modifier les résultats utilisés plus tard. Explique le reçu partiel : il sépare les entrées traitées des autres et donne la raison; ne simule pas une panne réseau en pleine séance.
5. Ouvre **Historique** à la demande et montre l’approbation de tout à l’heure, son auteur et son contexte. Dans les onglets, rappelle que **Approuvées** ou **Rejetées** peuvent être filtrées sur d’autres dates si l’action recherchée n’est pas du mois courant.

## 39 à 49 minutes — Personnel et correction d’une entrée

**À dire :** « Révision répond à “qu’est-ce qui attend une décision?”. Personnel répond à “qu’est-ce qui s’est passé pour cette personne?”. »

1. Dans **Personnel**, recherche **Noé** par son nom, puis montre les filtres par projet et statut d’employé. Ouvre sa fiche. Montre le calendrier, les totaux d’heures, les statuts, la répartition par projet et les montants estimés quand ils sont disponibles. Le calendrier montre aussi des entrées qui ne sont pas incluses dans le rapport départemental.
2. Fais une entrée jetable sur **DEMO-01**, **23 novembre, 08h00–09h00**, code 260, avec un commentaire et une note superviseur distincts. Sélectionne l’entrée dans le calendrier : la fiche s’ouvre à côté, sans déplacer la page. Dans le menu **⋯**, choisis **Modifier**, change la date au **24 novembre**, explique la correction dans la note et enregistre. Montre ensuite **Supprimer** avec la note requise, uniquement sur cette ligne jetable. Les autres fiches et entrées restent intactes.
3. Depuis une carte de Révision, montre **Ouvrir l’entrée** pour revenir directement à la bonne fiche et à la bonne entrée. Donne l’exemple de l’horaire à confirmer : un superviseur peut corriger une entrée, ou confirmer les horaires d’un mois sur une fiche quand le bouton est proposé. N’invente pas un horaire à partir de la préférence actuelle.
4. Si la direction pose des questions sur les personnes, ouvre **Analyse des heures supp.** dans **Personnel**. Garde le rapport **départemental sans employés** pour les discussions de gestion.

## 49 à 62 minutes — Projets, budget et rapport pour la direction

1. Dans **Projets**, pars de **Ce mois-ci**, puis passe à **1 an**. Montre que la période reste accessible pendant le défilement. Survole un mois sur le graphique pour lire les chiffres, masque une série avec la légende et réaffiche-la. Le zoom est utile si tu veux rapprocher deux mois; ne passe pas du temps sur tous les contrôles.
2. Trouve **DEMO-01 — Modernisation du portail** à l’aide de la recherche. Ouvre le dossier et montre la tendance, la part des heures, les statuts, les coûts estimés et, dans l’espace autorisé, les contributions. Montre les raccourcis **Réviser les entrées** et **Voir les entrées** plutôt que de refaire la navigation à la main. Mentionne les vues **Actifs / Archivés** et le tri par activité dans la période.
3. Ouvre **Afficher la comparaison** et compare **P7 (octobre)** à **P8 (novembre)**, en heures puis en montants estimés. « On compare ici des heures supplémentaires approuvées et terminées. Les périodes budgétaires ont leurs propres dates, indépendantes du filtre général. » Compare les mois avec prudence : la démo de novembre s’arrête le 23.
4. Reviens au portefeuille avec la période voulue et clique **Exporter le rapport départemental**. Ouvre le HTML dans le navigateur. Commence par la part des heures par projet et une date ou période qui justifie la variation. Le rapport **départemental** ne présente pas les résultats individuels; le **détaillé** sert à l’analyse interne selon les droits. « On peut justifier le volume par projet sans faire un classement d’employés. »

**Question à poser au groupe :** « Pour une rencontre de gestion, à quel niveau voulez-vous voir les écarts : par mois, par période budgétaire ou par projet? »

## 62 à 74 minutes — Ce que le super admin peut configurer

**Bascule à Maëlle.** « Le super admin n’est pas juste un admin qui voit plus de dossiers. Il est responsable des opérations qui touchent à la configuration et aux droits. »

1. **Personnel et accès.** Ouvre **Ajouter employé** ou **Modifier** une fiche de démo. Montre le rôle, les types d’entrée autorisés, le profil **Groupe / Sous-groupe / Échelon**, la réinitialisation de mot de passe et **Archiver / Réactiver**. Ne réinitialise pas le mot de passe d’un des trois comptes utilisés. Pour une démonstration d’archivage live, utilise un compte jetable, pas Élodie.
2. **Gestion des projets.** Crée le dossier vide `DEMO-90`, sans préfixe ER, avec un nom, un secteur, un code couleur, un marqueur, un admin et un remplaçant. Modifie son nom ou son numéro, archive-le, puis montre qu’on peut le retrouver sous **Archivés** et le réactiver. Montre la trace dans **Révision → Historique**. Explique que la suppression définitive n’est offerte que si les références le permettent; ne supprime pas un projet qui sert au scénario.
3. **Réglages.** Montre les dates de la grille salariale, sans modifier les taux en direct. La classification du profil sert aussi à la GC179. Un montant peut être **N/A** si une information manque; ce n’est pas 0 $. Ces montants servent à estimer les coûts, pas à remplacer la paie. Montre où le cycle budgétaire a été généré et où une période peut être ajoutée ou retirée. Si quelqu’un demande le diagnostic, ouvre **État du système** sans provoquer de panne.
4. **Import GC179.** Dans **Personnel → Importer GC179**, prends le FDF fourni, cible **Élodie**, projet **DEMO-01**, statut **En attente**, puis **Aperçu**. Attends-toi à **deux lignes valides, 27 et 29 octobre, aucun doublon** sur une copie intacte. Montre l’identité, la sélection et les avertissements avant l’écriture. Importe si le temps le permet et montre la note automatique attribuée au compte connecté; sinon, arrête-toi à l’aperçu. En réserve : montrer **Annuler cette importation** juste après l’avoir faite, ou relancer un aperçu pour montrer le repérage des doublons. Ne réimporte pas la GC179 du parcours principal.

## 74 à 80 minutes — Signaler un problème et résumer

1. Côté Élodie, clique **Signaler un bug**. Donne un titre explicite, par exemple `Démo – texte coupé sur petit écran`, une catégorie et une courte description. Glisse une image fictive, montre le chargement, soumets, puis ouvre le détail et agrandis l’image.
2. Côté Maëlle, ouvre **Bugs**, retrouve le ticket, change son statut et son code couleur, puis ajoute un message dans la discussion. Reviens côté Élodie pour montrer le suivi. Montre la possibilité de supprimer sur le ticket de démo seulement, ou laisse-le visible pour les questions.
3. **Conclusion à dire :** « L’employé saisit et suit ses heures. Le superviseur traite ce qui relève de lui. Le super admin règle les droits et les exceptions. À la fin, le département a un rapport par projet pour expliquer les heures, sans devoir exposer les résultats de chaque personne. »

## 80 à 90 minutes — Questions et plans de secours

| Si ça arrive | Comment poursuivre |
|---|---|
| Les deux fenêtres affichent le même rôle | Vérifie qu’une fenêtre est normale et l’autre privée, ou utilise deux profils séparés. Reste sur la même adresse SAPHIR. |
| Le pointage live est trop court ou l’état tarde à se mettre à jour | Utilise l’entrée préparée d’Élodie. Ne clique pas deux fois sur une action dont le résultat est incertain. |
| Acrobat n’ouvre rien | Montre le reçu et **Copier le chemin**, puis le formulaire déjà ouvert si tu l’as préparé. Ne dis pas que l’ouverture a réussi. |
| Le graphique ou le rapport prend trop de temps | Ouvre le rapport départemental HTML exporté d’avance; explique la période affichée avant de commenter les chiffres. |
| Tu as pris du retard | Retire d’abord la suppression de test, la réactivation du projet et l’import après l’aperçu. Garde le passage employé → admin → employé, les exceptions et le rapport départemental. |

**En réserve s’il reste du temps :** dans **Réglages**, montre le thème clair ou sombre, le profil GC179 et le changement de mot de passe. La langue se change avec le sélecteur FR/EN. Dans **Projets**, compare les deux formats de rapport pour un seul projet et montre le détail A/B du graphique budgétaire.

**Questions utiles pour terminer :** « Quel cas vous fait perdre le plus de temps aujourd’hui? », « Qu’est-ce qu’un superviseur doit voir au premier coup d’œil? », « Quelle comparaison vous aide le plus à justifier le temps supplémentaire? »
