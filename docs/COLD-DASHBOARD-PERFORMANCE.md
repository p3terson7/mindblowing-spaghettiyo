# Chargement à froid du dashboard

Travail du 14 octobre 2026, après le cache par dépendances. Ce rapport distingue
les mesures SMB des estimations et conserve les décisions rejetées. Les données
réelles, le format JSON, les transactions métier et le serveur HTTP séquentiel
restent dans leur périmètre actuel.

## Parcours analysé

`GET /dashboard/bootstrap` : réconciliation sync → authentification (gate et
route) → catalogue/portée de lecture et modification → snapshot employés →
contributions ordinaires → contributions filtrées par identité/droits → totaux,
files et employé sélectionné → historique récent → sérialisation HTTP.

Les fichiers indépendants sont les fichiers `*_data.json` des utilisateurs
actifs présents dans `users.json`. Le dossier ne définit pas les utilisateurs
autorisés : un fichier orphelin ne doit jamais ajouter un employé au dashboard.
Les données monétaires ne sont pas calculées dans ce parcours.

Les services de projection, classification, droits et cache de modèles ne sont
pas indépendants : ils mutent des hashtables, une pile de factories, des caches
auth/projets et le registre de dépendances. Aucune de ces structures ne doit
être partagée avec des workers. Les mutations sous verrou doivent continuer
à ouvrir des fichiers frais, même si une lecture précédente est en cache.

### Inventaire des accès

Pour 32 employés, la baseline mesurée fait 41 appels metadata et 37 lectures
sur le dashboard à froid. Chaque employé nécessite un premier snapshot
metadata puis une lecture. Le deuxième appel logique à metadata par son
lecteur JSON bénéficie déjà du cache FileStore : ce n'est pas un deuxième
appel SMB par employé.

Les autres accès concernent sync, users/sessions (selon expiration), projets,
historique et noms. `Get-Projects` et `Get-EmployeeNameMap` vérifient encore
directement l'existence avant leur snapshot metadata, même sur cache chaud.
Les caches de portée demandent plusieurs fois le catalogue, d'où des probes
répétés. Les traces contiennent un identifiant SHA-256 tronqué par ressource
et des comptes par opération; aucun chemin, nom, HRMIS ou contenu n'est loggé.

La baseline applicative est préservée dans
`output/cold-dashboard-baseline/app`, avec la même instrumentation mémoire et
ressources que les versions mesurées ensuite. Une copie sans ces extensions
de trace subsiste dans `output/cold-dashboard-original/app`.

## Méthode de mesure

`scripts/benchmark-cold-dashboard.ps1` crée des sous-dossiers UUID dans le
partage monté `/Volumes/OvertimeTest/data`. Un nouveau backend HTTP local est
lancé pour chaque observation. Les fichiers employés et modèles commencent
froids; l'initialisation et le login peuplent naturellement les fichiers core.
Le démarrage et le login ne sont pas inclus dans le temps du GET dashboard.

Chaque observation comprend le GET froid, deux GET chauds, puis un changement
par un deuxième processus et un nouveau GET. Les totaux attendus, le nombre
d'employés, la file d'approbation et l'égalité du DTO froid/chaud sont vérifiés.
La fixture contient quatre entrées par employé, trois approuvées et une en
attente, dans le mois courant. Le protocole de benchmark fixe sync à 1 seconde
et attend 1,1 seconde après le writer; le TTL de production n'est pas modifié.

Les rapports enregistrent durée serveur et HTTP client, opérations filesystem,
hits/misses, contributions recomputées, reconstructions/purges, modèles et
dépendances présents, mémoire managed et working set avant/après. La mémoire
est un snapshot, pas un pic ni une taille retained après GC. `privateBytes=0`
sur ce runtime macOS signifie métrique indisponible, pas zéro mémoire privée.
Les temps de fonctions sont imbriqués, donc ne doivent pas être additionnés.

