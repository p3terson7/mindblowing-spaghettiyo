# Documentation du projet

## 1. Présentation générale

Ce projet est une application interne de gestion des heures supplémentaires pour GÉEM. L’objectif est de permettre aux employés de déclarer leurs heures supplémentaires plus facilement, pendant que les superviseurs peuvent consulter, corriger, approuver ou rejeter les entrées à partir d’une interface centralisée.

Le projet a été développé avec une contrainte importante : rester utilisable dans un environnement Windows assez restreint, sans base de données externe et sans installation lourde. Pour cette raison, l’application repose surtout sur PowerShell, JavaScript, HTML/CSS et des fichiers JSON stockés dans un dossier de données.

L’application fonctionne maintenant comme une application unifiée : il n’y a plus deux vrais projets séparés pour l’employé et l’administrateur. Les deux rôles passent par le même backend et le même écran de connexion. L’interface affichée dépend ensuite du rôle de l’utilisateur connecté.

## 2. Problème à résoudre

Avant l’application, le suivi des heures supplémentaires se faisait surtout par courriel. Lorsqu’un employé commençait une période de temps supplémentaire, il devait envoyer manuellement un courriel d’entrée au superviseur. Lorsqu’il terminait, il devait ensuite envoyer un deuxième courriel de sortie. Avec une trentaine d'employés, cette méthode devient lourde à gérer.

Avec cette méthode, plusieurs problèmes pouvaient arriver :

- des courriels difficiles à retrouver à la fin du mois;
- des corrections difficiles à retracer;
- des informations réparties entre Outlook, les formulaires et les notes du superviseur;
- aucune façon simple de filtrer ou d’analyser les heures par projet;
- une perte de temps pour retrouver les heures d’un employé, d’un projet ou d’un mois précis.

Le programme cherche donc à remplacer ce suivi par courriel par un outil centralisé. L’idée n’est pas de changer complètement la façon de travailler, mais de regrouper les informations au même endroit, de réduire la recherche manuelle dans Outlook et de donner au superviseur une meilleure vue d’ensemble.

## 3. Objectifs du projet

Les objectifs principaux du projet sont les suivants :

- permettre aux employés de démarrer et terminer une entrée d’heures supplémentaires;
- forcer la sélection d’un projet, d’un code d’heures supplémentaires, d’un type de paiement et d’une raison lorsque nécessaire;
- donner aux superviseurs une vue claire des entrées à approuver;
- permettre la correction, la suppression, l’approbation et le rejet des entrées avec une note de gestionnaire lorsque c’est nécessaire;
- garder un historique des actions importantes;
- gérer les employés, les projets et les mots de passe dans l’interface;
- offrir des statistiques utiles par employé et par projet;
- produire un rapport HTML mensuel des entrées, utile pour remplir les formulaires d’heures supplémentaires;
- rester compatible avec Windows PowerShell 5.1;

## 4. Fonctionnalités principales

### Connexion et rôles

L’application utilise un système de connexion interne. Les utilisateurs sont définis dans `data/users.json`.

Deux rôles existent :

- `admin` : accès aux vues de supervision, approbations, employés, projets et historiques;
- `employee` : accès seulement à l’espace employé.

Le backend vérifie les rôles dans les routes protégées. Le frontend cache aussi certaines sections selon le rôle, mais la vraie protection reste côté backend.

### Espace employé

Un employé peut :

- se connecter avec son code employé;
- démarrer une période d’heures supplémentaires;
- choisir un projet avant de démarrer;
- choisir un code d’heures supplémentaires;
- choisir le type de paiement, par exemple `cash` ou `leave`;
- choisir une raison, par exemple `A`, `B`, `C`, etc.;
- terminer une entrée en cours;
- voir ses entrées dans une vue calendrier;
- consulter ses statistiques personnelles;
- exporter les entrées d’un mois dans un autre onglet HTML.

Les entrées rejetées ne sont pas incluses dans l’export mensuel.

### Espace administrateur

Un administrateur peut :

