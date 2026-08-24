# Notes sur le projet SAPHIR

> Dernière mise à jour : 22 août 2026
> J’ai volontairement écrit ce document dans un langage assez simple. Le but est
> d’expliquer mon projet comme je le présenterais à quelqu’un, pas de donner
> l’impression de lire un contrat ou une documentation générée automatiquement.

## 1. C’est quoi SAPHIR?

SAPHIR est une application interne que j’ai développée pour mieux gérer les
heures supplémentaires chez GÉEM.

Au départ, le processus reposait beaucoup sur des courriels. Un employé envoyait
un message au début de son temps supplémentaire, puis un autre à la fin. Plus
tard, il devait retrouver ces courriels, recalculer ses heures et recopier les
informations dans un formulaire. Ça fonctionnait, mais c’était long, facile à
oublier et difficile à vérifier.

SAPHIR rassemble maintenant tout ça au même endroit :

- les punches de début et de fin;
- les entrées ajoutées manuellement;
- les projets, les codes et les options de paiement;
- les commentaires de travail;
- les notes des superviseurs;
- les approbations, les rejets et les corrections;
- les formulaires GC179;
- l’historique des actions;
- les statistiques et les rapports.

Il existe aussi un type d’entrée appelé `Divers`. Il sert aux travaux qui ne
suivent pas le fonctionnement normal des heures supplémentaires et il est
seulement disponible aux employés qui ont cette permission.

Aujourd’hui, SAPHIR est une seule application. Les employés, les admins et les
super admins utilisent le même écran de connexion, le même frontend et le même
backend. Ce sont les permissions qui changent ce que chaque personne peut voir
ou faire. Il n’y a plus une application « admin » et une autre « employé ».

Le projet reste assez léger :

- le backend est en PowerShell et reste compatible avec Windows PowerShell 5.1;
- le frontend est fait en HTML, CSS et JavaScript;
- Bootstrap, Font Awesome et Chart.js sont inclus localement;
- il n’y a pas de service cloud obligatoire;
- les données sont gardées dans des fichiers JSON sur le disque partagé;
- chaque poste lance sa propre copie locale de l’application.

L’application a surtout été pensée pour un département d’environ 30 à
40 employés. On m’a aussi indiqué qu’il pourrait y avoir autour de 40 projets en
cours, donc certaines parties de l’interface devront continuer d’évoluer pour
rester faciles à lire à cette échelle.

## 2. Pourquoi j’ai créé cette application

L’ancien processus demandait beaucoup de travail manuel pour quelque chose qui
devrait être assez simple. Les principales difficultés étaient :

- retrouver les bons courriels dans Outlook;
- se rappeler quelle heure correspondait à quel projet;
- recopier plusieurs fois la même information;
- corriger une erreur sans perdre la trace de ce qui avait changé;
- savoir quelles entrées étaient encore en attente;
- préparer les formulaires de fin de mois;
- obtenir une vue d’ensemble par projet, employé ou période.

Mon objectif n’était pas de remplacer tous les processus administratifs
officiels. Je voulais plutôt structurer l’information avant cette étape, rendre
la révision plus rapide et éviter que les données soient éparpillées partout.

## 3. Ce que je voulais améliorer

Les objectifs principaux de SAPHIR sont assez concrets :

- rendre le punch simple à utiliser;
- conserver l’heure exacte tout en appliquant l’arrondissement demandé;
- éviter les entrées oubliées ou incomplètes;
- donner aux superviseurs une file d’approbation claire;
- permettre de corriger une entrée sans perdre son historique;
- afficher le nom de la personne qui a écrit une note de supervision;
- garder les anciennes données même si un employé ou un projet est archivé;
- séparer clairement les entrées approuvées, en attente, rejetées et ouvertes;
- préparer la GC179 plus rapidement;
- offrir un rapport analytique utilisable en réunion;
- fonctionner sans base de données ou serveur cloud;
- supporter plusieurs postes qui travaillent sur les mêmes fichiers;
- installer les nouvelles versions sans modifier les données de production.

## 4. Les utilisateurs et leurs permissions

Il y a trois rôles dans l’application.

### Employé

Un employé peut surtout :

- créer et terminer ses propres entrées;
- consulter son calendrier et ses statistiques;
- voir les notes laissées sur ses entrées;
- gérer son profil GC179;
- préparer sa GC179 mensuelle;
- changer son mot de passe.

### Admin

Un admin voit les vues de supervision. Il peut consulter le portefeuille de
projets et réviser les entrées couvertes par ses responsabilités.

Un admin peut être responsable principal d’un projet ou remplaçant. Le fait
d’être remplaçant est stocké dans `backupAdmins`; ce n’est pas un rôle séparé.

### Super admin

Le super admin a accès à la gestion complète :

- employés et comptes;
- mots de passe;
- projets;
- permissions;
- entrées des autres admins;
- entrées de type `Divers`;
- cas qui demandent plus de contrôle.

Même si le frontend cache les boutons non disponibles, les permissions sont
aussi revérifiées dans le backend. Il ne faut jamais se fier seulement à ce que
l’interface affiche.

