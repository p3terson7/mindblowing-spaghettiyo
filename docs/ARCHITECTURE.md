# Architecture de SAPHIR

Ce document décrit les frontières que le code doit respecter pendant la
modernisation progressive de SAPHIR. Le but n'est pas de réécrire
l'application d'un seul coup, mais de pouvoir isoler une responsabilité à la
fois sans changer les parcours, les réponses HTTP ou le format de DATA.

## Principes de migration

1. Caractériser le comportement actuel avant de déplacer du code.
2. Extraire d'abord les calculs purs et les décisions sans accès au disque.
3. Conserver une façade compatible tant que des appels historiques existent.
4. Migrer les consommateurs par petits groupes.
5. Retirer une façade seulement lorsqu'aucun appel historique ne subsiste.
6. Exécuter toute la suite de tests après chaque extraction.

Une phase de nettoyage ne doit jamais modifier simultanément une frontière,
une règle métier et le format persistant. Ces changements demandent des lots et
des validations distincts.

## Topologie canonique

Le dépôt contient une seule application, indépendamment du rôle connecté :

```text
app/
  backend/
    saphir-server.ps1
    saphir-config.psd1
    lib/AppContext.ps1
  frontend/
    index.html
deploy/bootstrap/
scripts/
data/
```

`app/backend` et `app/frontend` sont les seules sources d’exécution de
l’application. Les permissions d’employé, d’admin et de super admin restent des
règles applicatives; elles ne justifient pas des copies distinctes du serveur ou
du frontend. L’ancien arbre d’application employé a donc été retiré.

Les fichiers sous `deploy/bootstrap/` sont les sources versionnées des lanceurs
Windows. `scripts/package-app.ps1` les publie à la racine de
`SAPHIR-Distribution` pour conserver le parcours et les raccourcis existants;
ils ne constituent pas un second arbre d’application.

## Backend actuel

`app/backend/saphir-server.ps1` est le point de composition du serveur.
Il charge le contexte, les adaptateurs historiques et les services, précharge
le catalogue des routes, puis traite les requêtes avec `HttpListener`.

Les scripts sous `routes/` sont encore des gestionnaires historiques. Ils
utilisent la portée dynamique de la boucle HTTP pour accéder à `$request`,
`$response` et `$currentUser`, et utilisent `continue` pour terminer une
requête. Ils ne sont donc pas des modules et ne doivent pas être chargés ou
appelés directement depuis un nouveau service.

Le premier module isolé est `Saphir.Routing`. Il ne contient que les décisions
de routage et le catalogue ordonné des scripts. Le serveur reste responsable de
l'exécution du script choisi. Cette séparation garde le contrôle de flux
historique intact tout en rendant la décision testable sans serveur ni DATA.

`Saphir.EntryIdentity` est la deuxième frontière pure. Elle décide comment une
entrée est identifiée dans un fichier contenant zéro, une ou plusieurs entrées :
identifiant stable, repli legacy date/heure et refus des identifiants ambigus.
`EntryService.ps1` conserve les six noms historiques comme façades minces afin
que les routes actuelles n'aient pas à changer. Le module ne lit ni DATA, ni
l'horloge, ni le contexte HTTP; il transforme seulement les valeurs reçues.

`Saphir.ProjectCatalog` regroupe les décisions pures d'un catalogue projet :
palette, couleur de repli, codes d'administrateurs, anciens noms de propriétés,
archivage, normalisation et portée `active / archived / all`. Les onze noms
historiques de `CommonHelpers.ps1` restent des façades. Les lectures de
`projects.json`, le cache, les verrous et les mutations restent volontairement
hors du module. Le rapport analytique utilise la même primitive de couleur,
tout en conservant explicitement sa convention legacy sur les espaces dans un
code projet.

`Saphir.EntryState` centralise trois décisions booléennes sans effet de bord :
normaliser un ancien drapeau, reconnaître un oubli de punch-out et déterminer
si une entrée est encore ouverte. Les noms historiques de `EntryService`,
`ReadModelService` et du rapport analytique restent des façades. Les changements
de statut, les horodatages, les écritures et les autorisations demeurent hors du
module.

`Saphir.EntryDuration` isole le calcul pur du crédit d’heures. Il reçoit une
date et les deux heures exactes, puis compte une tranche fixe de 15 minutes
seulement lorsqu’elle contient au moins 10 minutes réellement travaillées. Les
routes conservent leurs heures arrondies historiques pour l’affichage, mais
stockent la durée créditée renvoyée par ce module. Les GC179 importées restent
hors de ce recalcul : leur durée déclarée est la source officielle.