- voir le tableau de bord principal dans `dashboardView`;
- consulter les approbations en attente;
- voir les sessions actives;
- consulter les détails d’un employé dans un tableau;
- ajouter, modifier ou supprimer une entrée;
- approuver ou rejeter une entrée;
- approuver plusieurs entrées filtrées en lot;
- ajouter une note de gestionnaire;
- modifier la note depuis une fenêtre modale;
- consulter l’historique des actions;
- filtrer les employés par statut ou par projet;
- accéder aux entrées d’un employé à partir d’un projet;
- gérer les employés;
- archiver ou réactiver un employé;
- réinitialiser ou définir les mots de passe des employés;
- gérer les projets;
- consulter les statistiques par projet.

### Gestion des projets

Les projets sont stockés dans `data/projects.json`. Chaque projet contient au minimum :

- `projectCode`;
- `projectName`.

L’interface permet d’ajouter, modifier ou retirer des projets. Les statistiques de projet sont visibles dans la vue `projectsView`, avec une répartition par employé.

### Codes et options

Les listes utilisées pour les entrées sont stockées dans des fichiers JSON séparés :

- `data/overtimeCodes.json` pour les codes d’heures supplémentaires;
- `data/paymentOptions.json` pour le paiement;
- `data/reasonCodes.json` pour les raisons;
- `data/projects.json` pour les projets.

Ces fichiers contiennent des libellés anglais et français lorsque c’est nécessaire.

### Historique des actions

Le fichier `data/history.json` garde les actions importantes, par exemple :

- ajout d’une entrée;
- modification d’une entrée;
- suppression d’une entrée;
- approbation ou rejet;
- création ou modification d’un employé;
- modification de projets;
- réinitialisation de mot de passe.

L’historique est affiché dans l’interface et peut être filtré.

### Vue calendrier

Les employés et les administrateurs ont accès à une vue calendrier. Elle permet de voir les entrées par mois, avec un tableau de navigation par mois et par année. Les entrées en cours peuvent aussi être affichées.

### Export mensuel HTML

La fonction `openMonthlyEntriesExportHtml` dans `apps/admin/frontend/scripts/Utilities.js` génère un rapport HTML dans un nouvel onglet. Le tableau contient :

- Jour;
- Raison;
- Heure de début;
- Heure de fin;
- Code d’heures supplémentaires;
- Paiement;
- Temps total.

Ce n’est pas un export PDF directement. L’idée est plutôt de produire une page propre qui peut servir de référence pour remplir un formulaire officiel.

### Détection d’oubli de punch-out

Le backend contient une logique pour éviter qu’un employé termine par erreur une entrée de la veille avec l’heure du jour courant. Les fonctions importantes sont dans `apps/admin/backend/services/EntryService.ps1` :

- `Test-EntryForgottenClockOut`;
- `Set-EntryForgottenClockOutReview`;
- `Clear-EntryForgottenClockOutReview`.

Si une entrée active date d’une journée précédente, elle est marquée comme nécessitant une révision. Le superviseur peut ensuite corriger l’heure de fin dans l’interface.

## 5. Fonctionnement général

Voici un scénario normal d’utilisation.

1. L’utilisateur lance l’application avec `Launch GEEM.bat`, `Launch GEEM.vbs`, `Launch GEEM.command` ou un script PowerShell.
2. Le script démarre le backend PowerShell si nécessaire.
3. Le navigateur ouvre l’adresse de l’application, par défaut `http://localhost:8081/`.
4. L’utilisateur se connecte.
5. Si l’utilisateur est un employé, il voit l’espace employé.
6. Si l’utilisateur est un administrateur, il voit les vues de supervision.
7. Lorsqu’une entrée est créée ou modifiée, le backend écrit les changements dans les fichiers JSON du dossier `data/`.
8. Le backend met aussi à jour `data/sync-state.json`.
9. Les autres écrans ouverts détectent le changement et rafraîchissent les données nécessaires.

## 6. Architecture technique

### Vue d’ensemble

L’application est séparée en deux grandes parties :

- backend PowerShell;
- frontend HTML, CSS et JavaScript.

Le backend principal est :

```text
apps/admin/backend/admin-server.ps1
```

Le frontend principal est :