Quelques règles importantes :

- un employé voit seulement ses propres données;
- un admin ne peut pas modifier n’importe quelle entrée simplement parce qu’il
  a accès à la vue;
- les permissions de projet déterminent ce qu’il peut traiter;
- l’entrée d’un admin doit être approuvée par un super admin;
- les entrées `Divers` sont supervisées par les super admins.

## 5. Tour rapide de l’application

### 5.1 Mes heures

C’est la vue principale d’un employé. Il peut y :

- commencer une entrée d’heures supplémentaires;
- choisir son projet et les codes nécessaires;
- terminer son entrée;
- écrire ce qu’il a fait pendant cette période;
- voir ses entrées sous forme de liste ou de calendrier;
- naviguer entre les mois et les années;
- consulter ses statistiques;
- voir la répartition de son temps par projet;
- ouvrir sa GC179 pour le mois choisi.

Le profil de l’employé contient la liste `timeEntryTypes`. Elle indique s’il peut
utiliser seulement les heures supplémentaires ou aussi `Divers`.

Exemple :

```json
{
  "timeEntryTypes": ["overtime", "diverse"]
}
```

Une entrée `Divers` demande une raison au départ et un résumé à la fin. Elle
n’utilise pas de projet, de code d’heures supplémentaires, d’option de paiement
ou de code de raison.

### 5.2 Centre de commandes

Cette vue donne aux superviseurs un résumé de ce qui se passe. On y trouve entre
autres :

- les projets supervisés;
- les approbations en attente;
- les employés qui ont une entrée active;
- l’activité récente;
- un outil pour rechercher un employé;
- des raccourcis vers les actions courantes.

J’ai essayé d’éviter les détours inutiles. Par exemple, lorsqu’une entrée est
visible dans une liste, l’utilisateur peut normalement l’ouvrir ou agir dessus
directement au lieu d’aller d’abord chercher la fiche de l’employé.

La recherche d’employé a aussi une petite sécurité : si le texte ne correspond
plus clairement à l’employé sélectionné, l’ancienne sélection est annulée. Ça
évite de modifier le mauvais dossier par accident.

### 5.3 Révision

La vue Révision sert à traiter les entrées. On peut filtrer par :

- statut;
- employé;
- projet;
- dates;
- texte.

Les onglets séparent les entrées en attente, rejetées et approuvées. Les actions
disponibles dépendent des permissions de la personne connectée.

L’approbation en lot est seulement offerte dans l’onglet « En attente ». Le
bouton est désactivé lorsqu’aucune entrée ne correspond aux filtres. J’ai aussi
ajouté une vérification dans le code, donc ce n’est pas seulement une protection
visuelle.

Une entrée peut être ouverte directement depuis cette vue. Selon les droits, on
peut aussi la modifier ou la supprimer sans devoir refaire tout le chemin vers
la fiche employé.

### 5.4 Personnel

La vue Personnel sert à consulter les employés et leurs données. Elle permet de :

- chercher par nom, code, projet ou secteur;
- filtrer les comptes actifs et archivés;
- ouvrir une fiche employé;
- consulter son calendrier et ses statistiques;
- voir ses heures par projet;
- gérer ses entrées lorsque les permissions le permettent;
- gérer le compte, le rôle, les types d’entrée et le profil GC179;
- réinitialiser un mot de passe;
- archiver ou restaurer un employé.

Les opérations sur le compte sont réservées au super admin. Un admin ordinaire
peut consulter les dossiers nécessaires à son travail, mais il ne devient pas
gestionnaire de tous les comptes pour autant.

Archiver un employé ne supprime pas ses anciennes heures. Elles restent utiles
dans les rapports et dans l’historique des projets.

Les cartes de l’annuaire sont volontairement assez simples. Le nom de l’employé
sert de contrôle accessible au clavier et la carte reste cliquable à la souris.
Les actions plus importantes restent dans la fiche détaillée, ce qui évite de
remplir chaque carte de boutons.

### 5.5 Projets

La vue Projets a deux parties :

1. la liste de tous les projets;
2. l’espace détaillé du projet sélectionné.

Au début, les détails se trouvaient sous toute la liste. Avec beaucoup de
projets, il fallait descendre très loin pour les trouver. Maintenant, ouvrir un
projet affiche un espace dédié en haut de la vue. Le bouton Retour ramène à la
liste en gardant les filtres et la position de défilement.

La liste peut être filtrée et triée. Elle distingue aussi les projets actifs et
archivés.

L’espace projet affiche entre autres :

- les heures supplémentaires approuvées;
- les entrées en attente;
- le nombre de contributeurs;
- la comparaison avec la période précédente;
- la part du projet dans les heures visibles;
- l’évolution mensuelle;
- les contributeurs;
- les entrées récentes;
- les éléments qui demandent une attention.

Le graphique mensuel utilise Chart.js. On peut survoler un point pour voir sa
valeur exacte. Une table sous le graphique donne aussi les mêmes chiffres, ce
qui est plus pratique au clavier et plus accessible qu’un graphique seulement
visuel.

