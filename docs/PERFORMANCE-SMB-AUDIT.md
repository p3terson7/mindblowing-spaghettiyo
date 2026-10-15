# Audit performance — stockage SMB

Audit du 9 octobre 2026, sur la base du commit `8ca7a3a` et de traces
diagnostiques ajoutées pendant cet audit. Il s'agit de la phase d'analyse,
pas d'une refonte déjà terminée.

La suite de cet audit est maintenant implémentée et mesurée avant/après sur
SMB : voir [Caches par dépendances](DEPENDENCY-CACHE-IMPLEMENTATION.md).
Les descriptions « actuelles » ci-dessous désignent la baseline de l'audit,
avant cette implémentation.

## Résumé

Les fichiers JSON sont petits. Le problème mesuré est surtout la succession
des accès au partage : lectures, métadonnées et transactions d'écriture.
Le serveur traite une requête à la fois; ces délais bloquent aussi les autres
requêtes du même poste.

Le dashboard admin passe d'environ 4,5 secondes à froid à quelques millisecondes
à chaud. Les caches ne sont donc pas inutiles. Le travail consiste à éviter
les validations SMB redondantes et les reconstructions globales, sans perdre
les changements faits sur un autre poste.

Attention : `sync-state.json` ne peut pas devenir l'unique source
d'invalidation dès maintenant. La création/révocation de sessions ne publie
pas systématiquement de changement, et une publication peut échouer après
une écriture métier réussie. Retirer les contrôles de fichiers avant de régler
ce contrat serait risqué.

## Environnement et portée des mesures

- Application et PowerShell 7.4.6 exécutés localement sur macOS.
- Partage Windows déjà monté : `/Volumes/OvertimeTest/data`.
- URI fournie : `smb://192.168.2.17/OvertimeTest/data`.
- Équivalent Windows : `\\192.168.2.17\OvertimeTest\data`.
- Configuration locale : `app/backend/saphir-config.psd1`, démonstration désactivée.
- Instance locale redémarrée sur cette configuration; `GET /` retourne HTTP 200.
  Les empreintes des 45 fichiers JSON du dossier partagé sont identiques avant
  et après ce redémarrage et cette vérification.
- Mesures HTTP dans un serveur séparé, sur un sous-dossier temporaire du
  partage : 32 employés fictifs, 128 entrées, un projet. Aucun compte ni entrée
  existants n'ont été utilisés pour ces mutations.
- Le sous-dossier de test et le runtime temporaire sont supprimés à la fin.
- Rapport brut : `output/smb-audit-20261009.json`, ignoré par Git.

Ce réseau domestique permet de reproduire des délais SMB, pas de prédire les
temps exacts du disque R: au travail. Le dernier passage a été exécuté pendant
la suite de tests locale : les durées CPU peuvent être influencées par cette
charge. Ce sont des observations ponctuelles,
pas des médianes/p95. Les caches du client SMB/Windows ne sont pas purgés.
« À froid » signifie ici cache applicatif du modèle vide, pas cache matériel vide.

Les compteurs représentent des appels/tentatives aux API de fichiers,
**pas des paquets SMB ni un inventaire complet de toutes les opérations OS**.
Ils couvrent les lectures, métadonnées, énumérations et commits FileStore.
Les ouvertures/flush/suppressions internes des verrous, mkdir, nettoyages,
vérifications exceptionnelles de commit et écritures binaires des pièces
jointes ne sont pas tous comptés. Les temps incluent ces opérations lorsqu'elles
sont dans une fonction tracée, ainsi que le coût des traces.

Les durées des fonctions sont imbriquées : ne pas les additionner entre elles.
`selfMs` retire seulement les enfants instrumentés. Ce n'est pas un profileur
CPU. La sérialisation HTTP inline et tous les parseurs spécialisés ne sont pas
isolés; aucun pourcentage précis de temps CPU JSON n'est revendiqué.

## A. Architecture actuelle

```text
Navigateur — AppShell, vues et caches de présentation
    │ HTTP localhost, polling /sync/status
    ▼
saphir-server.ps1 — HttpListener, UNE voie d'exécution
    │ contexte dynamique request/response/currentUser
    ▼
routes/ — authentification, permissions, validation, réponse HTTP
    ├── services métier — mutations, import/export, historique
    ├── modules Saphir.* — décisions/calculs purs
    └── ReadModelService — projections et agrégations
          │ caches mémoire du processus
          ▼
FileStore — métadonnées, texte/bytes, retries, verrous, commits atomiques
    │                                     ▲
    └────────── partage SMB ───────────────┘
                     ▲
SyncService — changeId, epoch/révisions employé, watcher + validation TTL
```

