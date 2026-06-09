# Documentation du projet - Gestion des heures GÉEM

## 1. Présentation générale

Ce projet est une application interne de gestion des heures pour GÉEM. À la base, l’objectif était surtout de mieux gérer les heures supplémentaires, mais l’application permet maintenant aussi de gérer une catégorie de temps plus générale appelée `Divers`, utilisée pour certains types de travail qui ne sont pas nécessairement des heures supplémentaires.

L’application sert à centraliser les entrées de temps des employés, à donner aux superviseurs une vue claire de ce qui doit être approuvé, et à faciliter la préparation des formulaires mensuels. Elle a été pensée pour un environnement de travail assez réaliste : environ 30 à 40 employés, 10 à 20 projets actifs, un poste de travail Windows parfois limité, et un dossier de données qui peut éventuellement être placé sur un lecteur réseau partagé.

Le projet fonctionne comme une application web locale. Le backend est écrit en PowerShell et l’interface est écrite en HTML, CSS et JavaScript. Les données sont stockées dans des fichiers JSON dans le dossier `data/`.

Le point important est que l’application est maintenant unifiée. Il n’y a pas une application employé et une application administrateur séparées. Tout passe par la même interface et le même backend. Après la connexion, l’application adapte les vues disponibles selon le rôle de la personne connectée.

## 2. Problème à résoudre

Avant l’application, le suivi des heures supplémentaires se faisait surtout par courriel. Quand un employé commençait une période de temps supplémentaire, il devait envoyer un courriel d’entrée au superviseur. Quand il terminait, il devait envoyer un deuxième courriel de sortie.

À la fin du mois, les employés devaient ensuite retourner dans Outlook, retrouver les courriels envoyés, recopier les heures dans leur formulaire de temps supplémentaire, puis ajouter les autres informations nécessaires comme la raison, le paiement, le code d’heures supplémentaires et le projet.

Cette méthode fonctionnait, mais elle devenait vite lourde avec plusieurs employés. Les problèmes principaux étaient :

- il fallait chercher manuellement dans les courriels à chaque fin de mois;
- l’information était répartie entre Outlook, les formulaires et les notes du superviseur;
- les corrections étaient difficiles à suivre proprement;
- il n’y avait pas de filtre simple par projet;
- il n’y avait pratiquement aucune façon d’analyser les heures par employé, projet, secteur ou période;
- le superviseur devait garder une vue d’ensemble à partir de beaucoup d’informations dispersées.

Le programme ne cherche pas à remplacer toute la gestion officielle des formulaires. Il sert plutôt à structurer l’information avant cette étape, pour que les entrées soient plus faciles à consulter, corriger, approuver et exporter.

## 3. Objectifs du projet

Les objectifs principaux sont les suivants :

- permettre aux employés d’entrer leurs périodes de temps sans passer par des courriels d’entrée et de sortie;
- centraliser les entrées dans un dossier de données commun;
- réduire les erreurs de transcription à la fin du mois;
- garder l’heure exacte du punch et l’heure arrondie au quart d’heure pour la gestion;
- donner aux superviseurs une vue claire des approbations en attente;
- permettre l’analyse des heures par employé, projet, secteur et période;
- garder un historique des actions importantes;
- gérer les employés, les projets, les accès et les mots de passe depuis l’interface;
- rester compatible avec Windows PowerShell 5.1;
- éviter les dépendances lourdes comme une base de données externe ou un serveur web complet.

## 4. Fonctionnalités principales

### Connexion et rôles

L’application possède un système de connexion interne. Les utilisateurs sont stockés dans `data/users.json`.

Les rôles utilisés sont :

- `employee` : accès à l’espace employé;
- `admin` : accès aux vues de supervision et aux données administratives;
- `superAdmin` : accès complet à la configuration, aux projets, aux employés et aux entrées sensibles.

Il y a aussi la notion d’admin remplaçant sur un projet, mais ce n’est pas un rôle séparé dans le fichier utilisateur. Un admin remplaçant reste un utilisateur avec le rôle `admin`, simplement ajouté dans la liste `backupAdmins` d’un projet.

Les règles importantes sont :

- un employé voit seulement son espace personnel;
- un admin peut consulter les statistiques et les entrées globales, mais ne peut modifier que les entrées liées aux projets qu’il supervise ou pour lesquels il est remplaçant;
- un super admin peut tout gérer;
- les entrées d’admins doivent être approuvées par un super admin;
- les entrées de type `Divers` sont supervisées et modifiées seulement par les super admins.