```text
apps/admin/frontend/index.html
```

Les anciens fichiers sous `apps/employee/` existent encore, mais ils servent surtout à rediriger ou à garder une compatibilité avec l’ancienne structure.

### Backend PowerShell

Le backend utilise `System.Net.HttpListener`. Il écoute par défaut sur :

```text
http://localhost:8081/
```

Le fichier `admin-server.ps1` charge les fichiers suivants :

- `lib/AdminContext.ps1`;
- `lib/CommonHelpers.ps1`;
- `lib/FileStore.ps1`;
- `lib/ResponseHelpers.ps1`;
- les services dans `services/`;
- les routes dans `routes/`.

Les routes sont séparées en plusieurs fichiers pour éviter un seul gros script difficile à maintenir.

### Services backend

Les services principaux sont :

- `AuthService.ps1` : gestion des utilisateurs, mots de passe, sessions et rôles;
- `EntryService.ps1` : normalisation des heures, calculs, identifiants d’entrées et oubli de punch-out;
- `ReadModelService.ps1` : préparation des données pour les vues, statistiques et caches de lecture;
- `EmployeeDirectoryService.ps1` : gestion des employés et des fichiers associés;
- `SyncService.ps1` : gestion de `sync-state.json` pour les rafraîchissements;
- `ProjectStatsService.ps1` : calculs liés aux projets;
- `HistoryService.ps1` : écriture de l’historique.

### Routes backend

Quelques routes importantes :

- `POST /auth/login` : connexion;
- `GET /auth/me` : validation de session;
- `POST /auth/logout` : déconnexion;
- `POST /auth/change-password` : changement de mot de passe;
- `GET /self/bootstrap` : données initiales de l’espace employé;
- `POST /self/punch` : punch-in ou punch-out;
- `GET /dashboard/bootstrap` : données principales du tableau de bord admin;
- `GET /employees` : liste des employés;
- `POST /employees` : ajout d’un employé;
- `PUT /employees/{code}` : modification d’un employé;
- `DELETE /employees/{code}` : archivage d’un employé;
- `POST /employees/{code}/restore` : réactivation d’un employé;
- `GET /employee/{code}` : entrées d’un employé;
- `POST /employee/add/{code}` : ajout d’une entrée par un admin;
- `PUT /employee/{code}` : modification d’une entrée;
- `DELETE /employee/{code}` : suppression d’une entrée;
- `POST /employee/approval/{code}` : approbation ou rejet d’une entrée;
- `POST /employee/approval/batch` : approbation en lot;
- `GET /projects` : liste des projets;
- `POST /projects` : ajout d’un projet;
- `PUT /projects/{projectCode}` : modification d’un projet;
- `DELETE /projects/{projectCode}` : retrait d’un projet;
- `GET /stats/projects` : résumé des statistiques de projets;
- `GET /stats/projects/trends` : tendances de projets;
- `GET /stats/projects/{projectCode}` : détail d’un projet;
- `GET /sync/status` : état de synchronisation.

### Frontend

Le frontend est construit avec des fichiers statiques :

- `index.html` pour la structure;
- `assets/styles.css` pour le style;
- `scripts/AppShell.js` pour la session, le thème, la langue et le rafraîchissement;
- `scripts/I18n.js` pour les traductions anglais/français;
- `scripts/Utilities.js` pour les fonctions communes;
- `scripts/Views/*.js` pour les différentes vues.

Les principales vues sont :

- `selfView` pour l’employé;
- `dashboardView` pour le tableau de bord admin;
- `employeesView` pour la gestion et l’analyse des employés;
- `adminView` pour les approbations et l’historique;
- `projectsView` pour les projets et statistiques.

### Stockage des données

Le programme ne dépend pas d’une base de données comme SQL Server. Les données sont stockées dans des fichiers JSON dans `data/`.

Chaque employé a son propre fichier d’entrées, par exemple :

```text
data/000379070_data.json
```

Cette approche est simple et adaptée aux contraintes du projet, mais elle demande une bonne gestion des permissions du dossier partagé.

### Concurrence et intégrité des données