| Fichier/zone | Responsabilité et dette pertinente |
| --- | --- |
| `lib/AppContext.ps1` | Configuration, chemins et initialisation DATA; mélange composition et écritures de démarrage. |
| `saphir-server.ps1` | Composition, scripts de routes précompilés, boucle bloquante `GetContext()`. Réconcilie les caches avant le routage, même pour les fichiers frontend. |
| `routes/` | Permissions backend et transactions orchestrées; scripts dot-sourcés, `continue` et variables de boucle. Pas encore des handlers isolés exécutables en parallèle. |
| `lib/FileStore.ps1` | Frontière de stockage générale. Protège les lectures/écritures et normalise l'identité des verrous entre chemins équivalents. |
| `services/SyncService.ps1` | Cache de révision, observation du partage, publication sous verrou. Ce sidecar n'est pas une transaction distribuée avec les fichiers métier. |
| `services/ReadModelService.ps1` | Cache de modèles global, caches par employé, projections filtrées par droits, coûts optionnels. Invalidation des fichiers ciblée, modèles généraux encore vidés globalement. |
| `services/AuthService.ps1` | Comptes, sessions, credentials, throttling et projections d'accès. Source de plusieurs caches et d'un contrat de mutations partiellement indépendant de sync. |
| `lib/CommonHelpers.ps1` | Catalogues projets/options/noms avec caches, mais tests d'existence directs avant la consultation des caches. |
| `CompensationGridService` / `OvertimeCostSnapshotService` | Grille, index salarial, estimations et snapshots privés. Pas de calcul salarial automatique dans les réponses employé ordinaires. |
| `EmployeeDirectoryService` / `ProjectMutationService` / `EntryService` | Opérations métier sur comptes/projets/entrées. À préserver, pas à remplacer par un DAO générique. |
| `HistoryService`, `BugReportService`, `BudgetPeriodService` | Stockage sidecar; historique et tickets ont leurs propres validations/mutations. |
| `modules/Saphir.*` | Durées, identité/état d'entrée, classification, compensation, couleurs/normalisation projets, permissions et validations pures. Bon point d'appui pour une future migration. |

### Exécution HTTP

La boucle appelle `GetContext()`, traite toute la requête, puis seulement
accepte la suivante. Le début d'une trace serveur se situe après cette
acceptation : le temps d'attente dans la file n'y figure pas.

L'authentification est généralement appelée deux fois : filtre du changement
de mot de passe puis route. La seconde bénéficie souvent du cache; elle n'est
pas une seconde lecture disque systématique. Le code reste néanmoins couplé
à la portée dynamique du serveur.

Le parallélisme nécessite de traiter les hashtables mutables, profondeurs de
factory, état auth/session, watcher et sa file, traces stdout, exceptions,
cycle de vie du listener et arrêt. Les verrous de fichiers ne rendent pas les
caches mémoire thread-safe. Lancer simplement des jobs/runspaces serait une
modification de comportement importante.

## B. Traces des cinq parcours

Le rapport brut contient les valeurs exactes de la dernière exécution. Les ordres
de grandeur ci-dessous résument ce passage; ils varient avec
la latence et le réchauffement du partage.

| Parcours | Temps serveur observé | Métadonnées partagées | Lectures partagées | Commits temporaires |
| --- | ---: | ---: | ---: | ---: |
| Connexion admin | ~0,9 s | 1 | 2 | 1 |
| Dashboard admin à froid | ~4,5 s | 40 | 36 | 0 |
| Dashboard admin à chaud | ~6 ms | 0 | 0 | 0 |
| Connexion employé | ~0,7 s | 0 | 1 | 1 |
| Dashboard employé premier passage | ~0,51 s | 8 | 4 | 0 |
| Dashboard employé à chaud | ~11 ms | 4 | 0 | 0 |
| Création/punch-in employé | ~1,3 s | 7 | 2 | 2 |
| Dashboard après changement d'un employé | ~0,73 s | 7 | 3 | 0 |
| Approbation | ~1,7 s | 4 | 4 | 3 |
| Rejet | ~2,0 s | 4 | 4 | 3 |
| `/sync/status` chaud | ~4,5 ms | 0 | 0 | 0 |
| `/sync/status` validation expirée | ~74 ms | 1 | 1 | 0 |