### Espace employé

Dans son espace, un employé peut :

- démarrer une entrée d’heures supplémentaires;
- sélectionner le projet avant de démarrer;
- sélectionner le code d’heures supplémentaires;
- sélectionner le type de paiement, par exemple `En espèce` ou `Congé`;
- sélectionner la raison;
- terminer une entrée en cours;
- voir ses entrées dans une liste et dans une vue calendrier;
- consulter ses statistiques personnelles;
- voir des statistiques par projet;
- exporter ses entrées mensuelles dans une page HTML séparée.

Les entrées rejetées ne sont pas incluses dans l’export mensuel.

### Entrées de type Divers

Le projet supporte aussi des entrées de type `Divers`. Cette catégorie sert à déclarer certains travaux qui ne sont pas des heures supplémentaires classiques. Par exemple, une personne pourrait déclarer une période de télétravail liée à SAPHIR.

Cette option est configurable par employé. Dans `data/users.json`, la propriété `timeEntryTypes` peut contenir :

```json
["overtime", "diverse"]
```

Quand un employé a accès au type `Divers` :

- au punch-in, il doit écrire une raison courte sur une ligne;
- au punch-out, il doit écrire un résumé du travail effectué;
- l’entrée ne demande pas de projet, code de temps supplémentaire, paiement ou code de raison;
- la supervision et la modification reviennent aux super admins.

### Centre de commandes

Le centre de commandes est la vue principale pour les superviseurs. Il contient notamment :

- les projets supervisés par l’admin connecté;
- les approbations en attente;
- les sessions actives;
- un dossier employé avec recherche;
- les entrées récentes;
- les notes de gestionnaire;
- les actions rapides comme approuver, modifier, supprimer ou ouvrir la fiche d’un employé.

L’objectif de cette page est d’éviter d’avoir à naviguer partout pour faire les opérations courantes.

### Vue Révision

La vue Révision sert surtout aux approbations. Elle permet de filtrer les entrées par employé, projet, période, statut et recherche texte. Elle supporte aussi l’approbation en lot avec des filtres.

Quand une action importante est faite, l’application demande une note de gestionnaire dans les cas où c’est nécessaire, par exemple pour un rejet, une modification ou une suppression.

### Vue Personnel

La vue Personnel sert à gérer les employés et à consulter leurs données.

Elle permet de :

- chercher par nom, code employé, projet, code projet ou secteur;
- voir les employés séparés par sections pour les admins, l’équipe liée aux projets supervisés et les autres employés;
- ouvrir une fiche employé;
- consulter une vue calendrier;
- consulter une répartition par projet;
- approuver, modifier ou supprimer certaines entrées directement dans les sections de détail;
- ajouter une entrée manuellement;
- ajouter, modifier, archiver ou réactiver un employé;
- réinitialiser ou définir un mot de passe;
- configurer les types d’entrée autorisés pour un employé.

Les employés archivés ne sont pas supprimés physiquement. Ils restent disponibles pour l’historique.

### Vue Projets

La vue Projets sert à consulter et gérer les projets.

Elle permet de :

- voir les projets actifs ou archivés;
- gérer les admins et admins remplaçants d’un projet;
- modifier les informations du projet;
- consulter les statistiques du projet;
- voir une répartition par employé;
- naviguer vers la fiche d’un employé filtrée sur le projet;
- consulter des graphiques, comme la distribution des projets par secteur et la répartition des heures par projet.

Les projets ont des attributs comme :

- `projectCode`;
- `projectName`;
- `sector`;
- `admins`;
- `backupAdmins`;
- `archived`.

### Historique et activité récente

Les actions importantes sont conservées dans `data/history.json`. L’historique permet de savoir ce qui a été fait, par qui, sur quelle entrée ou quel employé.

L’application distingue maintenant mieux l’auteur de l’action et l’employé concerné. Par exemple, dans une activité récente, le titre peut être l’auteur et le message peut préciser l’employé touché.

### Rapports mensuels HTML

L’application peut ouvrir un rapport mensuel dans un nouvel onglet. Le rapport contient un tableau avec :

- Jour;
- Raison;
- Heure de début;
- Heure de fin;
- Code de temps supplémentaire;
- Paiement;
- Temps total.