Pour éviter que deux utilisateurs écrivent dans le même fichier en même temps, le backend utilise des verrous dans `data/.locks`. Les fonctions principales sont dans `FileStore.ps1` :

- `Acquire-ResourceLock`;
- `Release-ResourceLock`;
- `Write-JsonAtomic`.

Les écritures JSON sont faites de manière atomique : le fichier est écrit dans un fichier temporaire, puis remplacé. Cela réduit les risques de fichier partiellement écrit.

## 7. Technologies utilisées

### PowerShell

PowerShell est utilisé pour le backend, les scripts de lancement et la gestion des fichiers. Le projet reste compatible avec Windows PowerShell 5.1, ce qui est important pour les postes Windows plus anciens ou verrouillés.

### JavaScript

JavaScript est utilisé côté navigateur pour gérer l’interface, les appels au backend, les filtres, les calendriers, les statistiques et les exports HTML.

### HTML et CSS

L’interface est une application web statique servie par le backend. Le fichier principal est `apps/admin/frontend/index.html`.

Le style est principalement dans :

```text
apps/admin/frontend/assets/styles.css
```

L’interface contient aussi un thème clair et un thème sombre.

### Bootstrap

Bootstrap est utilisé pour certains composants d’interface, notamment les modales, les onglets et certains comportements de base.

Les fichiers sont inclus localement dans :

```text
apps/admin/frontend/assets/vendor/bootstrap/
```

### Font Awesome

Font Awesome est utilisé pour les icônes de l’interface.

### Chart.js

Chart.js est utilisé pour les graphiques dans la section projets. La bibliothèque est servie localement avec le projet, ce qui évite de dépendre d’un CDN bloqué par le réseau de travail.

### JSON

Les fichiers JSON servent de stockage principal. C’est lisible et simple à modifier pour la configuration, mais ce n’est pas une base de données complète.

## 8. Installation et configuration

### Prérequis

Sur Windows :

- Windows PowerShell 5.1 ou PowerShell 7 (`pwsh`);
- un navigateur moderne;
- accès au dossier du projet;
- si les données sont sur un disque réseau, accès au chemin configuré.

Sur macOS :

- PowerShell 7 (`pwsh`);
- un navigateur moderne.

### Lancement simple

Sur Windows, le plus simple est d’utiliser :

```text
Launch GEEM.bat
```

ou :

```text
Launch GEEM.vbs
```

Le fichier `.vbs` lance l’application plus discrètement, sans garder une fenêtre de terminal visible.

Sur macOS :

```text
Launch GEEM.command
```

### Lancement par commande

Sur Windows :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\launch-app.ps1
```

Sur macOS ou PowerShell 7 :

```powershell
pwsh ./scripts/launch-app.ps1
```

Pour démarrer seulement le backend en arrière-plan :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-all.ps1
```

ou :

```powershell
pwsh ./scripts/start-all.ps1
```

### Arrêt de l’application

Sur Windows :

```text
Stop GEEM.bat
```

ou :

```text
Stop GEEM.vbs
```

Par commande :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1
```

Sur macOS :

```powershell
pwsh ./scripts/stop-all.ps1
```

### Vérifier l’état

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\status-all.ps1
```

ou :

```powershell
pwsh ./scripts/status-all.ps1
```

### Configuration principale

Le fichier principal de configuration est :

```text
apps/admin/backend/admin-config.psd1
```

Il contient actuellement :

```powershell
@{
    ListenerPrefix = "http://localhost:8081/"
    DataFolderPath = "../../../data"
}
```

`ListenerPrefix` définit l’adresse du serveur local.

`DataFolderPath` définit où les fichiers JSON sont stockés. Pour un dossier réseau, on pourrait utiliser un chemin partagé, par exemple :

```powershell
DataFolderPath = "\\serveur\partage\OvertimeData"
```

Le code supporte aussi `BootstrapAdminUsername` et `BootstrapAdminPassword` si on veut changer le compte admin créé automatiquement quand `users.json` n’existe pas encore.

### Comptes par défaut

Si `data/users.json` n’existe pas encore, le backend crée des comptes de base.

Compte administrateur par défaut :