Le premier parcours Personnel et Projets a été mesuré aussi, mais après les
autres scénarios : ses caches de fichiers étaient déjà partiellement chauds.
Ce n'est pas une comparaison « démarrage à froid » entre vues.

### 1. Connexion

`POST /auth/login` → synchronisation du cache → lecture/index utilisateur
→ vérification PBKDF2 (CPU intentionnel) → verrou sessions → relecture fraîche
→ retrait des sessions expirées/ajout → commit atomique → purge auth locale
→ cookie/token et projection publique.

L'écriture de session est nécessaire. Le coût résiduel du login inclut le
hashage du mot de passe : ne pas diminuer les itérations pour gagner du temps.
Ce parcours ne publie actuellement pas de révision auth.

### 2. Dashboard admin

`GET /dashboard/bootstrap` → sync → auth et portée →
`Get-DashboardBootstrapModel` → `Get-ScopedEmployeeDataSnapshot` →
`Get-EmployeeDataSnapshot` → boucle des 32 fichiers employé → normalisation
→ projections autorisées, tris/compteurs → sérialisation/réponse.

À froid : 36 lectures, 40 métadonnées. Les lectures FileStore représentent
environ 3,0 s et les appels de métadonnées environ 0,84 s sur ce passage;
le temps propre de `Read-JsonArrayFile` est d'environ 14 ms, avec validation
et overhead inclus. C'est une forte preuve de coût I/O, pas une mesure pure
du parseur. À chaud : modèle réutilisé, aucun accès partagé compté.

Après une seule mutation, les autres fichiers bruts sont réutilisés, mais
les snapshots/projections globaux sont reconstruits. Le cas après expiration
des métadonnées remonte à 40 contrôles et environ 1,3 s sur le premier essai.
Il suit également des mutations : cette mesure ne prouve pas que le TTL seul
invalide un modèle déjà valide.

### 3. Dashboard employé

`GET /self/bootstrap` → sync/auth → utilisateur et fichier de cet employé
→ projection sans snapshot privé → projets actifs et trois listes d'options
→ réponse. Pas de snapshot de tous les employés, pas de calcul monétaire.

À chaud, quatre contrôles directs demeurent : `Get-Projects` et les trois
`Read-JsonOptionArray` vérifient l'existence avant leur cache. Ce parcours
explique les quatre métadonnées SMB alors qu'aucun contenu n'est relu.

### 4. Création d'entrée

`POST /self/punch` → sync/auth → règles de type d'entrée, code et projet
→ verrous appropriés, dont garde de références projet → relecture fraîche
→ validation état/durée/horaire → écriture employé atomique → publication sync
→ invalidation locale/réponse. Le scénario tracé est un punch-in; il ne
couvre pas toutes les branches punch-out, Divers ou création manuelle admin.

Deux commits : fichier employé et sync. Trois acquisitions de verrou ont été
observées. La durée d'acquisition inclut création/écriture du verrou SMB,
pas seulement un éventuel conflit avec un autre poste.

### 5. Approbation et rejet

`POST /employee/approval/{code}` → auth et portée projet → verrou employé
→ relecture fraîche → identité et transition → snapshot de coût si requis
→ commit employé → historique sous verrou → publication sync sous verrou
→ réponse avec éventuels avertissements post-commit.

Trois commits et trois verrous : employé, historique, sync. La publication
vient après le commit métier. Une erreur de publication ne doit pas pousser
le client à répéter silencieusement une transaction déjà réussie.

### Effet de file HTTP

Deux GET lancés quasiment ensemble ont montré `/sync/status` à environ 23 ms
côté client pour environ 2,1 ms d'exécution serveur, derrière Personnel
(~26 ms). La différence inclut transport et overhead client, donc n'est pas
une mesure exacte de la file seule. La sérialisation est certaine dans le
code; derrière un dashboard de 4,5 s, une autre requête peut attendre cette
durée. L'audit ne mesure pas un débit multi-utilisateur ni son p95.

## C. Carte des I/O réseau