`Saphir.Gc179Profile` isole la normalisation du profil utilisé pour produire une
GC179 : nom, initiales, indicateurs, PRI et les trois codes d'en-tête Groupe,
Sous-groupe et Niveau. Les douze fonctions publiques de `AuthService.ps1`
restent des façades, dont les anciens noms Poste et Échelon, afin que les
consommateurs actuels et les anciens profils gardent exactement leurs valeurs de
repli. Le module reçoit un objet utilisateur déjà lu; il ne consulte ni les
utilisateurs, ni les sessions, ni DATA et ne persiste aucune modification.

`Saphir.UserAccessProfile` centralise trois règles de compatibilité des comptes :
le nom canonique d'un rôle, la liste normalisée des types d'entrées et les
anciens drapeaux permettant les entrées Divers. `AuthService.ps1` conserve les
trois noms historiques comme façades, de sorte que l'autorisation et les routes
ne changent pas. Le module reçoit uniquement des valeurs ou un objet utilisateur
déjà chargé; il ne lit ni utilisateurs, ni sessions, ni projets et ne décide pas
si une requête est autorisée.

### Règles pour les nouveaux modules PowerShell

- Fournir un manifeste `.psd1` et un `RootModule` explicite.
- Rester compatible avec Windows PowerShell 5.1.
- Énumérer `FunctionsToExport`; les jokers et les exports implicites sont
  interdits.
- Laisser `CmdletsToExport`, `VariablesToExport` et `AliasesToExport` vides,
  sauf décision d'architecture documentée et testée.
- Recevoir toutes les données nécessaires par paramètre. Un module ne doit pas
  chercher `$request`, `$response`, `$currentUser`, `$sharedFolder` ou
  `$scriptDir` dans la portée de son appelant.
- Ne pas utiliser `Get-Variable -Scope` pour contourner une dépendance
  explicite.
- Ne pas lire, créer ou modifier DATA pendant l'import du module.
- Pouvoir être importé plusieurs fois sans multiplier les commandes, les
  abonnements ou les effets de bord.
- Garder `Set-StrictMode`, s'il est utilisé, dans la portée du module. Il ne doit
  pas être activé globalement par une façade dot-sourcée.
- Utiliser un appel qualifié par le module lorsqu'une façade temporaire porte
  encore le même nom qu'une fonction extraite.

### Code historique dot-sourcé

Le dot-sourcing demeure une couche de compatibilité, pas le modèle cible.

- Seul le point de composition doit décider de l'ordre de chargement.
- Une façade historique peut déléguer vers un module, mais ne doit pas dupliquer
  sa logique.
- Aucun nouveau service ne doit dépendre d'une variable appartenant à une
  route.
- Les routes ne doivent pas appeler des fonctions privées d'une autre vue ou
  d'une autre route pour partager du comportement.
- La conversion des routes en fonctions attendra qu'un objet de requête et un
  résultat de route explicites puissent remplacer les `continue` dynamiques.

`AppContext.ps1` possède encore des responsabilités multiples : lecture de la
configuration, résolution des chemins et initialisation du stockage. Cette dette
est connue. Elle devra être séparée seulement après l'ajout de contrats de
démarrage couvrant les chemins locaux, absolus et UNC ainsi que les fichiers
absents, vides et invalides.

## Compatibilité des releases historiques

La topologie historique `apps/admin` n’est pas une structure de développement à
réutiliser. Elle est reconnue uniquement par
`scripts/lib/ApplicationLayout.ps1` afin que le lanceur mis à jour puisse encore
démarrer une ancienne release déjà présente dans
`%LOCALAPPDATA%\SAPHIR\versions` lors d’un retour arrière.

Le résolveur cherche d’abord la topologie canonique, puis la topologie
historique. Une nouvelle release doit toujours être produite depuis `app/` et
contenir `app/backend/saphir-server.ps1`,
`app/backend/saphir-config.psd1` et `app/frontend/index.html`.

La transition en production se fait en deux étapes séparées : publier le
bootstrap avec `-BootstrapOnly` et faire réinstaller le raccourci, puis publier
la première release canonique. Cela met le code de résolution compatible sur
les postes avant que `current.json` désigne une archive utilisant la nouvelle
topologie.

## Frontend actuel

Le frontend fonctionne sans bundler et doit rester utilisable hors ligne. Les
scripts de base sont chargés dans cet ordre :

1. `I18n.js`;
2. `Utilities.js`;
3. `AppShell.js`;
4. `Views/ViewSwitching.js`;
5. `Views/SelfView.js`.

Les scripts de gestion sont ensuite chargés à la demande par `AppShell.js`.
Le graphe de dépendances et l'ordre des scripts différés font partie du contrat
de l'application. Les tests doivent aussi permettre un nouvel essai lorsqu'un
asset échoue temporairement à se charger.