- utilisateur : `admin`;
- mot de passe : `ChangeMe123!`.

Pour les employés créés au départ, le nom d’utilisateur est habituellement le code employé. Le mot de passe initial dépend de la création du compte ou du reset effectué par l’administrateur. Dans les données de départ, plusieurs comptes employés peuvent être forcés à changer leur mot de passe avec `mustChangePassword`.

Il est fortement recommandé de changer le mot de passe admin avant une utilisation réelle.

## 9. Guide d’utilisation

### Pour un employé

1. Ouvrir l’application.
2. Se connecter avec son code employé et son mot de passe.
3. Choisir le projet.
4. Choisir le code d’heures supplémentaires.
5. Choisir le type de paiement.
6. Choisir une raison si nécessaire.
7. Cliquer sur le bouton pour démarrer les heures supplémentaires.
8. À la fin, cliquer sur le bouton pour terminer l’entrée.
9. Consulter le calendrier ou les statistiques si besoin.
10. Exporter un mois en HTML si l’information doit être reportée dans un formulaire.

### Pour un administrateur

1. Ouvrir l’application.
2. Se connecter avec un compte administrateur.
3. Utiliser le tableau de bord pour voir les entrées en attente, les sessions actives et les détails employés.
4. Aller dans `Review` pour traiter les approbations et consulter l’historique.
5. Aller dans `People` pour gérer les employés, consulter leurs calendriers et leurs statistiques.
6. Aller dans `Projects` pour gérer les projets et analyser la répartition des heures.
7. Ajouter une note de gestionnaire lorsque l’entrée est rejetée, modifiée ou supprimée.
8. Utiliser les filtres pour cibler une période, un employé ou un projet.

## 10. Structure des fichiers

Voici les fichiers et dossiers les plus importants.

```text
apps/admin/backend/admin-server.ps1
```

Point d’entrée du backend. Il démarre le serveur HTTP et charge les routes.

```text
apps/admin/backend/admin-config.psd1
```

Configuration du port et du dossier de données.

```text
apps/admin/backend/lib/
```

Fonctions de base du backend : contexte, réponses HTTP, fichiers, verrous et écritures atomiques.

```text
apps/admin/backend/services/
```

Logique principale du programme : authentification, entrées, employés, statistiques, synchronisation et historique.

```text
apps/admin/backend/routes/
```

Endpoints HTTP utilisés par le frontend.

```text
apps/admin/frontend/index.html
```

Page principale de l’application.

```text
apps/admin/frontend/scripts/AppShell.js
```

Gestion de la session, du rôle, de la langue, du thème et du rafraîchissement des vues.

```text
apps/admin/frontend/scripts/I18n.js
```

Traductions français/anglais.

```text
apps/admin/frontend/scripts/Utilities.js
```

Fonctions communes : formats de dates, durées, filtres, export HTML, messages, rendu d’historique.

```text
apps/admin/frontend/scripts/Views/
```

Code JavaScript séparé par vue : employé, dashboard, personnes, projets, historique et approbations.

```text
data/
```

Dossier contenant les fichiers JSON de données.

```text
runtime/
```

Dossier créé/utilisé au lancement pour les fichiers PID et les logs.

```text
scripts/
```

Scripts de lancement, arrêt, statut, redémarrage et réinitialisation des données d’exemple.

## 11. Gestion des erreurs et points importants

### Port déjà utilisé