| Accès | Où/pourquoi/fréquence | Classement et suite possible |
| --- | --- | --- |
| `Get-Item` de validation | FileStore metadata, auth users/sessions, fichiers employé; au miss/TTL | Cacheable; remplacer progressivement par révisions fiables, garder secours documenté. |
| `Get-Item` d'existence direct | CommonHelpers projets/options/noms, initialisation, helpers spécialisés | Évitable sur lecture chaude; séparer initialisation et lecture. Revalidation sous verrou toujours nécessaire en écriture. |
| `ReadAllText` | Miss de texte, auth, employé, catalogues | Nécessaire au premier chargement/changement; cacheable ensuite. |
| Existence + lecture sync | SyncService, dirty/watcher ou TTL 10 s | Nécessaire comme source commune actuelle; un contrôle et une lecture en validation normale, pas par employé. |
| Énumération `Get-ChildItem` | FileStore et parcours maintenance/export | Nécessaire pour découverte ou maintenance; éviter sur requête ordinaire si index fiable. Aucun parcours mesuré ne dépend d'une énumération par employé. |
| Lecture fraîche sous verrou | Mutations auth/entrées/projets/historique | Write-critical; ne pas remplacer par une copie mémoire préalable au verrou. |
| Création/flush de lock | FileStore, ressources métier et sync | Write-critical; ne pas supprimer. Mesurer coût uncontended séparément de contention. |
| Temp + replace/rename | FileStore, chaque commit | Write-critical. Sur ce montage, les remplacements sont tombés sur le fallback Move-Item; vérifier aussi sur Windows avant toute optimisation. |
| Lecture de destination après erreur de commit | FileStore | Write-critical et exceptionnelle : résolution d'un commit ambigu. |
| JSON tickets + images | BugReportService/FileStore bytes; ouverture/upload explicites | Cacheable pour lecture; commits binaires nécessaires. Writer spécialisé à caractériser séparément. |
| Backup sync corrompu | SyncService, récupération exceptionnelle | Nécessaire; pas une lecture chaude à optimiser. |
| Sonde `/health` | Écriture/suppression fichier test + tests d'existence | Diagnostic explicite; ne pas en faire une dépendance de toutes les lectures. |
| Initialisation defaults/schema | AppContext/Auth/DataSchema/Sync au démarrage | Nécessaire si absent; cacheable/évitable si déjà validé. Ne pas compter ces créations comme coût normal d'un GET. |
| Templates PDF, frontend, routes précompilées | Runtime local, export FDF/temp | Local dans le déploiement actuel, pas R:. Éviter de confondre tous les `Test-Path` avec des appels au partage. |
| Scripts externes, modifications manuelles, anciens clients | Hors protocole courant | Unknown : conserver un chemin de réconciliation tant que leur interdiction/compatibilité n'est pas assurée. |

Un appel FileStore pouvant réessayer plusieurs fois, le compteur de tentatives
augmente en cas d'erreur réseau. Le cas nominal ne décrit pas une panne SMB.

## D. Carte des caches

Tous les caches backend ci-dessous sont propres au processus PowerShell.
Les hashtables/objets ne sont pas protégés pour plusieurs runspaces. Aucun
cache frontend n'est une autorité d'accès ni de persistance.