Les totaux officiels de cette vue sont basés sur les heures supplémentaires
fermées et approuvées. Les entrées ouvertes, en attente ou rejetées sont
présentées séparément pour ne pas fausser le résultat.

Un projet contient notamment :

```json
{
  "projectCode": "OPS-410",
  "projectName": "Quality Review",
  "sector": "Operations",
  "colorKey": "blue",
  "markerKey": "diamond",
  "admins": ["000100001"],
  "backupAdmins": ["000100002"],
  "archived": false
}
```

Supprimer un projet dans l’usage normal l’archive. La suppression permanente
est refusée si des entrées font encore référence au projet.

L’identité visuelle combine maintenant dix couleurs et quatre formes. Ça donne
40 combinaisons possibles sans devoir inventer 40 teintes presque identiques.
Le code reste toujours visible, et le nom s’ajoute lorsque l’espace le permet :
la couleur et la forme servent de repères rapides, pas de seule façon
d’identifier un projet.

### 5.6 Modification d’une entrée et notes de supervision

Lorsqu’un superviseur modifie une entrée, il doit expliquer pourquoi. La note
garde maintenant :

- le nom de l’auteur;
- son identifiant;
- la date de mise à jour.

L’employé peut donc voir qui a laissé la note, au lieu de lire seulement
« Note du superviseur » sans savoir de qui elle vient.

La date de l’entrée peut aussi être corrigée dans la fenêtre de modification.
L’ancienne date sert à retrouver l’entrée, puis la nouvelle date est enregistrée
sans changer son identifiant ni ses autres données.

Pour éviter de perdre un formulaire commencé, cliquer à l’extérieur d’une
fenêtre de modification ne la ferme plus. Les boutons Fermer et Annuler restent
disponibles, et la touche Échap fonctionne encore.

### 5.7 Historique

Les actions importantes sont enregistrées dans `history.json` :

- ajout;
- modification;
- suppression;
- approbation;
- rejet;
- import;
- autres changements importants.

L’historique distingue la personne qui a fait l’action de l’employé concerné.
C’est important lorsqu’un superviseur travaille dans le dossier de quelqu’un
d’autre.

La vue Historique peut être filtrée et les données sont normalisées pour rester
compatibles avec les anciens enregistrements.

### 5.8 GC179

SAPHIR automatise une bonne partie de la préparation de la GC179. Le profil
contient par exemple :

- nom et prénom;
- initiales;
- PRI;
- groupe, sous-groupe et niveau;
- semaine comprimée.

L’employé peut modifier son propre profil dans Réglages. Un super admin peut
aussi le gérer depuis la fiche employé.

Les trois champs sont envoyés séparément dans le formulaire : `Groupe` vers
`Group`, `Sous-groupe` vers `SubGroup` et `Niveau` vers `Level`. Les anciens
profils qui contiennent seulement Poste et Échelon restent compatibles : ils
sont lus comme Groupe et Sous-groupe, sans inventer de Niveau.

L’export prépare les données du mois choisi et ouvre le formulaire local. Les
entrées rejetées, ouvertes et `Divers` ne sont pas envoyées dans la GC179.

Le nom du fichier suit la nomenclature demandée :

- `HRMIS_NOM_I_GC179_AAAA-MM` pour une demande payée en argent;
- `HRMIS_NOM_I_GC179_AAAA-MM_TEMPS` dès que le formulaire contient une
  demande payée en temps.

`I` correspond à l’initiale du prénom. Les accents et les caractères qui ne
sont pas permis dans un nom de fichier sont normalisés. Si le mois demande
plusieurs formulaires, un numéro de partie est ajouté avant `TEMPS`, par exemple
`000123456_SMITH_J_GC179_2026-07_1sur2_TEMPS.pdf`.

Il existe aussi un import GC179/FDF avec :

- aperçu avant l’import;
- validation de l’identité;
- sélection des lignes;
- détection des doublons;
- import atomique;
- possibilité d’annuler le lot importé.

L’ancien rapport mensuel HTML de l’employé a été retiré. Il ne faut pas le
confondre avec le rapport analytique présenté dans la section suivante.

### 5.9 Rapport analytique

Les superviseurs peuvent télécharger un rapport HTML autonome. Il a été pensé
pour être lisible sur un écran de réunion, imprimé ou enregistré en PDF.

Le rapport peut couvrir tous les projets accessibles ou un seul projet. Il
contient :

- des filtres par employé, projet, secteur, statut, mois et paiement;
- des indicateurs principaux;
- les heures par employé et par projet;
- l’évolution mensuelle;
- les répartitions par statut et paiement;
- une matrice employé-projet;
- un tableau détaillé;
- des vérifications de qualité des données;
- une exportation CSV des lignes filtrées.

Les données approuvées sont choisies par défaut. Le fichier contient tout le CSS
et le JavaScript nécessaires, donc il peut être ouvert sans avoir SAPHIR en
marche.

### 5.10 Réglages et diagnostic

Dans les réglages, l’utilisateur peut :

- choisir le thème système, clair ou sombre;
- changer son mot de passe;
- modifier son profil GC179;
- changer de langue;
- lancer un diagnostic de l’application.