Si l’application refuse de démarrer parce que le port `8081` est déjà utilisé, il faut arrêter l’ancien processus :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\stop-all.ps1
```

ou :

```powershell
pwsh ./scripts/stop-all.ps1
```

Le script `status-all.ps1` aide aussi à vérifier l’état du backend.

### Fermer le navigateur ne ferme pas forcément le serveur

Si l’utilisateur ferme seulement l’onglet du navigateur, le backend peut continuer à tourner. C’est normal. Les fichiers `Launch GEEM.*` essaient de réutiliser le serveur existant si l’application est déjà disponible.

Pour arrêter complètement l’application, il faut utiliser `Stop GEEM.*` ou `scripts/stop-all.ps1`.

### Dossier réseau lent

Si `DataFolderPath` pointe vers un disque réseau, certaines opérations peuvent être plus lentes. Le projet contient déjà des caches de lecture et limite plusieurs requêtes inutiles, mais les fichiers JSON sur réseau restent moins rapides qu’un disque local ou une vraie base de données.

### Permissions du dossier de données

Les fichiers JSON contiennent les données du programme. Même si les mots de passe sont hashés, les entrées d’heures, projets et historiques sont lisibles en clair.

Il faut éviter que tous les utilisateurs aient un accès direct en modification au dossier `data/`. Idéalement :

- le backend a les droits de modification;
- les utilisateurs passent par l’application;
- les employés n’éditent pas les JSON manuellement;
- les permissions du partage réseau et les permissions NTFS sont configurées correctement.

### Mot de passe oublié

Un administrateur peut réinitialiser le mot de passe d’un employé dans la section `People`. Les utilisateurs peuvent aussi changer leur propre mot de passe depuis l’interface.

### Oubli de punch-out

Si un employé oublie de terminer une entrée et essaie de la fermer le lendemain, le système ne met pas automatiquement l’heure du lendemain comme punch-out. L’entrée est plutôt marquée comme nécessitant une correction par un superviseur.

### Données d’exemple

Le script suivant réinitialise les données d’exemple :

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\reset-sample-data.ps1
```

ou :

```powershell
pwsh ./scripts/reset-sample-data.ps1
```

Il faut faire attention avec ce script, car il remplace les données existantes par des données d’exemple.

## 12. Limites actuelles

Le projet fonctionne, mais il a encore certaines limites importantes.

- Le stockage est basé sur des fichiers JSON, pas sur une vraie base de données.
- Les fichiers de données métier ne sont pas chiffrés.
- Le serveur utilise HTTP par défaut, pas HTTPS.
- Le rafraîchissement en temps réel se fait par vérification de `sync-state.json`, pas par WebSocket.
- Les performances peuvent diminuer si le dossier de données est sur un réseau lent.
- Le projet n’est pas installé comme un service Windows officiel.
- L’export mensuel est un fichier HTML ouvert dans un nouvel onglet, pas un remplissage automatique de formulaire PDF.
- Les permissions du dossier de données doivent être configurées correctement à l’extérieur de l’application.
- L’application est conçue pour un groupe limité d’utilisateurs, pas pour une très grande organisation avec des milliers d’entrées par jour.

## 13. Améliorations possibles

Voici des améliorations réalistes pour une version future.

- Ajouter une option d’export PDF officielle, surtout si le formulaire d’heures supplémentaires doit être rempli automatiquement.
- Installer le backend comme un vrai service Windows pour éviter de dépendre d’un lancement manuel.
- Ajouter HTTPS pour une utilisation réseau plus sécuritaire.
- Remplacer éventuellement les fichiers JSON par une petite base de données si le volume augmente.
- Ajouter une page de configuration administrateur pour modifier certains paramètres sans toucher aux fichiers.
- Ajouter une meilleure gestion des sauvegardes automatiques du dossier `data/`.
- Ajouter un système de journalisation plus détaillé pour diagnostiquer les erreurs en production.
- Ajouter des tests automatisés pour les routes principales du backend.
- Ajouter une validation plus stricte des permissions réseau au démarrage.
- Ajouter une option d’archivage des anciennes années pour garder les fichiers plus légers.

## 14. Conclusion

Ce projet permet de centraliser la gestion des heures supplémentaires dans un outil interne adapté aux contraintes actuelles. Il permet aux employés de saisir leurs heures plus proprement et donne aux superviseurs une vue plus claire pour approuver, corriger et suivre les entrées.

La solution reste volontairement simple sur le plan technique : PowerShell, JavaScript, fichiers JSON et interface web locale. Cette simplicité facilite le déploiement dans un environnement restreint, mais elle vient aussi avec certaines limites, surtout pour la sécurité avancée, la performance sur disque réseau et la gestion à grande échelle.

Dans son état actuel, le projet est utilisable comme outil interne pour un nombre raisonnable d’employés, tout en laissant une base assez claire pour des améliorations futures.