| Propriétaire/cache | Données/source | Durée et invalidation | Validation réseau / mémoire |
| --- | --- | --- | --- |
| SyncService `CachedSyncState` | Document sync et révisions | 10 s par défaut, dirty par watcher, publication locale, reset explicite | Existence + lecture à échéance; un document. Dernier état valide conservé si indisponibilité. Watcher n'est pas une garantie SMB. |
| FileStore `FileMetadataCache` | Path, taille, timestamp | 30 s par défaut; purge après mutation/invalidation | Get-Item à échéance; entrées par chemin. Peut conserver dernière métadonnée valide en panne. Absence non traitée comme panne prouvée. |
| FileStore `TextFileCache` | Texte de chaque JSON | Pas de TTL propre; dépend des métadonnées, purge explicite | Métadonnées à consulter; texte stocké en plus du JSON parsé. |
| FileStore `BinaryFileCache` | Frontend local/images partagées | Même validation métadonnées | Octets potentiellement plus volumineux que JSON; pas de limite globale dédiée constatée. |
| CommonHelpers `ProjectsCache` | Projets normalisés | Clé taille/timestamp, purge via sync | Test d'existence direct + metadata; un catalogue. |
| CommonHelpers `EmployeeNameMapCache` | Noms | Clé taille/timestamp et purge | Test d'existence + metadata; un mapping. |
| CommonHelpers `JsonOptionArrayCache` | Options parsées par fichier | Taille/timestamp et purge | Test d'existence + metadata; listes courtes. |
| Auth `AuthStorageEnsured` | Drapeau d'initialisation | Durée du processus, pas cache des droits | Évite initialisation répétée; booléen. |
| Auth `AuthArrayFileCache` | users/sessions parsés | Taille/timestamp et mutations locales/revision auth | Métadonnées FileStore; deux collections sensibles en mémoire. |
| Auth `UserLookupCache` | Index username/code + users | Clé metadata users, purge auth | Metadata; duplique références/index, utile pour éviter scans répétés. |
| Auth `AuthenticatedUserRequestCache` | Projection user, expiry, version de sources | 10 s, expiration réelle session, changements de sources/purge; plafond ~128 | `Get-AuthSyncVersion` consulte users/sessions via metadata même avant hit auth. Chaud TTL metadata : 0 SMB; à échéance : vérification des deux sources possible. |
| Auth `ProjectAccessModelCache` | Portées visibles/modifiables par user | Version projets + identité/droits user, purge ciblée; plafond ~64 | Dépend des caches projets/users; existence directe peut rester coûteuse. |
| Auth `LoginThrottleState` | Échecs par principal/client | Fenêtre 300 s, nettoyage/plafond ~4096 | Aucun SMB; contrôle de sécurité, pas cache redondant à retirer. |
| ReadModel `ReadModelCache` | Dashboard, snapshots, listes/détails/statistiques | Aucun TTL propre; TOUT vidé sur nouveau changeId | Sync d'abord; rebuild peut reparcourir tous les employés. Plusieurs représentations et clés de filtres. |
| ReadModel `EmployeeEntryFileCache` | Entrées normalisées, snapshots privés internes | Taille/timestamp; epoch + révisions employé pour invalidation ciblée | Metadata par fichier lors d'un rebuild, contenu réutilisé sinon; une collection par employé. |
| Montants persistés (`compensationSnapshot`) | Résultat ou N/A | Révision du fichier employé | Remplace l'ancien `EmployeeMonetaryEntryCache` : aucun calcul ni lecture de classification/grille pour afficher un montant. Voir `COMPENSATION-BACKFILL.md`. |
| Compensation `CompensationGridRuntimeCache` | Document normalisé + raw | Identité du contenu/purge après changement | FileStore metadata puis texte; conserve une copie raw. |
| Compensation `CompensationGridSourceCache` | Hash de grille + raw | Seulement recalculé si contenu différent | Même source FileStore; pas de hash par entrée. |
| Compensation `CompensationSalaryBandIndexCache` | Index de bandes | Identité du document de grille | Aucun SMB supplémentaire; index utile pour calculs répétés. |
| BudgetPeriodService | Pas de cache métier indépendant | FileStore cache le texte; document reparsé à la lecture | Metadata au TTL; petit document. Optimisation CPU secondaire. |
| BugReportService | Pas de collection métier cachée indépendante | FileStore texte/bytes, purge mutations | Reparse/validation de collection; images uniquement à la demande. |
| Frontend AppShell | GET en vol coalescés | Retrait en finally; état session/sync | Évite doublons HTTP, pas stockage autoritatif. |
| Frontend Utilities/vues | Lookups options/projets, détails projet, état de vue | Session/URL/portée, changements sync et mutations; pas TTL backend | Mémoire du navigateur; pas SMB direct. Les droits sont recalculés côté serveur. |

Redondance principale : validation metadata/existence répétée entre les
couches. Conserver texte, JSON normalisé et index ne constitue pas à lui seul
un bug : chacun évite un travail différent. Le cache de modèles global et ses
projections dupliquées mérite une stratégie de dépendances/limites, pas une
suppression aveugle. Pas de mesure heap réalisée; les impacts mémoire sont
qualitatifs, pas des chiffres inventés.

## Contrat des mutations : conditions avant une autorité sync unique

| Famille | Écriture autoritative | Publication constatée | Limite |
| --- | --- | --- | --- |
| Punch/création/modification/suppression/note/horaire | Fichier employé | Routes employee/self : catégorie employee | Souvent post-commit; peut échouer. |
| Approbation/rejet/batch | Employés + historique | employee + codes affectés en batch | Plusieurs fichiers, pas transaction globale. |
| Comptes/profils/suppression/restauration | users/noms/fichiers employés | employee-directory ou auth dans routes | Les fonctions de stockage seules ne garantissent pas publication. |
| Login/logout et `Revoke-SessionsForUsername` | sessions | Purge locale, aucune publication dans ces primitives; login/logout n'en ajoutent pas | Trou confirmé. Mot de passe publie auth depuis sa route, pas preuve que chaque appelant le fait. |
| Projets, grille, budget, tickets | Fichiers respectifs | project / compensation / budget-periods / bug-reports | Post-commit, même limite de panne publication. |
| Import/annulation GC179, seed | Employés | Publication dans service et/ou route | Vérifier coalescence et couverture, ne pas multiplier les commits sync par entrée. |
| Historique | history | Option PublishChange; volontairement false quand route publie ensuite | Correct seulement avec propriétaire transactionnel explicite. |
| Snapshots de coût backfill | Fichier employé | Helper réécrit/purge localement, pas de publication dans la primitive | Auditer chaque appelant/outillage avant suppression fallback. |
| Initialisation/schema/defaults/récupération | Fichiers absents ou sidecars | Pas de publication métier systématique | Démarrage/maintenance à distinguer des transactions utilisateur. |
| Ancien client/édition manuelle/outillage externe | Potentiellement tout DATA | Non garanti | Ne pas affirmer couverture complète. |