Le style est volontairement simple, avec peu de bordures, pour être lisible et proche d’un tableau propre. Ce rapport ne remplace pas encore un PDF officiel rempli automatiquement, mais il aide à rassembler les informations au même endroit.

### Données de démonstration

Pour les présentations, il existe un bouton dans l’interface permettant de générer des entrées de démonstration. La logique backend est dans `apps/admin/backend/services/SeedService.ps1` et la route utilisée est `POST /seed/demo-entries`.

Le script `scripts/seed-presentation-data.ps1` permet aussi de créer un jeu de données plus complet avec environ 30 employés, plusieurs projets et des entrées réparties sur plusieurs mois.

## 5. Fonctionnement général

Un scénario normal ressemble à ceci :

1. L’utilisateur lance l’application avec un raccourci ou un script.
2. Le script démarre le backend PowerShell si celui-ci n’est pas déjà disponible.
3. Le navigateur ouvre `http://localhost:8081/`.
4. L’utilisateur se connecte.
5. Le backend crée une session et retourne un jeton de session.
6. Le frontend charge les données nécessaires selon le rôle.
7. Quand une entrée est créée ou modifiée, le backend écrit dans les fichiers JSON du dossier `data/`.
8. Le fichier `data/sync-state.json` est mis à jour.
9. Les autres vues ouvertes détectent le changement et rafraîchissent seulement ce qui est nécessaire.

## 6. Architecture technique

### Vue d’ensemble

Le projet est organisé autour d’une seule application :

```text
overtime_manager/
  apps/admin/backend/      backend PowerShell
  apps/admin/frontend/     interface web
  data/                    fichiers JSON de données
  scripts/                 lancement, arrêt, tests et outils
  runtime/                 PID, logs et fichiers temporaires
  docs/                    notes techniques supplémentaires
```

Les anciens dossiers `apps/employee/` peuvent encore exister comme compatibilité, mais le vrai point d’entrée est maintenant l’application unifiée sous `apps/admin/`.

### Backend PowerShell

Le backend principal est :

```text
apps/admin/backend/admin-server.ps1
```

Il utilise `System.Net.HttpListener`. Par défaut, il écoute sur :

```text
http://localhost:8081/
```

Le fichier de configuration principal est :

```text
apps/admin/backend/admin-config.psd1
```

Exemple actuel :

```powershell
@{
    ListenerPrefix = "http://localhost:8081/"
    DataFolderPath = "../../../data"
}
```

`DataFolderPath` peut être remplacé par un chemin absolu vers un dossier réseau si on veut déplacer les données hors du dépôt.

### Services backend

Les services importants sont :

| Fichier | Rôle |
| --- | --- |
| `AuthService.ps1` | Connexion, mots de passe, sessions, rôles et permissions. |
| `EntryService.ps1` | Normalisation des entrées, arrondi au quart d’heure, calculs de durée, oubli de punch-out. |
| `ReadModelService.ps1` | Prépare les données utilisées par les vues et garde des caches de lecture. |
| `EmployeeDirectoryService.ps1` | Gestion des employés, fiches et fichiers associés. |
| `ProjectStatsService.ps1` | Statistiques liées aux projets. |
| `HistoryService.ps1` | Journal des actions importantes. |
| `SyncService.ps1` | Gestion de l’état de synchronisation entre les vues ouvertes. |
| `SeedService.ps1` | Génération de données de démonstration. |

### Routes backend

Les routes sont séparées dans `apps/admin/backend/routes/`. Quelques routes importantes :

| Route | Utilité |
| --- | --- |
| `GET /` | Sert l’interface web. |
| `POST /auth/login` | Connexion. |
| `GET /auth/me` | Vérifie la session courante. |
| `POST /auth/logout` | Déconnexion. |
| `POST /auth/change-password` | Changement de mot de passe. |
| `GET /self/bootstrap` | Chargement initial de l’espace employé. |
| `POST /self/punch` | Punch-in ou punch-out. |
| `GET /dashboard/bootstrap` | Données du centre de commandes. |
| `GET /employees/bootstrap` | Données initiales de la vue Personnel. |
| `GET /employee/{code}` | Chronologie et statistiques d’un employé. |
| `POST /employee/add/{code}` | Ajout manuel d’une entrée. |
| `PUT /employee/{code}` | Modification d’une entrée. |
| `DELETE /employee/{code}` | Suppression d’une entrée. |
| `POST /employee/{code}/approve` | Approbation ou rejet. |
| `POST /employee/batch-approve` | Approbation en lot. |
| `GET /projects/bootstrap` | Données initiales de la vue Projets. |
| `POST /projects` | Création d’un projet. |
| `PUT /projects/{code}` | Modification d’un projet. |
| `DELETE /projects/{code}` | Archivage d’un projet. |
| `GET /history` | Historique et activité récente. |
| `GET /sync/status` | État utilisé pour le rafraîchissement léger. |
| `POST /seed/demo-entries` | Génération d’entrées de démonstration. |