Les caches OS/SMB ne sont pas purgés. Les mesures sont successives, sans suite
de tests simultanée. Les compteurs sont des tentatives d'API, pas des paquets
SMB : une énumération peut demander plusieurs échanges réseau et le système
peut effectuer des accès internes non instrumentés. Avec cinq observations,
le p95 nearest-rank est le maximum observé; ce n'est pas un p95 de production.

## Capacité du cache

Un dashboard d'un gestionnaire crée `2 × employés + 5` modèles : une
contribution ordinaire et une contribution de portée par employé, plus les
agrégats/dashboard/historique. D'autres identités, vues, filtres et projections
monétaires ajoutent des variantes. Les enfants transmettent leurs sources au
parent, même sur hit.

La baseline à 512 modèles purge tout le cache à saturation. Une première
purge peut donc survenir au-delà de 253 employés. L'agrégat en cours peut être
correct malgré la purge, car ses objets locaux restent vivants, mais une
modification ultérieure peut reconstruire beaucoup de contributions perdues.
Une limite de modèles n'est pas une limite mémoire globale : texte, metadata,
entrées normalisées et snapshots restent aussi détenus par d'autres caches.

## Phases architecturales non implémentées

### Affichage progressif

L'identité, la liste de projets et le choix d'employé pourraient apparaître
avant les agrégats, via un endpoint initial léger et un endpoint de statistiques
séparé. Les KPIs et files d'approbation ne doivent jamais afficher les résultats
d'un sous-ensemble comme s'ils étaient complets. Il faudrait un état explicite
« chargement », une révision commune, annuler les réponses d'une ancienne
identité/période et appliquer les mêmes permissions aux deux endpoints.

Cela réduit le temps avant une interaction utile, pas nécessairement le temps
de calcul. Avec le serveur séquentiel, une requête de statistiques longue
continue à bloquer les suivantes. Le frontend actuel attend son bootstrap
complet : découper la réponse demande un chantier UX/contrat distinct.

### Index agrégé persistant

Un index dérivé pourrait remplacer des centaines de lectures froides par
quelques lectures, mais déplacerait la complexité sur toutes les écritures.
Il devrait contenir versions des fichiers sources, epoch, schemaVersion et
révision de droits/grille, rester privé, et ne jamais devenir la source métier.

Un commit employé et un commit index ne forment pas une transaction distribuée.
Il faut donc rendre un index incomplet identifiable, coordonner les writers
par un verrou dédié, reconstruire de manière atomique dans un fichier
temporaire, vérifier les révisions pendant la reconstruction et publier la
nouvelle génération seulement si elle est cohérente. Les erreurs/absences,
versions inconnues et publications ratées doivent retrouver les fichiers
sources via fallback et réconciliation. Un index global peut devenir un point
de contention. Son coût de maintenance inclut migration, corruption, réparation,
permission, changements de grille et compatibilité des anciennes versions.

Ce n'est pas le premier choix tant que les lectures indépendantes peuvent être
rendues sensiblement plus rapides. Aucun index persistant ni chargement
progressif n'est implémenté pendant cette tâche.

## Références techniques