Le dernier champ category/resource ne représente pas toutes les mutations
intermédiaires manquées. Les révisions par employé aident à les retrouver;
pour les autres catégories, le saut de version doit conserver une invalidation
prudente. Une epoch inconnue/rotative ou un schéma legacy doit déclencher une
réconciliation, pas « aucun changement ».

L'écriture métier et la publication sync sont deux commits. Il faut un contrat
de publication récupérable (ou un fallback périodique assumé), puis des tests
de panne entre commits, avant de supprimer toute vérification du fichier.
Une simple publication ajoutée au login ne résout pas cette fenêtre.

## E. Constats classés

### HIGH — I/O séquentiel sur chargement global

40 contrôles et 36 lectures sur un dashboard de 32 employés. Environ 4,5 s
à froid, contre quelques ms à chaud. Pattern N+1 fichier par employé; taille
des JSON et parsing ne sont pas les premières cibles. Tous les employés sont
requis pour certaines statistiques super admin, pas forcément pour un admin
limité à quelques projets.

### HIGH — Serveur HTTP sérialisé

Une opération SMB lente bloque les autres routes locales. Code confirmé et
écart client/serveur observé. Ne pas déduire de cette petite mesure le gain
exact d'une implémentation multithread.

### HIGH — Invalidation trop large des modèles

Chaque changeId vide le cache général. La sélectivité existe déjà pour les
fichiers bruts, mais les agrégats/projections sont reconstruits globalement.
Même un changement ticket/budget peut faire perdre des modèles indépendants.

### HIGH — Contrat de publication incomplet

Sessions, helpers de maintenance et fenêtre commit/publication empêchent
d'enlever les contrôles de fichiers en sécurité. C'est surtout un risque de
correctness pour l'optimisation proposée, pas une nouvelle fuite de droits
démontrée par cet audit.

### MEDIUM — Existence avant cache

Quatre appels SMB subsistent au bootstrap employé chaud. Gains accessibles
sans nouvelle technologie : initialization séparée, validation cohérente.

### MEDIUM — Sync expiré et statiques soumis à sync

~74 ms pour une validation expirée contre ~4,5 ms chaude sur ce passage
(~177 ms et ~3,5 ms sur le précédent, mêmes compteurs I/O).
Le serveur synchronise avant de distinguer les routes statiques locales.
Pendant une panne, une page/style local peut donc subir des retries DATA.

### MEDIUM — Coût des transactions et fallback replace

1,3–2,1 s sur les mutations tracées des deux passages, malgré aucune contention volontaire.
Plusieurs commits/verrous sont nécessaires. Le fallback de replacement est
observé sur macOS/SMB, pas confirmé sur le PC Windows au travail. Caractériser
avant toute modification de la stratégie atomique.

### LOW — JSON/index/mémoire et auth doublée

Les contrôles auth doublés sont souvent chauds. Le parsing mesuré ne justifie
pas de changer le format persistant. Les limites mémoire des modèles filtrés
restent à examiner si usage long/intensif; pas de fuite démontrée.

Aucun constat n'est classé CRITICAL : pas de perte de données ni de rupture
de sécurité reproduites dans ces mesures.

## F. Architecture cible minimale

```text
Route → contexte de requête explicite (identité validée + révision observée)
    ├── lecture → modèles existants avec dépendances
    │                → cache employé par epoch/révision
    │                → FileStore seulement si absent/périmé/réconciliation
    └── mutation → service métier
                     → lock → lecture fraîche → règles → commit atomique
                     → publication/invalidation récupérable
SyncService → observation commune amortie + invalidation ciblée
Modules purs → décisions métier, sans HTTP ni chemins DATA
```

Pas de nouveau Repository/DAO par objet. FileStore reste la frontière de
persistance et SyncService l'observateur partagé. ReadModelService conserve
la responsabilité des projections, avec des dépendances explicites plutôt
qu'une nouvelle couche de caches empilée.