Le diagnostic vérifie surtout :

- l’accès au dossier DATA;
- les droits d’écriture;
- la version du schéma;
- la présence du modèle GC179;
- certains éléments nécessaires au bon fonctionnement.

## 6. Quelques règles importantes

### Heure exacte et heure arrondie

SAPHIR garde deux versions des heures :

- `exactPunchIn` et `exactPunchOut` : l’heure réellement enregistrée;
- `punchIn` et `punchOut` : l’heure arrondie au quart d’heure.

Ça permet d’appliquer la règle de gestion sans perdre l’information originale.

### Identité d’une entrée

Les nouvelles entrées ont un `entryId` stable. C’est la meilleure façon de les
retrouver pour une modification ou une suppression.

Les anciens fichiers n’avaient pas toujours cet identifiant. Pour rester
compatible, le backend peut encore utiliser la date et l’heure exacte comme clé
de secours. Il refuse par contre les cas ambigus plutôt que de choisir une ligne
au hasard.

### Statuts

Une entrée peut être :

- `pending`;
- `approved`;
- `rejected`;
- ouverte, ce qui est déterminé par ses heures et ses drapeaux.

Les anciennes entrées sans statut explicite sont généralement traitées comme
étant en attente.

### Oubli de punch-out

Une entrée ouverte peut être marquée comme oubliée si elle dépasse la date
prévue. Dans ce cas, l’application demande une correction au lieu de fermer
silencieusement l’entrée avec une valeur inventée.

### Archivage

Archiver n’est pas supprimer. Un employé ou un projet archivé disparaît des
listes normales, mais son historique reste disponible lorsque les rapports en
ont besoin.

## 7. Comment l’application fonctionne

Voici le parcours normal, sans entrer tout de suite dans le code :

1. Le lanceur démarre le backend local sur le poste.
2. Le navigateur ouvre `http://localhost:8081/`.
3. Le frontend envoie ses requêtes au backend local.
4. Le backend valide la session et les permissions.
5. Il lit ou modifie les fichiers dans le dossier DATA partagé.
6. Après une modification réussie, il vide les caches concernés.
7. Il publie ensuite un changement dans `sync-state.json`.
8. Les autres postes détectent le changement et rafraîchissent seulement les
   vues touchées.

Chaque poste exécute donc son propre serveur, mais tous les postes partagent les
mêmes données.

## 8. Organisation du code

### 8.1 Structure actuelle

Le projet a été réorganisé pour enlever l’ancienne séparation admin/employé.
La structure principale ressemble maintenant à ceci :

```text
overtime_manager/
├── app/
│   ├── backend/
│   │   ├── saphir-server.ps1
│   │   ├── saphir-config.psd1
│   │   ├── lib/
│   │   ├── modules/
│   │   ├── routes/
│   │   └── services/
│   └── frontend/
│       ├── index.html
│       ├── assets/
│       └── scripts/
├── data/
├── deploy/bootstrap/
├── docs/
├── scripts/
├── tests/
│   ├── frontend/
│   ├── powershell/
│   ├── fixtures/
│   └── lib/
├── assets/branding/
├── README.md
└── notes.md
```

L’ancien chemin `apps/admin` est seulement reconnu par le lanceur pour pouvoir
revenir à une vieille version déjà mise en cache. Ce n’est plus l’endroit où se
trouve le code actuel.

### 8.2 Backend

Le point d’entrée est :

```text
app/backend/saphir-server.ps1
```

Le serveur charge :

- les bibliothèques générales;
- les services métier;
- les modules PowerShell plus faciles à tester;
- le catalogue des routes.

Quelques services importants :

- `AuthService.ps1` pour les comptes et les sessions;
- `EntryService.ps1` pour les entrées;
- `ReadModelService.ps1` pour préparer les données des vues;
- `SyncService.ps1` pour signaler les changements;
- `HistoryService.ps1` pour l’historique;
- `EmployeeDirectoryService.ps1` pour les employés;
- `ProjectMutationService.ps1` pour les changements de projets;
- `Gc179ExportService.ps1` et `Gc179ImportService.ps1`;
- `AnalyticsReportService.ps1`;
- `DataSchemaService.ps1`;
- `RouteDispatchService.ps1`.

Les modules purs se trouvent dans `app/backend/modules/`. J’ai commencé par y
extraire les règles qui ne lisent pas le disque et ne dépendent pas du serveur :

- routage;
- identité d’une entrée;
- état d’une entrée;
- profil GC179;
- catalogue de projets;
- profil d’accès utilisateur.

L’idée est de rendre les règles plus faciles à comprendre et à tester sans
réécrire toute l’application d’un seul coup.

### 8.3 Routes principales

Les routes sont regroupées par sujet :

```text
/auth/*
/self/*
/dashboard/*
/review/*
/employees/*
/employee/*
/projects/*
/stats/*
/history/*
/sync/*
/health
```

Quelques exemples utiles :