### Frontend

Le frontend principal est :

```text
apps/admin/frontend/index.html
```

Les scripts JavaScript sont dans :

```text
apps/admin/frontend/scripts/
```

Les fichiers les plus importants sont :

| Fichier | Rôle |
| --- | --- |
| `AppShell.js` | Session, langue, thème, navigation, synchronisation et appels API. |
| `I18n.js` | Traductions français/anglais. |
| `Utilities.js` | Fonctions communes : dates, durées, statuts, exports HTML, modales, toasts. |
| `ViewSwitching.js` | Changement de vue dans l’interface. |
| `Views/SelfView.js` | Espace employé. |
| `Views/DashboardView.js` | Centre de commandes. |
| `Views/ApprovalsView.js` | Révision et approbations. |
| `Views/EmployeesView.js` | Vue Personnel. |
| `Views/ProjectsView.js` | Vue Projets. |
| `Views/HistoryView.js` | Historique. |

Le style principal est dans :

```text
apps/admin/frontend/assets/styles.css
```

Les bibliothèques frontend sont locales dans `apps/admin/frontend/assets/vendor/`. Cela évite de dépendre d’un CDN externe, ce qui est important sur un réseau de travail restreint.

## 7. Stockage des données

Les données sont stockées dans le dossier `data/`. Les fichiers principaux sont :

| Fichier | Description |
| --- | --- |
| `users.json` | Utilisateurs, rôles, hash de mot de passe, types d’entrée autorisés. |
| `employeeNames.json` | Liste d’employés et noms affichés. |
| `projects.json` | Projets, secteurs, admins, admins remplaçants, archivage. |
| `*_data.json` | Entrées de temps de chaque employé. |
| `history.json` | Historique des actions. |
| `sessions.json` | Sessions actives, avec jetons hashés. |
| `sync-state.json` | Version de synchronisation utilisée par le frontend. |
| `overtimeCodes.json` | Codes d’heures supplémentaires. |
| `paymentOptions.json` | Options de paiement. |
| `reasonCodes.json` | Codes de raison. |
| `.locks/` | Fichiers de verrouillage utilisés pendant les écritures. |

### Exemple simplifié d’une entrée d’heures supplémentaires

```json
{
  "entryId": "...",
  "entryType": "overtime",
  "date": "2026-06-08",
  "punchIn": "17:15",
  "punchOut": "19:00",
  "exactPunchIn": "17:13",
  "exactPunchOut": "18:58",
  "overtime": "01h 45m",
  "projectCode": "APP-220",
  "overtimeCode": "260",
  "paymentOption": "leave",
  "reasonCode": "D",
  "status": "pending",
  "message": ""
}
```

Le système garde l’heure exacte et l’heure arrondie. L’heure arrondie est utilisée pour la gestion, tandis que l’heure exacte permet de savoir ce qui s’est réellement passé.

### Exemple simplifié d’une entrée Divers

```json
{
  "entryId": "...",
  "entryType": "diverse",
  "date": "2026-06-08",
  "punchIn": "07:30",
  "punchOut": "09:00",
  "exactPunchIn": "07:25",
  "exactPunchOut": "08:55",
  "diverseReason": "Télétravail pour SAPHIR",
  "diverseSummary": "Correction de dossiers et suivi avec l'équipe.",
  "status": "pending"
}
```

## 8. Sécurité et permissions

L’application n’utilise pas de mots de passe en clair. Dans `AuthService.ps1`, les mots de passe sont hashés avec PBKDF2 et un sel par utilisateur. Les jetons de session sont aussi stockés sous forme hashée dans `sessions.json`.

Cela dit, il faut être honnête : les fichiers JSON de données ne sont pas chiffrés. JSON est un format de stockage, pas un mécanisme de sécurité. Les entrées, projets et historiques restent lisibles si quelqu’un a accès au dossier `data/`.