Ordre recommandé : contrat de mutations → petits accès redondants → modèles
incrémentaux → mesurer à nouveau → décider si concurrence nécessaire.

## G. Plan progressif, non implémenté dans cet audit

| Phase | Fichiers concernés | Raison/gain attendu | Risque et tests | Retour arrière |
| --- | --- | --- | --- | --- |
| 0 — Baseline (cet audit) | PerformanceTrace, points FileStore/Auth/ReadModel/Sync/server, harness et test | Compter I/O et séparer froid/chaud sans changer les règles | Trace inactive par défaut; tests de retour/collections/confidentialité + suite complète | Désactiver SAPHIR_PERF_TRACE; retirer hooks sans changer DATA. |
| 1 — Contrat de mutations | AuthService, auth.routes, SyncService, routes métier, helpers de maintenance identifiés | Publier/qualifier toute mutation, définir récupération post-commit; prérequis à une autorité sync fiable | Pannes entre commits, deux postes, révocation/logout/password/disabled, batch, import/backfill; garder fallback | Petits commits; ancien client reste lisible; ne supprimer aucun fallback à ce stade. |
| 2 — Réduire validations redondantes | CommonHelpers, AppContext, FileStore, saphir-server, frontend.routes, AuthService | Retirer existence directe sur lecture chaude; statiques locales hors sync; une identité par requête | Absence/corruption/perte du partage; defaults jamais réécrits; auth/mustChangePassword/permissions/TTL; compteur self chaud visé 0 hors refresh | Revenir à la validation actuelle, sans migration DATA. |
| 3 — Modèles par dépendances | ReadModelService, ProjectStatsService, SyncService | Réutiliser projections employé et invalider seulement modèles affectés; éviter N validations sur changement d'un employé | Révisions multiples/saut de version/epoch legacy; permissions admin restreintes; un fichier modifié, autres conservés; salary/budget/project/noms dépendances | Garder possibilité invalidation globale et vérification metadata de secours. |
| 4 — Réconciliation maîtrisée | SyncService, FileStore, ReadModelService | Remplacer validations régulières par révisions là où le contrat le permet; fallback regroupé et observable | Publication échouée, anciens clients, timestamp/taille conservés, restauration, watcher absent, panne/reconnexion | Mode conservateur actuel disponible; ne pas rallonger TTL sécurité implicitement. |
| 5 — Transaction/SMB ciblé | FileStore, HistoryService, services mutateurs | Réduire tentatives/commits vraiment superflus si mesures Windows le prouvent; coalescer publications de batch | Tests multiprocess, contention, crash, commit ambigu, atomicité sur partage Windows réel; jamais supprimer locks | Stratégie actuelle replace/move conservée comme chemin testé. |
| 6 — Décision concurrence | server, RouteDispatch, routes ciblées, état caches/logs/control | Seulement si la file reste dominante après phases précédentes; isoler contexte et ownership avant pool borné | État mémoire/runspaces, credentials, exception/continue, shutdown, fairness, parallélisme lecture/écriture; stress réel | Mode sériel gardé, pas de changement du datastore requis. |

Chaque phase : baseline → tests → petit changement → suite complète → mêmes
scénarios SMB avant/après. Mesurer plusieurs passages et des percentiles avant
d'annoncer un gain de release. Pas de changement simultané de protocole HTTP,
format DATA et règles métier.

### Couverture à conserver

La suite couvre déjà les parcours entrée/approval, auth, révisions, FileStore
multiprocess, import/export, snapshots monétaires, UI et publication des routes.
Tests pivots : `test-file-store-multiprocess.ps1`,
`test-auth-cache-file-revision.ps1`, `test-auth-route-reliability.ps1`,
`test-route-sync-publication.ps1`, `test-single-entry-approval.ps1`,
`test-self-punch-work-comment.ps1`, `test-project-workspace-read-model.ps1`,
`test-monetary-read-model-projections.ps1` et `test-performance-trace.ps1`.

Les tests existants ne prouvent pas une couverture exhaustive des helpers
externes de mutation. Ajouter notamment les tests de publication session et
de récupération post-commit avant de changer l'autorité d'invalidation.

124 tests sélectionnés passent sur macOS. Les cas dépendant de Windows
signalent leur limitation/skip interne : ce résultat ne remplace pas une
validation du launcher, de Windows PowerShell 5.1 et des commits SMB sur le
poste de travail.

## Réponses explicites aux 17 questions