```text
POST /auth/login
GET  /self/bootstrap
POST /self/punch-in
POST /self/punch-out
GET  /review/bootstrap
GET  /employees/bootstrap
POST /employee/approval/{code}
POST /employee/approval/batch
GET  /projects/bootstrap
GET  /stats/projects/{code}
GET  /stats/analytics-export
GET  /sync/status
GET  /health
```

### 8.4 Frontend

Le frontend n’utilise pas de bundler. Les premiers scripts chargés sont surtout :

- `I18n.js`;
- `Utilities.js`;
- `AppShell.js`;
- `ViewSwitching.js`;
- `SelfView.js`.

Les vues de gestion sont chargées seulement quand elles deviennent nécessaires.
Ça évite de charger tout le code admin pour un employé qui n’en a pas besoin.

Chart.js est lui aussi inclus localement et chargé pour les vues qui utilisent
des graphiques.

Le frontend garde encore plusieurs fonctions globales historiques. Pendant les
phases de refactorisation, j’ai ajouté de petites API sous `window.Saphir`, par
exemple pour :

- les plages de dates;
- les statistiques d’entrées;
- les mois et les jours de calendrier;
- la recherche texte.

Les anciennes fonctions servent encore de façades pour ne pas casser les vues.

## 9. Les données

Le dossier DATA contient les fichiers métier. En développement, il se trouve
normalement dans `data/`. En production, le chemin est écrit dans la
configuration au moment de publier une version.

Les fichiers principaux sont :

```text
data/
├── data-schema.json
├── users.json
├── employeeNames.json
├── projects.json
├── overtimeCodes.json
├── paymentOptions.json
├── reasonCodes.json
├── history.json
├── sessions.json
├── sync-state.json
├── <employeeCode>_data.json
└── .locks/
```

`data-schema.json` indique la version du format. La version actuelle est la
version 1. Si l’application rencontre une version future qu’elle ne comprend
pas, elle s’arrête avant de modifier les fichiers.

### Exemple simplifié d’une entrée

```json
{
  "entryId": "entry-...",
  "entryType": "overtime",
  "date": "2026-08-20",
  "exactPunchIn": "17:03:14",
  "punchIn": "17:00:00",
  "exactPunchOut": "19:11:42",
  "punchOut": "19:15:00",
  "project": "OPS-410",
  "status": "approved",
  "workComment": "Préparation des données",
  "message": "Heures vérifiées",
  "messageAuthorName": "Camille Tremblay",
  "messageAuthorUsername": "000100001",
  "messageUpdatedAt": "2026-08-20T19:30:00Z"
}
```

Tous les anciens fichiers ne contiennent pas chaque champ. Le code accepte
encore les anciennes formes, y compris un fichier qui contient un seul objet au
lieu d’un tableau. Les nouveaux champs sont ajoutés progressivement et il n’y a
pas de migration destructive automatique.

### Règle des quarts d’heure

Pour les nouvelles entrées, les entrées modifiées et les punchs terminés dans
SAPHIR, une tranche fixe de 15 minutes compte seulement si l’employé y a fait au
moins 10 minutes. Exemple : `14:04–14:08` vaut `00:00:00`, garde les heures
exactes et sort dans Révision avec **À vérifier**. Une GC179 importée conserve
sa durée officielle, et les anciennes entrées ne sont pas recalculées en bloc.

## 10. Plusieurs postes sur le même disque partagé

C’est une partie importante du projet. Plusieurs ordinateurs peuvent lire et
modifier les mêmes fichiers JSON sur un partage SMB.

Pour éviter que deux postes écrivent au même endroit en même temps,
`FileStore.ps1` utilise :

- un verrou par ressource;
- des fichiers temporaires;
- un remplacement atomique;
- quelques tentatives lorsqu’une erreur réseau semble temporaire;
- une erreur HTTP `503` lorsque le partage est indisponible;
- une vérification supplémentaire lorsque le résultat d’une écriture est
  incertain.

Le délai normal pour obtenir un verrou est de 30 secondes. Les fichiers de
verrou sont supprimés automatiquement quand leur poignée est fermée, ce qui
réduit le risque de supprimer le verrou d’un autre processus.

Un point important : SAPHIR ne refuse pas une action simplement parce que son
cache local n’a pas encore vu le dernier `sync-state.json`. Une action métier lit
la donnée nécessaire sous verrou, fait l’écriture, puis publie le changement.

Si la donnée métier a déjà été enregistrée mais que la publication de sync
échoue, l’application garde l’écriture et retourne un avertissement. Elle ne fait
pas semblant que toute l’action a échoué.

Le frontend vérifie les changements environ toutes les 10 secondes quand
l’onglet est visible et toutes les 30 secondes quand il est caché. Il recharge
seulement les vues concernées.

## 11. Sécurité

Les mots de passe ne sont pas enregistrés directement. SAPHIR utilise PBKDF2
avec :

- HMAC-SHA1;
- un sel aléatoire;
- 120 000 itérations par défaut.

Les jetons de session sont eux aussi stockés sous forme de hash. Une session
dure normalement 12 heures.

Au premier démarrage, un compte super admin temporaire peut être créé. Il doit
changer son mot de passe avant d’utiliser normalement l’application.