Pour un déploiement sur lecteur réseau, la bonne pratique est :

- mettre `data/` dans un dossier partagé contrôlé;
- donner l’accès en modification seulement au compte qui exécute le backend;
- éviter que tous les employés puissent parcourir ou modifier les fichiers JSON directement;
- donner aux utilisateurs l’accès à l’application, pas au dossier de données;
- faire des sauvegardes régulières du dossier `data/`.

Le backend valide les permissions côté serveur. Le frontend masque aussi les boutons non disponibles, mais ce n’est pas la protection principale.

## 9. Concurrence, intégrité et synchronisation

Comme le projet n’utilise pas de base de données, il faut être prudent avec les écritures simultanées. Le fichier `apps/admin/backend/lib/FileStore.ps1` contient la logique utilisée pour réduire les risques :

- verrous par ressource avec fichiers `.lock`;
- écritures atomiques avec fichiers temporaires;
- invalidation des caches après écriture;
- lecture JSON centralisée;
- caches de fichiers pour éviter de relire inutilement les mêmes fichiers.

Le système utilise aussi `sync-state.json`. Quand une donnée importante change, la version de synchronisation est mise à jour. Le frontend appelle `GET /sync/status` périodiquement et rafraîchit la vue active seulement quand une vraie modification est détectée.

Ce modèle est le meilleur compromis possible avec les contraintes du projet : PowerShell, JavaScript, fichiers Windows et JSON. Pour une utilisation plus grosse ou plus critique, une vraie base de données serait plus robuste.

## 10. Performance

Plusieurs optimisations ont été ajoutées parce que les postes de travail du réseau peuvent être lents, surtout si le dossier `data/` est sur un lecteur partagé.

Les optimisations principales sont :

- regroupement de plusieurs chargements dans des routes `bootstrap`;
- cache de lecture côté backend;
- cache des fichiers statiques avec ETag;
- bibliothèques frontend locales au lieu de CDN;
- rafraîchissement seulement quand `sync-state.json` change;
- ralentissement automatique du polling quand l’onglet est caché;
- moins de rechargements complets quand on change d’onglet;
- filtres frontend quand les données sont déjà chargées;
- structure des vues pensée pour 30 à 40 employés et 10 à 20 projets.

Même avec ces optimisations, le point le plus lent peut rester le lecteur réseau. Chaque lecture/écriture de fichier dépend de la vitesse du partage, de l’antivirus, des permissions et du poste client.

## 11. Technologies utilisées

| Technologie | Utilisation |
| --- | --- |
| PowerShell 5.1 | Backend, routes HTTP, lecture/écriture JSON, scripts de lancement. |
| `System.Net.HttpListener` | Serveur HTTP local. |
| JavaScript vanilla | Logique frontend sans framework lourd. |
| HTML/CSS | Interface utilisateur. |
| JSON | Stockage des utilisateurs, entrées, projets, sessions et historiques. |
| Chart.js | Graphiques dans les vues de statistiques. |
| Bootstrap local | Quelques composants et bases de style. |
| Font Awesome local | Icônes dans l’interface. |

Le choix de PowerShell 5.1 est volontaire, parce que c’est disponible sur beaucoup de postes Windows sans installation supplémentaire. Le projet fonctionne aussi avec `pwsh` sur macOS.

## 12. Installation et configuration

### Prérequis

Sur Windows :

- Windows PowerShell 5.1 ou plus récent;
- un navigateur moderne;
- accès en lecture au dossier du projet;
- accès en écriture au dossier `data/` pour le compte qui exécute le backend.

Sur macOS :

- PowerShell 7 (`pwsh`);
- un navigateur moderne.

### Lancement sur Windows

La façon la plus simple est d’utiliser les lanceurs :

```text
Launch GEEM.bat
Launch GEEM.vbs
```

Pour arrêter l’application :

```text
Stop GEEM.bat
Stop GEEM.vbs
```

On peut aussi utiliser PowerShell directement :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launch-app.ps1
```

ou démarrer en arrière-plan :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-all.ps1
```

### Lancement sur macOS

Sur macOS, il faut utiliser `pwsh` au lieu de `powershell.exe` :

```bash
pwsh ./scripts/launch-app.ps1
```

ou :

```bash
./Launch\ GEEM.command
```