Les fichiers actuels utilisent encore des symboles globaux de scripts
classiques. Une conversion globale en modules ES serait trop risquée. Pendant
la transition, un helper déplacé dans le fichier historique `Utilities.js` peut
conserver son nom global afin de ne pas casser ses consommateurs. Cette
exception est une façade de compatibilité, pas le modèle à reproduire. Pour un
nouveau composant ou un nouveau fichier autonome :

- encapsuler l'implémentation dans une IIFE ou une frontière équivalente;
- publier uniquement une petite API intentionnelle sous `window.Saphir`;
- ne pas ajouter de nouvelle dépendance d'une vue vers l'état ou une fonction
  privée d'une autre vue;
- placer une action utilisée par plusieurs vues dans un composant partagé;
- injecter `fetch`, le stockage, l'horloge ou le DOM dans les fonctions pures
  testées au lieu de les lire implicitement;
- conserver une compatibilité temporaire `window.nomHistorique` seulement si un
  consommateur existant en a encore besoin;
- ne pas ajouter de dépendance externe ou réseau pour le fonctionnement de
  l'application.

La première API frontend suivant cette convention est
`window.Saphir.dateRanges`. Elle contient deux résolveurs déterministes : celui
de Mes heures conserve les dates calendrier locales, et celui des statistiques
Projets conserve pour l'instant la convention UTC historique. L'horloge est
passée explicitement aux résolveurs. Les fonctions historiques des vues restent
des façades qui fournissent leur état et `new Date()`; elles ne doivent pas
reprendre le calcul. Corriger une convention de fuseau ou valider une plage
inversée sera un changement fonctionnel séparé, jamais caché dans un refactor.

`window.Saphir.entryStats` est la frontière partagée suivante. Elle calcule le
statut effectif, le principal regroupement et les agrégats par projet utilisés
par Mes heures et Personnel. Les dépendances variables — durée, date, projet et
libellés traduits — lui sont passées par les façades des vues. Le composant ne
lit ni le DOM, ni le réseau, ni le stockage, ni l'horloge. Mes heures conserve
ses filtres et sa liste racine; Personnel conserve les listes d'entrées par
projet nécessaires à l'ouverture différée.

`window.Saphir.calendarMonths` construit le modèle des douze mois partagé par
Mes heures et Personnel. L'horloge, l'extraction de date, le tri, la conversion
des clés et les libellés sont injectés afin de préserver les conventions de
chaque vue. Les façades gardent leurs propriétés historiques (`key` dans Mes
heures, `monthKey` dans Personnel), leur sélection courante et leur ordre de
tri; le composant partagé ne lit ni état de vue, ni DOM, ni réseau.

`window.Saphir.calendarDays` construit les cellules dimanche-samedi du mois
actif, regroupe les entrées et calcule leurs totaux. Les vues injectent
l'extraction de date, le calcul de durée et l'ordre propre à une journée : Mes
heures conserve son tri date-heure, tandis que Personnel conserve l'ordre reçu.
Le composant retourne les mêmes objets d'entrée sans les modifier; le HTML, les
actions et les permissions demeurent entièrement dans les vues.

`window.Saphir.textSearch` fournit seulement deux opérations sur du texte déjà
préparé : découper des mots et vérifier qu'ils sont tous présents. Chaque façade
reste responsable de sa normalisation historique. Ainsi, Projets continue
d'ignorer les accents, tandis que Personnel, Vue d'ensemble et Historique
restent sensibles aux accents. Les classements, correspondances exactes,
filtres de dates et identités de tableaux restent également dans leurs vues.

La syntaxe de chaque fichier JavaScript d'application est validée avec Node.
Les tests de comportement restent nécessaires : une simple recherche de texte
ne prouve pas qu'un ordre de chargement ou un parcours DOM fonctionne.

## Frontière DATA et partage SMB

DATA est une API persistante. Un refactor de code ne donne pas l'autorisation de
la modifier.

- `data-schema.json` indique la compatibilité de lecture; toute nouvelle version
  demande une migration explicite et réversible.
- Les fichiers d'entrées doivent rester valides pour zéro, une ou plusieurs
  entrées. Un singleton historique doit continuer à être normalisé en mémoire.
- Les identifiants d'entrée stables ont priorité sur la recherche historique par
  date et heure.
- Toute mutation partagée passe par le verrou de ressource et l'écriture
  atomique de `FileStore`.
- Un cache est une optimisation locale et ne devient jamais la source de
  vérité.
- L'invalidation locale suit une écriture réussie. La publication de sync sert
  à informer les autres instances; son échec ne doit ni annuler une écriture
  déjà commise ni provoquer une répétition aveugle de la mutation.