1. **HTTP sériel ?** Oui, `GetContext()` n'est rappelé qu'après traitement complet.
2. **Combien perdu ?** Environ 21 ms d'écart client/exécution pour le poll derrière une requête chaude; transport inclus. Un appel derrière un dashboard froid peut attendre plusieurs secondes. Gain global/p95 non mesuré.
3. **I/O dashboard admin ?** 40 metadata + 36 lectures au premier chargement des 32 employés; 0 + 0 à chaud, hors échéance/événement sync.
4. **I/O dashboard employé ?** 8 + 4 au premier passage après login, 4 + 0 à chaud, sur cette séquence.
5. **Endpoint le plus coûteux en I/O ?** `/dashboard/bootstrap` froid parmi ceux mesurés. Pas de classement exhaustif de tous les exports/imports et uploads.
6. **Coût sync ?** Quelques ms sans I/O à chaud; une metadata + une lecture à échéance, ~74–177 ms sur les deux essais. Plus sous panne/retry.
7. **Auth touche quand le partage ?** Validation users/sessions consultée par appel; chaude via metadata cache, aucun SMB. À cache expiré/invalidation : metadata et contenu selon changement. Login/logout écrivent sessions.
8. **Snapshot inspecte tous les employés ?** Oui, tous les comptes employés actifs à la construction, puis projection de portée. Un hit du modèle ne refait pas la boucle. Global parfois nécessaire; certaines portées devraient réutiliser des projections ciblées.
9. **Sync autorité principale sûre ?** Direction raisonnable, mais pas unique aujourd'hui; publication incomplète/non transactionnelle et anciens clients.
10. **Mutations sans sync ?** Oui, création/révocation de sessions, primitives d'initialisation et certains helpers backfill hors publication interne. Les appelants de maintenance restent à couvrir.
11. **Caches redondants ?** Surtout leurs validations; pas preuve que texte/normalisé/index soient tous superflus. Cache global et projections multiples à rendre dépendance-aware et bornés.
12. **Validation = trafic ?** Get-Item metadata à échéance, existence directe des catalogues, validation sync existence + contenu; même sans nouveau parsing.
13. **JSON vs réseau ?** Dashboard froid du rapport : ~3,0 s lectures + ~0,84 s metadata, ~14 ms temps propre ReadJsonArrayFile. Parseur pur/sérialisation HTTP pas isolés; I/O dominant démontré, pourcentage CPU exact inconnu.
14. **N+1 ?** Oui, boucle par fichier employé lors des reconstructions globales; appels metadata séquentiels malgré petits fichiers.
15. **Sans changer stockage ?** Existence chaude, statiques hors sync, auth par requête, invalidation ciblée des modèles, projections incrémentales et contrat mutation/publication.
16. **Concurrence maintenant ?** Réduire I/O d'abord : différence froid/chaud montre un gros potentiel. Réévaluer file/p95 ensuite; concurrence sûre implique changement de contexte/ownership mémoire et dispatch, pas juste un job.
17. **Préparer .NET/DB sans surcouche ?** Garder modules purs, rendre entrées/sorties de services explicites, centraliser stockage/transaction/publication; conserver contrats et tests. Pas de DAO générique ni réécriture frontend nécessaire.

## Reproduire

Partage monté et accessible, puis depuis la racine du dépôt :

```powershell
pwsh -NoProfile -File scripts/audit-smb-performance.ps1 `
  -NetworkDataFolder /Volumes/OvertimeTest/data `
  -ReportPath output/smb-audit.json

pwsh -NoProfile -File scripts/test-all.ps1
```

Sous Windows, donner le chemin UNC ou le lecteur de test réellement monté.
Le harness exige un dossier DATA existant et crée son propre sous-dossier;
ne pas modifier son comportement pour écrire les fixtures à la racine DATA.

Pour tracer un serveur manuellement, définir `SAPHIR_PERF_TRACE=1` avant de le
démarrer. Une ligne stdout `SAPHIR_PERF` par requête contient durées, compteur
d'opérations et identifiant de corrélation `X-SAPHIR-Trace`. Aucun contenu,
mot de passe, token ou chemin de fichier n'est journalisé par ces traces.
Les traces normales de l'application sont indépendantes de ce dispositif.
La trace n'est pas thread-safe pour de futurs runspaces; ne pas la partager
sans adapter son ownership.

## Point d'arrêt

Configuration locale SMB et instrumentation uniquement. Aucun changement aux
règles métier, verrous, commits atomiques, fréquence de polling, dispatch HTTP
ou droits. Les phases 1–6 ci-dessus sont des propositions à valider avant
implémentation.