L’application limite aussi les tentatives de connexion et vérifie les données
reçues par les routes.

Il faut quand même comprendre une limite de l’architecture actuelle : le backend
tourne sur le poste de chaque utilisateur sous son compte Windows. Les employés
doivent donc avoir le droit **Modifier** sur le dossier DATA partagé. Le contrôle
d’accès de SAPHIR protège les actions offertes par l’application, mais il ne
remplace pas complètement les permissions du système de fichiers.

## 12. Installation et mises à jour

### 12.1 Ce qui est publié

Le script principal est :

```powershell
./scripts/package-app.ps1
```

Il crée une distribution de ce genre :

```text
SAPHIR-Distribution/
├── Install SAPHIR Shortcut.vbs
├── SAPHIR Launcher.vbs
├── Launch SAPHIR.bat
├── Launch SAPHIR.vbs
├── Stop SAPHIR.bat
├── Stop SAPHIR.vbs
└── deployment/
    ├── current.json
    └── releases/
        └── SAPHIR-<ReleaseId>.zip
```

Le ZIP contient l’application, mais jamais le dossier DATA de production. Il
n’inclut pas non plus les tests ou les scripts de données de démonstration.

`current.json` est très important : le lanceur ne cherche pas automatiquement
le ZIP le plus récent dans `releases/`. Il suit seulement le fichier indiqué par
`current.json`.

Donc, copier un ZIP manuellement dans le dossier ne publie pas vraiment une
nouvelle version.

### 12.2 Première installation

Sur un poste Windows :

1. ouvrir le dossier partagé `SAPHIR-Distribution`;
2. exécuter `Install SAPHIR Shortcut.vbs`;
3. utiliser ensuite le raccourci SAPHIR créé sur le Bureau;
4. cliquer sur Démarrer dans le lanceur.

Le lanceur lui-même est copié dans :

```text
%LOCALAPPDATA%\SAPHIR\launcher\versions\<bundleId>
```

L’application est copiée dans :

```text
%LOCALAPPDATA%\SAPHIR\versions\<ReleaseId>
```

Le backend ne roule donc pas directement depuis le disque réseau. Ça rend le
démarrage plus rapide et évite d’exécuter les scripts depuis un partage lent.

### 12.3 À quoi servent les boutons du lanceur

- **Actualiser** : relit l’état et indique si une mise à jour existe. Il
  n’installe rien.
- **Ouvrir SAPHIR** : ouvre l’application déjà en marche dans le navigateur.
- **Démarrer SAPHIR** : installe la version ciblée au besoin, puis démarre le
  backend.
- **Redémarrer** : arrête proprement l’ancienne version, installe la nouvelle et
  redémarre.
- **Arrêter** : arrête le backend géré par SAPHIR.

### 12.4 Publication normale

Exemple :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-app.ps1 `
  -OutputRoot "\\serveur\service\Applications" `
  -DataFolderPath "\\serveur\service\SAPHIR-Data" `
  -NoZip
```

Le script :

1. prépare le contenu;
2. crée le ZIP de la version;
3. calcule son SHA-256;
4. copie et vérifie le ZIP;
5. met à jour `current.json` en dernier.

Cet ordre évite qu’un poste voie une version qui n’a pas fini d’être copiée.

### 12.5 À quoi sert `-BootstrapOnly`

Cette option met seulement à jour les fichiers du lanceur sur le partage :

- l’installateur;
- les scripts du lanceur;
- l’icône;
- les bibliothèques nécessaires au lancement.

Elle ne :

- publie pas de nouvelle version de l’application;
- crée pas de ZIP applicatif;
- modifie pas `current.json`;
- touche pas au dossier DATA;
- remplace pas automatiquement le lanceur déjà installé dans AppData.

Après un changement important du lanceur, les utilisateurs doivent relancer
`Install SAPHIR Shortcut.vbs`. Ensuite, une publication normale reste nécessaire
pour envoyer une nouvelle version de l’application.

Cette étape a surtout servi pendant le passage de l’ancien dossier `apps/admin`
au dossier unifié `app/`.

### 12.6 Retour arrière

Si une nouvelle version ne s’installe pas ou ne démarre pas, le lanceur essaie
de revenir à la version précédente. Il crée alors :

```text
%LOCALAPPDATA%\SAPHIR\failed.json
```

Le même identifiant et le même hash ne seront pas réessayés sans raison. Le plus
simple est normalement de corriger le problème et de publier avec un nouveau
`ReleaseId`.

Les fichiers utiles se trouvent ici :

```text
%LOCALAPPDATA%\SAPHIR\
├── active.json
├── failed.json
├── versions\
├── launcher\versions\
└── runtime\
    ├── logs\
    └── pids\
```

## 13. Tests et refactorisation

La commande principale pour les tests est :

```powershell
./scripts/test-all.ps1
```

Le script découvre automatiquement :

- les tests PowerShell sous `tests/powershell/`;
- les tests JavaScript sous `tests/frontend/`.