Les informations de taille des `FileInfo` issus d'une énumération sont déjà
préchargées; un `Refresh()` les actualise :
[Microsoft — FileInfo.Length](https://learn.microsoft.com/en-us/dotnet/api/system.io.fileinfo.length?view=netframework-4.8.1).
Une énumération n'est toutefois pas un snapshot transactionnel d'un dossier.
Le pool de runspaces fournit une borne minimale/maximale de workers, sans
nécessiter les fonctionnalités PS7 de foreach parallèle :
[Microsoft — RunspaceFactory.CreateRunspacePool](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.runspaces.runspacefactory.createrunspacepool).

## Optimisations de métadonnées et capacité

- Un groupe d'au moins huit fichiers employés sans metadata en cache utilise
  une seule énumération filtrée. Seuls les chemins issus des utilisateurs actifs
  sont retenus. Les métadonnées existantes ne sont pas renouvelées; l'absence
  d'un fichier dans le listing ne prouve pas qu'il n'existe pas. Le lecteur
  habituel conserve ses retries et vérifie le parent pour les fichiers absents.
- Les helpers noms/projets réutilisent leur snapshot metadata pour l'existence.
  Leur création reste sous verrou avec une nouvelle vérification fraîche.
- Une observation réussie porte `ObservedAtUtc`. La réconciliation ne répète
  pas un probe plus jeune que la limite FileStore de 30 secondes. Un TTL renouvelé
  après une erreur réseau ne renouvelle pas cette preuve. Un probe de
  réconciliation réussi alimente aussi FileStore pour ne pas être refait ensuite.
- La saturation évince un seul modèle least-recently used. Valeur, dépendances
  et compteur d'accès sont retirés ensemble. Les parents conservent les sources
  héritées de leurs enfants, même si un enfant est évincé pendant une factory.
  Aucune éviction de capacité ne déclenche une purge globale des fichiers bruts.
- La capacité est configurable par `SAPHIR_READ_MODEL_CACHE_CAPACITY` (16 à
  4 096). La phase 2 compare explicitement 1 024 à la baseline de 512; pas de
  choix de capacité fondé uniquement sur le nombre de fichiers.

Le coût d'une énumération dépend du système et du partage : réduire des appels
`Get-Item` ne signifie pas réduire d'autant les paquets SMB. Sur ce Mac,
l'énumération elle-même prend du temps, ce qui explique le faible gain froid
de cette phase tant que les lectures de contenu restent séquentielles.

### Mesures baseline et phase 2 séquentielle

Rapports : `output/cold-dashboard-smb-before.json`,
`output/cold-dashboard-smb-phase2.json` (32/100) et
`output/cold-dashboard-smb-phase2-large.json` (300/500). Cinq observations par
taille. Les lectures froides chargent toutes les contributions dans les deux
versions : 32, 100, 300 ou 500, plus les contributions de portée correspondantes.

| Employés | Médiane baseline → phase 2 | p95 baseline → phase 2 | Metadata baseline → phase 2 | Lectures de fichiers |
| --- | ---: | ---: | ---: | ---: |
| 32 | 3 971 → 3 761 ms | 4 437 → 4 331 ms | 42 → 7 + 1 énumération | 38 → 38 |
| 100 | 10 214 → 10 438 ms | 13 227 → 13 091 ms | 110 → 7 + 1 énumération | 106 → 106 |
| 300 | 41 439 → 38 604 ms | 45 443 → 40 544 ms | 615 → 311 + 1 énumération | 306 → 306 |
| 500 | 68 608 → 67 593 ms | 79 116 → 68 014 ms | 1 015 → 511–532 + 1 énumération | 506 → 506 |

La phase 2 seule n'apporte pas un gain froid important et régulier. Elle
supprime des probes redondants, mais conserve le coût de toutes les lectures.
Les fichiers dont l'observation dépasse 30 secondes pendant un long chargement
restent revalidés; cette sécurité n'a pas été allongée pour rendre les chiffres
plus beaux. Les rapports incluent tous les passages réussis, sans couper les
pics périodiques.

| Employés | Modèles présents baseline → capacité 1 024 | Mémoire managed médiane baseline → phase 2 | Working set médian baseline → phase 2 | Après une modification : médiane baseline → phase 2 |
| --- | ---: | ---: | ---: | ---: |
| 32 | 69 → 69 | 98,1 → 98,0 Mio | 246,2 → 250,3 Mio | 343 → 342 ms |
| 100 | 205 → 205 | 118,9 → 116,0 Mio | 268,7 → 187,0 Mio | 375 → 449 ms |
| 300 | 93 → 605 | 169,8 → 172,6 Mio | 230,0 → 298,4 Mio | 4 910 → 610 ms |
| 500 | 493 → 1 005 | 223,9 → 224,9 Mio | 249,9 → 323,4 Mio | 11 766 → 755 ms |

La baseline purge ses 512 modèles une fois pendant le froid de 300/500 employés;
la phase 2 n'en évince aucun à capacité 1 024. Après une seule modification,
300/500 contributions sont reconstruites dans la baseline, contre une seule
dans chacun des cinq essais de la phase 2. Les chiffres mémoire incluent des
allocations non collectées; les variations de working set ne sont pas une
mesure de la seule taille du registre. La mémoire globale n'est pas bornée par
la limite de modèles.

### Incidents du protocole de mesure

Une première série phase 2 a été interrompue pendant l'arrêt d'un backend;
elle a été reprise. Le harness attend désormais 30 secondes après la réponse
shutdown, puis arrête uniquement son processus de fixture s'il reste vivant,
et enregistre ce cas. Les séries retenues indiquent un arrêt gracieux.

L'instrumentation a aussi révélé un choix d'overload `Math.Max` Int32 pour le
temps propre d'un span dépassant 2,1 milliards de ticks. Le compteur est
explicitement Int64, avec un test sans attente longue. La série interrompue
par cette erreur a été reprise. Les mesures baseline déjà réussies ne sont pas
affectées par cette correction du logger, aussi appliquée à la copie baseline.
Sans trace activée, cette erreur n'existe pas dans le chemin de production.

## Expérience de lectures bornées

Rapport `output/cold-dashboard-smb-parallel-experiment.json` : trois
observations à chaque taille pour 2, 4 et 8 lecteurs. Le niveau 1 est la phase
2 séquentielle ci-dessus (cinq observations). Les médianes en millisecondes :

| Employés | 1 lecteur | 2 lecteurs | 4 lecteurs | 8 lecteurs |
| --- | ---: | ---: | ---: | ---: |
| 32 | 3 761 | 2 830 | 2 620 | 2 041 |
| 100 | 10 438 | 6 218 | 4 947 | 4 458 |
| 300 | 38 604 | 20 164 | 14 458 | 9 818 |
| 500 | 67 593 | 46 033 | 25 883 | 15 852 |

| Employés | p95 2 / 4 / 8 lecteurs | Mémoire managed médiane 2 / 4 / 8 lecteurs (Mio) |
| --- | ---: | ---: |
| 32 | 2 938 / 2 626 / 2 271 ms | 100,7 / 99,7 / 113,4 |
| 100 | 7 378 / 4 960 / 4 678 ms | 122,1 / 124,4 / 125,0 |
| 300 | 21 240 / 15 694 / 11 389 ms | 172,7 / 173,5 / 181,1 |
| 500 | 47 839 / 26 004 / 19 764 ms | 231,4 / 231,5 / 231,4 |

Les 36 réponses ont la même empreinte DTO que la baseline pour leur taille.
Toutes chargent N contributions ordinaires et N contributions de portée.
Il n'y a ni éviction ni purge à capacité 1 024 dans ce parcours. Les lectures
restent N+6 : le parallélisme les chevauche, sans prétendre les supprimer.
Les niveaux 4/8 restent sous la frontière de 30 secondes aux quatre tailles :
7 probes metadata + 1 énumération. À 500/2, le chargement dépasse cette frontière
et fait 511 probes. Toutes les modifications ultérieures recalculent une seule
contribution. Les 36 arrêts de backend sont gracieux.

### Décision et fonctionnement

Les gains sont assez importants pour conserver le préchargement, avec **8
lecteurs maximum par défaut**, configurable par
`SAPHIR_EMPLOYEE_READ_CONCURRENCY=1|2|4|8`. Le niveau 1 désactive le pool. Aucun
pool n'est créé si moins de huit fichiers nécessitent une lecture de contenu,
donc le rafraîchissement d'un seul employé conserve le chemin direct.

`EmployeeFileReadService.ps1` ouvre un pool local à la requête, et ne crée pas
plus de huit invocations PowerShell à la fois. Les workers de
`EmployeeFileReadWorker.ps1` importent seulement FileStore et les traces; ils
ont leurs propres caches, locks vides et métriques. Ils reçoivent chemins,
scalaires et une **copie** des métadonnées, jamais le registre, les utilisateurs
ou les objets de projection du serveur. Ils ne publient ni révision ni modèle.

Les résultats sont collectés dans l'ordre des chemins. Le cache texte du
serveur n'est alimenté que si tous les workers réussissent. JSON, normalisation,
estimations monétaires éventuelles, permissions, agrégations et enregistrement
des dépendances restent sur la voie HTTP unique. En cas d'échec, les workers
en cours sont arrêtés/disposés et le pool fermé. Un JSON corrompu échoue ensuite
dans le parseur normal : il n'est jamais remplacé par une contribution vide.

Les retries FileStore, la confirmation des fichiers absents par leur parent et
les métadonnées horodatées sont conservés. Un TTL de worker n'est pas remis à
zéro lors de sa copie dans le serveur. Les lectures sous un verrou de mutation
bypassent toujours le cache préchargé. Il n'y a aucune écriture métier ni
normalisation concurrente.

Ce parcours n'est pas une transaction de lecture de tout le département.
Chaque fichier est lu selon les mêmes garanties d'atomicité que le lecteur
sériel. Une publication concurrente invalide les sources à l'observation sync
suivante; les publications ratées restent couvertes par la réconciliation
30 secondes / contenus forcés cinq minutes. Le parallélisme ne prétend pas
produire un snapshot global transactionnel ni une révocation instantanée au
milieu d'une requête déjà authentifiée.

La capacité par défaut devient **1 024 modèles**, après la mesure de 1 005
modèles à 500 employés et de son coût mémoire. LRU reste actif pour les autres
vues, identités et filtres; la croissance ne devient pas illimitée. Une
installation avec plusieurs gestionnaires/vues à 500 employés peut bénéficier
d'une capacité plus grande, mais doit la mesurer : 1 024 n'est pas une promesse
de conserver toutes les variantes.

## Validation finale

Rapport de confirmation `output/cold-dashboard-smb-after.json` : cinq nouveaux
backends froids par taille, version intégrée, capacité par défaut 1 024 et niveau
8, sans exécution de tests simultanée. Toutes les réponses ont la même empreinte
que la baseline; les 20 arrêts sont gracieux.

| Employés | Médiane avant → finale | Gain médian | p95 avant → finale | Metadata avant → finale | Lectures |
| --- | ---: | ---: | ---: | ---: | ---: |
| 32 | 3 971 → 2 205 ms | 44,5 % | 4 437 → 2 248 ms | 42 → 7 + 1 énumération | 38 → 38 |
| 100 | 10 214 → 4 475 ms | 56,2 % | 13 227 → 4 643 ms | 110 → 7 + 1 énumération | 106 → 106 |
| 300 | 41 439 → 11 263 ms | 72,8 % | 45 443 → 11 947 ms | 615 → 7 + 1 énumération | 306 → 306 |
| 500 | 68 608 → 19 524 ms | 71,5 % | 79 116 → 20 084 ms | 1 015 → 7 + 1 énumération | 506 → 506 |

Le coût réseau n'est pas nul : toutes les lectures nécessaires restent présentes.
À 300/500, terminer sous 30 secondes évite aussi une revalidation massive à
l'intérieur du bootstrap. Aucun TTL n'est allongé pour obtenir cette amélioration.

| Employés | Modèles / misses froids | Contributions ordinaires / portée | Mémoire managed avant → finale | Working set avant → finale | Deuxième GET chaud médian |
| --- | ---: | ---: | ---: | ---: | ---: |
| 32 | 69 / 69 | 32 / 32 | 98,1 → 113,4 Mio | 246,2 → 258,2 Mio | 8,3 ms |
| 100 | 205 / 205 | 100 / 100 | 118,9 → 125,6 Mio | 268,7 → 269,2 Mio | 5,2 ms |
| 300 | 605 / 605 | 300 / 300 | 169,8 → 181,2 Mio | 230,0 → 294,1 Mio | 6,2 ms |
| 500 | 1 005 / 1 005 | 500 / 500 | 223,9 → 231,4 Mio | 249,9 → 324,0 Mio | 9,5 ms |

Aucune des 20 lectures froides finales n'évince/purge de modèle; la baseline
en purge 512 à 300 et à 500. Le GET chaud fait deux hits de modèles, zéro miss,
zéro reconstruction. Les états auth/sync et vérifications périodiques peuvent
toujours ajouter de l'I/O sur d'autres lectures; ces chiffres ne sont pas une
garantie de zéro réseau à tout instant.

Après une seule modification distante, toutes les tailles finales font sept
misses/reconstructions de modèles, conservent `2N-2` hits et ne recalculent
qu'une contribution ordinaire et une de portée. Les médianes avant → finale
sont 343 → 285 ms (32), 375 → 432 ms (100), 4 910 → 643 ms (300),
11 766 → 716 ms (500). Le cas 100 n'améliore pas ce rafraîchissement; le pool
n'est pas utilisé pour un seul fichier. Le gain massif à 300/500 vient de la
capacité/éviction, pas de lectures parallèles sur cette mutation.

Les gains du prototype ne sont pas présentés comme une promesse exacte : par
exemple 500/8 donne 15,9 secondes de médiane exploratoire puis 19,5 secondes
sur la confirmation. Le rapport final utilise cette seconde mesure. La cible
du chantier n'était pas un seuil fixe mais une amélioration mesurable sûre.

Les empreintes cumulées SHA-256 des **45 fichiers JSON existants à la racine
DATA** sont identiques avant/après (`2300b521…bcce15`). Aucun sous-dossier
`saphir-cold-*` ne reste sur le partage; les runtimes/backends de fixture sont
arrêtés et supprimés. Les rapports et copies baseline sous `output/` sont
ignorés par Git et conservés pour comparaison.

Pour reproduire :

```powershell
pwsh -NoProfile -Command '& ./scripts/benchmark-cold-dashboard.ps1 -NetworkDataFolder /Volumes/OvertimeTest/data -EmployeeCounts @(32,100,300,500) -Iterations 5 -Concurrency @(1) -ApplicationRoot output/cold-dashboard-baseline/app -ReportPath output/cold-dashboard-smb-before.json'
pwsh -NoProfile -Command '& ./scripts/benchmark-cold-dashboard.ps1 -NetworkDataFolder /Volumes/OvertimeTest/data -EmployeeCounts @(32,100,300,500) -Iterations 5 -Concurrency @(8) -ReportPath output/cold-dashboard-smb-after.json'
```

Depuis Windows, remplacer le chemin monté par le chemin UNC du partage de test.
Le harness utilise actuellement `pwsh` pour démarrer les backends de benchmark.
Les tests de runtime Windows doivent être exécutés sur Windows séparément.

### Régressions

- Phase 1 : 126 tests sélectionnés, aucun échec, 76,4 secondes.
- Phase 2 après corrections : 128 tests sélectionnés, aucun échec, 84,9 secondes.
- Phase 3 intégrée : 129 tests sélectionnés, aucun échec, 87,0 secondes.
- Deux tests Windows ont un skip interne sur ce Mac, compté comme succès par
  le runner. Les APIs utilisées existent en Windows PowerShell 5.1 et l'audit
  syntaxique passe; cela ne remplace pas une exécution réelle Windows/PS5.1.

Nouveaux tests : `test-cold-dashboard-loading.ps1`,
`test-cold-metadata-batch.ps1`, `test-employee-file-prefetch.ps1`. Ils couvrent
le DTO et les totaux froids/chauds aux niveaux 1/2/4/8, les limites de portée,
un autre processus de mutation, fichiers orphelins/absents/corrompus, indisponibilité
et restauration du dossier DATA, exactitude des bytes/stamps, copie détachée de
metadata, absence de modèles enregistrés par les workers, publication du cache
seulement après succès de tous les workers et bypass sous verrou d'écriture.

Le test du registre ajoute LRU, propagation après éviction et synchronisation
des trois dictionnaires. Les tests existants de publications ratées font vieillir
les véritables observations metadata, pas seulement l'horloge globale de sweep.
Le test de trace vérifie les compteurs Int64 avec un span simulé long, sans
attendre plusieurs secondes. Les 80 commits multiprocess FileStore restent
préservés; les contrats HTTP, profils, montants, exports et frontend passent.

### Fichiers de ce chantier

| Fichier | Changement |
| --- | --- |
| `app/backend/lib/FileStore.ps1` | Observation réussie horodatée, batch froid de metadata depuis une énumération. |
| `app/backend/lib/CommonHelpers.ps1` | Réutilisation du snapshot metadata pour noms/projets; création sous verrou préservée. |
| `app/backend/lib/PerformanceTrace.ps1` | Mémoire/capacité/ressources anonymisées, compteurs Int64. |
| `app/backend/services/ReadModelCacheService.ps1` | LRU, capacité configurable mesurée, suppression des doubles probes frais. |
| `app/backend/services/ReadModelService.ps1` | Appel du préchargement avant assemblage, sans nouveau DTO. |
| `app/backend/services/EmployeeFileReadService.ps1` (nouveau) | Borne/pool, collecte ordonnée, publication du cache brut et métriques. |
| `app/backend/services/EmployeeFileReadWorker.ps1` (nouveau) | Lecture FileStore isolée et retries; aucune projection ni écriture. |
| `scripts/benchmark-cold-dashboard.ps1` (nouveau) | HTTP réel froid/chaud, matrices taille/concurrence, empreintes et mémoire. |
| Trois nouveaux tests + registre/traces/cohérence | Régressions ciblées et clocks de test explicites. |
| `tests/lib/CacheCoherenceFixture.ps1` | Runtime alternatif pour valider le prototype avant intégration. |
| Documentation d'architecture/caches | Rapport et liens vers les garanties/résultats. |

Les modifications précédentes encore présentes dans l'arbre de travail,
notamment `data/`, ne font pas partie de ce chantier et n'ont pas été annulées.
Aucun commit/push ou publication de release n'est inclus.

### Limites

Le backend HTTP reste séquentiel et peut bloquer les autres requêtes du même
poste pendant un gros chargement. Le calcul/normalisation/tri/sérialisation reste
sériel et significatif à 500 employés. Huit lecteurs par poste peuvent saturer
un partage si plusieurs postes démarrent simultanément : ce benchmark n'est
pas un test de charge de plusieurs gestionnaires connectés ensemble.

Les mesures portent sur un Mac/PS7 lisant un partage Windows domestique, avec
quatre entrées par employé. Beaucoup d'historique ou un réseau de travail plus
lent peuvent changer le résultat. Pas de purge OS ni d'estimation de débit
production. Les caches de fichiers bruts restent dimensionnés par les données
chargées; LRU borne les modèles, pas toute la mémoire du processus.

Le préchargement ne répare pas les JSON corrompus, n'améliore pas le login ou
les écritures, et ne transforme pas les commits multi-fichiers en transaction
distribuée. Affichage progressif et index persistant restent uniquement des
évaluations documentées, pas des fonctionnalités cachées activées.