- Une indisponibilité transitoire du partage doit produire une erreur stable et
  réessayable, sans traiter un fichier inaccessible comme un fichier absent.
- Les tests qui écrivent copient les fixtures vers un dossier temporaire. Ils
  ne pointent jamais vers le DATA de production.

Les tests locaux simulent la concurrence et plusieurs pannes, mais ne prouvent
pas le comportement d'un vrai serveur SMB. Une livraison exige toujours la CI
Windows PowerShell 5.1, une copie du DATA réel, deux postes contre le même partage
de test et un essai de coupure réseau.

## Niveaux de validation

### Phase 0 : caractérisation fonctionnelle

- contrats HTTP et codes de statut;
- diff strict des mutations DATA;
- fixtures zéro, une et plusieurs entrées;
- concurrence multiprocessus et récupération transitoire;
- compatibilité PowerShell 5.1;
- baseline de lectures, écritures et durées.

### Phase 1 : frontières d'architecture

- manifeste et exports exacts des modules;
- import répété sans effet de bord observable;
- absence de dépendances implicites dans les modules purs;
- catalogue des routes unique, complet et composé de fichiers existants;
- syntaxe valide de tous les scripts JavaScript d'application;
- conservation de l'ordre et du retry des assets différés.

### Phase 2 : logique de domaine pure

- parité entre le module pur et sa façade historique;
- matrices zéro, singleton et plusieurs entrées;
- priorité de l'identifiant stable et refus des collisions legacy;
- calculs de dates avec horloge injectée et sans DOM, réseau ou stockage;
- tests golden des conventions locale et UTC existantes;
- inclusion des modules et manifestes dans le paquet Windows.

### Phase 3 : domaine partagé sans duplication

- une seule implémentation des couleurs, archives et champs legacy des projets;
- conservation des façades de `CommonHelpers` et du chargement autonome du
  rapport analytique;
- une seule boucle d'agrégation pour les statistiques Self et Personnel;
- dépendances frontend injectées et absence d'effets de bord;
- parité golden des formes Self/Personnel, références d'entrées et égalités;
- inclusion du nouveau module dans le paquet Windows.

### Phase 4 : état partagé et modèles de calendrier

- une seule définition des drapeaux legacy et de l'état ouvert d'une entrée;
- conservation des façades EntryService, ReadModel et rapport analytique;
- matrices null, booléen, texte, espaces et casse pour les anciens drapeaux;
- une seule construction des douze mois pour Mes heures et Personnel;
- conservation exacte des formes, tris, références et sélections des vues;
- absence de DATA, I/O, horloge implicite, DOM ou réseau dans les composants;
- inclusion du nouveau module dans le paquet Windows.

### Phase 5 : profils normalisés et journées de calendrier

- une seule normalisation du profil GC179 et de ses anciens champs;
- conservation des douze façades de `AuthService` et de leurs valeurs de repli;
- matrices golden pour les noms, drapeaux, PRI, codes, groupe, sous-groupe et niveau;
- une seule construction des journées utilisée par Mes heures et Personnel;
- conservation du nombre de cellules, des totaux, des références et de l'ordre
  propre à chaque vue;
- absence de DATA, I/O, persistance d'authentification, DOM, réseau ou horloge
  implicite dans les nouveaux composants;
- inclusion du nouveau module dans le paquet Windows.

### Phase 6 : accès utilisateur et recherche textuelle

- une seule normalisation des rôles et des types d'entrées utilisateur;
- conservation des anciens drapeaux Divers et des trois façades `AuthService`;
- matrices null, scalaire, collections, doublons, casse et alias historiques;
- primitives de recherche limitées au texte déjà normalisé;
- conservation des différences d'accents, classements, filtres et références
  propres à chaque vue;
- absence de DATA, sessions, projets, autorisation HTTP, DOM, réseau, stockage
  ou horloge implicite dans les nouveaux composants;
- inclusion du nouveau module dans le paquet Windows.

Un changement de structure est accepté seulement si ces sept niveaux restent
verts, si les compteurs d'opérations partagées ne régressent pas et si le format
DATA ne change pas.

## Dettes explicitement reportées

Les travaux suivants ne font pas partie du premier lot de modularisation :

- convertir les scripts de routes en fonctions;
- découper en une fois `AuthService` ou `ReadModelService`;
- remplacer le stockage JSON ou modifier le protocole de sync;
- paralléliser la boucle `HttpListener`;
- convertir tout le frontend en modules ES;
- migrer simultanément tous les appels `fetch` ou toutes les actions d'entrée;
- nettoyer massivement les feuilles CSS.

Chacun de ces travaux aura son propre contrat de caractérisation et son propre
lot de retour arrière.