Les données de test sont dans `tests/fixtures/`. Les tests qui modifient des
données travaillent sur une copie temporaire, jamais directement dans le DATA
normal du projet.

La suite couvre entre autres :

- les routes HTTP;
- les permissions;
- les formats JSON anciens et nouveaux;
- les écritures concurrentes;
- les erreurs du disque partagé;
- les verrous;
- la synchronisation;
- le lanceur et le cache local;
- la création du ZIP;
- la GC179;
- le rapport analytique;
- les comportements importants de l’interface.

La CI Windows exécute les tests sous Windows PowerShell 5.1.

### Ce qui a vraiment été refactorisé

Les phases 0 à 6 n’ont pas transformé tout le projet en architecture parfaite.
Elles ont surtout permis de travailler sans casser les fonctions existantes.

En résumé :

- phase 0 : tests de base, contrat DATA, concurrence et compatibilité;
- phase 1 : première frontière de routage et règles d’architecture;
- phase 2 : identité des entrées et plages de dates;
- phase 3 : règles des projets et statistiques partagées;
- phase 4 : état des entrées et modèle mensuel;
- phase 5 : profil GC179 et jours de calendrier;
- phase 6 : accès utilisateur et recherche texte.

Après ça, j’ai aussi réorganisé le dépôt : l’application est maintenant sous
`app/`, les tests sont sous `tests/` et l’ancien dossier `apps/employee` a été
retiré.

Il reste quand même du travail. Certaines vues JavaScript et certains services
PowerShell sont encore gros. Les routes utilisent encore une portée dynamique
historique. Je préfère continuer par petites étapes avec des tests plutôt que
faire une grosse réécriture risquée.

## 14. Problèmes connus et diagnostic

### Une version est dans `releases`, mais elle n’apparaît pas

Le lanceur ne parcourt pas tous les ZIP. Il regarde `deployment/current.json`.
Il faut donc vérifier :

- que `current.json` pointe vers le bon `ReleaseId`;
- que `packagePath` correspond au bon ZIP;
- que le hash est le même;
- que le chemin DATA est accessible.

### La version ciblée existe, mais aucun dossier n’apparaît dans AppData

Le bouton Actualiser ne fait qu’un diagnostic. Il faut cliquer sur Démarrer ou
Redémarrer pour installer la version.

Si la même version a déjà échoué, vérifier `failed.json` et `bootstrap.log`.

### L’application prend beaucoup de temps à se connecter

Il n’y a pas volontairement une attente de 30 à 60 minutes. Un délai aussi long
indique plutôt qu’un appel au disque partagé ou au réseau Windows est bloqué.

La connexion fait plus qu’une vérification de mot de passe :

1. le backend lit les comptes;
2. il écrit la session partagée;
3. le frontend charge ensuite les données personnelles;
4. ces opérations lisent plusieurs fichiers sur DATA.

Le serveur traite actuellement les requêtes une à la fois. Si une opération SMB
reste bloquée, les requêtes suivantes attendent derrière elle.

Pour trouver où ça bloque, regarder dans les outils réseau du navigateur :

- `POST /auth/login` lent : comptes, session, verrou ou partage;
- login rapide mais `GET /self/bootstrap` lent : données de l’employé ou
  catalogues partagés;
- requêtes rapides mais interface lente : trop de données à afficher ou problème
  JavaScript.

Il faut aussi vérifier que l’URL API est bien :

```text
http://localhost:8081/
```

### L’application n’a plus de styles

Ce problème venait d’une réponse HTTP `304` vide qui était mal gérée. Le backend
accepte maintenant correctement une réponse sans contenu et les fichiers
frontend ont une version de cache dans leur URL.

Une page déjà ouverte garde quand même ses anciens styles en mémoire. Après une
mise à jour, un rechargement normal de la page peut être nécessaire.

### Le port 8081 est occupé

Le lanceur vérifie que le processus appartient bien à SAPHIR. Il ne doit pas
fermer un autre programme simplement parce qu’il utilise le même port.

### Journaux utiles

```text
%LOCALAPPDATA%\SAPHIR\runtime\logs\bootstrap.log
%LOCALAPPDATA%\SAPHIR\runtime\logs\launcher-startup.log
%LOCALAPPDATA%\SAPHIR\runtime\logs\app.stdout.log
%LOCALAPPDATA%\SAPHIR\runtime\logs\app.stderr.log
```

## 15. Limites actuelles

Le projet fonctionne, mais il a encore certaines limites :

- le serveur `HttpListener` traite les requêtes une à la fois;
- une opération SMB très lente peut bloquer les requêtes suivantes;
- les appels frontend n’ont pas encore tous une limite de temps claire;
- les données JSON conviennent à la taille actuelle, mais pas à une très grande
  organisation;
- les utilisateurs ont besoin du droit Modifier sur DATA;
- les couleurs seules ne suffiront pas pour reconnaître 40 projets;
- certains fichiers JavaScript et PowerShell sont encore trop gros;
- les anciennes façades de compatibilité ne peuvent pas encore toutes être
  retirées;
- les tests locaux ne remplacent pas un vrai essai avec deux postes Windows et
  une coupure réseau.