Pour arrêter :

```bash
pwsh ./scripts/stop-all.ps1
```

### Commandes utiles

```powershell
# Démarrer en arrière-plan
./scripts/start-all.ps1

# Vérifier le statut
./scripts/status-all.ps1

# Arrêter
./scripts/stop-all.ps1

# Redémarrer
./scripts/restart-all.ps1
```

### Modifier le dossier de données

Le chemin des données se configure dans :

```text
apps/admin/backend/admin-config.psd1
```

Exemple avec un dossier réseau :

```powershell
@{
    ListenerPrefix = "http://localhost:8081/"
    DataFolderPath = "\\SERVEUR\Partage\GEEM\data"
}
```

Il faut ensuite s’assurer que le compte qui lance le backend a les droits de lecture et d’écriture sur ce dossier.

### Premier compte administrateur

Le backend peut initialiser un compte super admin de base si les fichiers de données n’existent pas encore.

Les valeurs par défaut sont :

```text
Nom d'utilisateur : admin
Mot de passe      : ChangeMe123!
```

Ce mot de passe doit être changé rapidement dans une vraie utilisation.

## 13. Guide d’utilisation rapide

### Pour un employé

1. Ouvrir l’application.
2. Se connecter.
3. Choisir le type d’entrée si plusieurs types sont disponibles.
4. Pour les heures supplémentaires, choisir le projet, le code, le paiement et la raison.
5. Cliquer sur le bouton de démarrage.
6. À la fin, cliquer sur le bouton de sortie.
7. Consulter le calendrier ou l’historique au besoin.
8. Générer le rapport HTML mensuel si nécessaire.

### Pour un admin

1. Se connecter avec un compte admin.
2. Consulter le centre de commandes.
3. Vérifier les approbations en attente.
4. Utiliser les filtres pour trouver un employé, un projet ou une période.
5. Modifier, approuver ou rejeter les entrées selon les permissions.
6. Consulter la vue Personnel pour analyser un employé.
7. Consulter la vue Projets pour analyser les projets et les secteurs.

### Pour un super admin

En plus des actions d’un admin, un super admin peut :

- gérer tous les projets;
- gérer les employés et les rôles;
- approuver les entrées d’admins;
- superviser les entrées `Divers`;
- générer des données de démonstration;
- réinitialiser les mots de passe;
- corriger les cas plus sensibles.

## 14. Structure des fichiers importants

```text
overtime_manager/
  README.md
  DOCUMENTATION_PROJET.md
  Launch GEEM.bat
  Launch GEEM.command
  Launch GEEM.vbs
  Stop GEEM.bat
  Stop GEEM.command
  Stop GEEM.vbs

  apps/
    admin/
      backend/
        admin-server.ps1
        admin-config.psd1
        lib/
        routes/
        services/
      frontend/
        index.html
        assets/
        scripts/

  data/
    users.json
    employeeNames.json
    projects.json
    history.json
    sessions.json
    sync-state.json
    overtimeCodes.json
    paymentOptions.json
    reasonCodes.json
    *_data.json
    .locks/

  scripts/
    launch-app.ps1
    start-all.ps1
    stop-all.ps1
    status-all.ps1
    restart-all.ps1
    seed-demo-entries.ps1
    seed-presentation-data.ps1
    test-powershell51-compat.ps1
    lib/

  runtime/
    logs/
    pids/
```

## 15. Validation et compatibilité

Le projet doit rester compatible avec Windows PowerShell 5.1. Cela veut dire qu’il faut éviter certaines syntaxes modernes de PowerShell 7, par exemple :

- l’opérateur ternaire `? :`;
- `??` et `??=`;
- certaines commandes ou paramètres qui existent seulement dans PowerShell 7.

Un script de vérification existe :

```powershell
./scripts/test-powershell51-compat.ps1 -FailOnIssues
```

Pour valider les fichiers JavaScript modifiés, on peut aussi utiliser Node si disponible :

```bash
node --check apps/admin/frontend/scripts/AppShell.js
node --check apps/admin/frontend/scripts/Views/SelfView.js
node --check apps/admin/frontend/scripts/Views/EmployeesView.js
node --check apps/admin/frontend/scripts/Views/DashboardView.js
node --check apps/admin/frontend/scripts/Views/ProjectsView.js
```

Ce n’est pas une suite de tests complète, mais ça aide à attraper les erreurs de syntaxe avant une démonstration ou une livraison.