Ces limites ne veulent pas dire que l’application est inutilisable. Elles
indiquent surtout les endroits où le projet devra évoluer si son usage grandit.

## 16. Ce que je veux améliorer ensuite

### Continuer à améliorer l’affichage d’environ 40 projets

Créer 40 couleurs différentes n’aurait pas été une bonne solution. Plusieurs
teintes auraient fini par se ressembler, surtout en mode sombre ou pour une
personne qui distingue moins bien certaines couleurs.

J’ai donc ajouté un système qui combine plusieurs indices :

- dix couleurs stables;
- quatre formes stables pour distinguer les projets;
- le code toujours visible, avec le nom lorsque l’espace le permet;
- les graphiques limités aux projets les plus importants, avec « Autres » pour
  le reste;
- des formes de points et des styles de lignes différents dans les graphiques;
- une table de valeurs exactes lorsque le graphique est plus difficile à lire.

Une combinaison de 10 couleurs et 4 formes donne 40 identités possibles. Le
champ `markerKey` est optionnel : un ancien projet qui ne l’a pas reçoit une
forme stable à partir de son code, sans modifier son fichier ni changer sa
couleur existante.

Lorsqu’on crée un projet, l’éditeur propose la première combinaison libre. Il
indique aussi si le choix actuel est déjà utilisé. Il reste encore possible de
choisir volontairement une autre combinaison.

La prochaine amélioration pour les très grandes listes serait d’ajouter une
légende recherchable et des filtres encore plus rapides. Même avec 40 identités,
un graphique contenant 40 lignes en même temps ne serait pas vraiment lisible.

### Performance du disque partagé

Les prochaines améliorations les plus utiles seraient :

- mesurer la durée de chaque requête sans écrire de données sensibles dans les
  journaux;
- ajouter des délais d’attente clairs côté navigateur;
- éviter qu’une seule lecture réseau lente bloque toutes les autres requêtes;
- réduire le nombre de fichiers lus pendant une connexion;
- tester les déconnexions SMB sur deux vrais postes Windows.

### Continuer le ménage dans le code

Je veux aussi continuer à :

- découper les grandes vues JavaScript;
- réduire la taille de `AuthService.ps1` et `ReadModelService.ps1`;
- transformer progressivement les routes en fonctions plus explicites;
- retirer les façades devenues inutiles;
- mieux séparer l’affichage, les appels API et les règles métier;
- simplifier le CSS qui s’est accumulé avec les différentes interfaces.

## 17. Petit guide d’utilisation

### Pour un employé

1. Ouvrir SAPHIR avec le raccourci du Bureau.
2. Cliquer sur Démarrer si l’application n’est pas déjà en marche.
3. Se connecter.
4. Commencer une entrée dans Mes heures.
5. Choisir le projet et les options demandées.
6. Terminer l’entrée et décrire le travail effectué.
7. Vérifier le mois avant de préparer la GC179.

### Pour un admin

1. Vérifier le Centre de commandes.
2. Ouvrir Révision pour traiter les entrées en attente.
3. Utiliser les filtres avant une approbation en lot.
4. Ouvrir un projet pour consulter ses détails et ses tendances.
5. Utiliser la fiche employé lorsqu’une analyse plus complète est nécessaire.
6. Télécharger le rapport analytique pour une réunion ou une analyse détaillée.

### Pour un super admin

En plus des étapes précédentes :

1. gérer les comptes et les mots de passe;
2. configurer les permissions et les types d’entrée;
3. créer, archiver ou restaurer les projets;
4. gérer les profils GC179;
5. surveiller les entrées d’admins et les entrées `Divers`;
6. utiliser le diagnostic avant de modifier manuellement des fichiers.

## 18. Documents utiles

Les autres documents importants du dépôt sont :

- `README.md` pour commencer rapidement;
- `docs/ARCHITECTURE.md` pour les choix techniques et les limites;
- `docs/LOCAL-CACHE-DEPLOYMENT.md` pour la publication et le cache local;
- `docs/TESTING.md` pour les tests;
- `docs/EMPLOYEE-QUICK-START.md` pour un guide utilisateur court;
- `app/backend/README.md` pour le backend;
- `docs/GC179.pdf` pour le modèle officiel.

Le code et les tests restent la référence lorsqu’un ancien document contredit le
fonctionnement réel.

## 19. Conclusion

SAPHIR a commencé comme une façon d’éviter des courriels répétitifs, mais le
projet est devenu un vrai outil de suivi, de révision et d’analyse.

Ce que je trouve le plus important est que l’application garde une trace claire
des actions tout en restant assez simple pour les employés. Elle ne dépend pas
d’un service externe et elle peut fonctionner dans l’environnement Windows déjà
utilisé par le département.

Le projet n’est pas « terminé pour toujours ». Il reste des défis, surtout pour
les délais du disque partagé, la taille de certains fichiers de code et la
gestion visuelle d’un grand nombre de projets. Par contre, les bases sont en
place : une application unifiée, des données protégées, des tests, un système de
versions et des fonctions qui répondent beaucoup mieux au besoin de départ.