## 16. Erreurs fréquentes et points importants

### Le port 8081 est déjà utilisé

Si l’application refuse de démarrer parce que le port est déjà occupé, il faut vérifier le statut :

```powershell
./scripts/status-all.ps1
```

Puis arrêter proprement :

```powershell
./scripts/stop-all.ps1
```

Sur certains postes Windows, un port peut apparaître utilisé par `PID 4`. Dans ce cas, il s’agit souvent d’un service système ou d’une réservation HTTP Windows. Il peut être nécessaire de changer `ListenerPrefix` ou de demander l’aide de l’équipe TI.

### `powershell.exe` introuvable sur macOS

Sur macOS, il faut utiliser :

```bash
pwsh ./scripts/launch-app.ps1
```

et non `powershell.exe`.

### `Authentication required`

Cette erreur arrive quand la session n’est plus valide ou quand le frontend appelle une route protégée sans jeton. La solution normale est de se déconnecter, se reconnecter, puis recharger la page.

### L’application est lente sur un lecteur réseau

Les causes possibles sont :

- lecture JSON sur un partage lent;
- antivirus qui inspecte chaque fichier;
- réseau chargé;
- dossier `data/` très volumineux;
- plusieurs postes qui écrivent en même temps;
- poste client peu performant.

Les caches et routes `bootstrap` réduisent le problème, mais ils ne peuvent pas rendre un lecteur réseau aussi rapide qu’un disque local.

### Modification manuelle des fichiers JSON

Il faut éviter de modifier les fichiers JSON manuellement pendant que l’application roule. Une erreur de virgule ou de format peut empêcher le backend de lire les données.

Si une modification manuelle est nécessaire, il vaut mieux :

- arrêter l’application;
- faire une copie du fichier;
- modifier avec prudence;
- redémarrer;
- vérifier que la page charge correctement.

## 17. Limites actuelles

Les limites principales sont :

- les données sont dans des fichiers JSON, pas dans une vraie base de données;
- il n’y a pas de chiffrement des fichiers de données;
- l’application utilise HTTP local par défaut, pas HTTPS;
- la performance dépend beaucoup du poste et du lecteur réseau;
- les verrous de fichiers réduisent les conflits, mais ne remplacent pas des transactions de base de données;
- il n’y a pas encore d’intégration Active Directory ou SSO;
- le rapport mensuel est en HTML, pas encore un PDF officiel rempli automatiquement;
- les sauvegardes doivent être gérées séparément;
- il n’y a pas encore une suite complète de tests automatisés.

Ces limites ne bloquent pas l’utilisation interne, mais elles sont importantes à connaître avant de déployer plus largement.

## 18. Améliorations possibles

Pour une prochaine version, les améliorations les plus réalistes seraient :

- héberger un seul backend partagé au lieu de faire tourner le serveur sur plusieurs postes;
- ajouter HTTPS si l’application est consultée sur le réseau;
- remplacer les fichiers JSON par SQLite, SQL Server ou une autre base de données légère;
- ajouter une vraie génération PDF pour les formulaires officiels;
- ajouter une exportation CSV ou Excel;
- ajouter une stratégie automatique de sauvegarde du dossier `data/`;
- créer un installateur ou un service Windows;
- ajouter une intégration Active Directory;
- ajouter plus de tests automatisés pour les routes backend;
- ajouter un écran d’administration pour vérifier l’état du système, les fichiers de données et les permissions.

## 19. Conclusion

L’application permet de remplacer une partie importante du suivi manuel par courriel par un outil centralisé. Elle donne aux employés un moyen plus simple de déclarer leurs heures, et aux superviseurs une meilleure vue sur les approbations, les projets, les employés et les tendances.

Le projet reste volontairement simple dans ses technologies : PowerShell, JavaScript, fichiers JSON et navigateur. Ce choix correspond aux contraintes de l’environnement, mais il vient aussi avec des limites claires, surtout pour la sécurité des fichiers et la performance sur lecteur réseau.

Dans son état actuel, le programme est utilisable comme outil interne pour structurer les entrées de temps, accélérer la révision et préparer plus facilement les informations mensuelles. Pour un déploiement plus large ou plus critique, la prochaine étape logique serait de centraliser l’hébergement et d’utiliser un stockage plus robuste qu’un ensemble de fichiers JSON.
