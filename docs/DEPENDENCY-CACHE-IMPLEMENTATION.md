# Caches par dépendances et contributions par employé

Implémentation du 13 octobre 2026, suite à `PERFORMANCE-SMB-AUDIT.md`.
La persistance JSON, les transactions, les règles métier et le serveur HTTP
séquentiel sont conservés. Aucun chantier de démarrage à froid n'a été engagé.

## Ce qui change

Un nouveau `changeId` ne vide plus systématiquement tous les modèles.
Chaque factory déclare ses sources; un modèle parent hérite aussi des
dépendances des modèles enfants, même si ces enfants viennent du cache.
Le registre stocke seulement `clé de modèle → ensemble de sources`, à côté
du cache existant. Pas de bus d'événements ni de framework de graphes.

Les données/projections d'un employé sont des contributions réutilisables.
Après un changement d'un employé, les autres contributions sont conservées.
Les agrégats sont reconstruits depuis ces contributions : concaténation,
filtrage et tri restent simples et exacts, sans compteurs ajustés par une
arithmétique de deltas susceptible de dériver au fil des modifications.

Le dashboard sépare son historique récent de son noyau d'heures. Un ticket
peut actualiser l'historique sans reconstruire les projections employé.
La réponse HTTP contient toujours les mêmes champs.

### Carte des dépendances

| Modèle/source | Dépendances directes | Dépendances transitives / conservation |
| --- | --- | --- |
| Contribution employé ordinaire | `employee:{code}`, `directory`, `auth` | Entrées normalisées et projection publique; conservée sur tickets, budget, catalogue et grille salariale. |
| Contribution employé monétaire | Les précédentes + `compensation` | Repose sur le cache monétaire existant; snapshots privés jamais exposés directement. |
| Contribution de portée | Employé précis, directory/auth, projects; compensation si demandé | Identité, rôle, droits de modification et liste de projets font partie de la clé. |
| Snapshot employés | directory/auth | Hérite des sources de chacun de ses employés; assemble les contributions inchangées. |
| Snapshot de portée / révision | directory/auth/projects; compensation pour révision chiffrée | Hérite des contributions; conserve les filtrages et droits backend actuels. |
| Dashboard heures | directory/auth/projects | Hérite du snapshot de portée; clé contient aussi le mois courant. Pas de dépendance à history/bugs/budget/grille dynamique. |
| Historique | history/directory | Cache séparé, actualisé lors des mutations qui peuvent écrire l'historique. |
| Personnel | directory/auth/projects/compensation | Statistiques par employé réutilisées; seul le contributeur modifié est recalculé. Responsabilités projet recomposées depuis le catalogue. |
| Statistiques/résumés/tendances projets | directory/auth/projects/compensation | Contributions monétaires par employé/portée, puis regroupement exact par période et projet. |
| Budget | Configuration indépendante | Pas de nouveau cache de calendrier; les résumés de projets sont déjà clés par dates. Changer une période ne rend pas faux un résumé pour les anciennes dates. |
| Tickets/images | bugs, et history si journalisation | Pas de dépendance des contributions employé à ces fichiers. |
| Sessions | Cache d'authentification | Une session révoquée est refusée avant l'accès aux modèles; un nouveau login n'invalide pas les heures des autres utilisateurs. |
| Factory non déclarée | `*` | Invalidation prudente, pas de réutilisation spéculative. |

Les admins peuvent actuellement lire tous les projets, mais modifier seulement
ceux dont ils sont responsables; les super admins ont des droits plus larges.
Cette règle existante est préservée. Les clés différencient les identités,
rôles et portées de modification; une projection de super admin n'est pas
réutilisée pour un admin ou un employé.

Un changement de catalogue invalide les modèles qui utilisent le catalogue
ou ses droits, mais pas les contributions brutes indépendantes. Il reste
volontairement large au sein des modèles projet : parts du département,
listes visibles et responsabilités dépendent de plusieurs projets. Il n'y a
pas de tentative fragile de cibler un seul projet dans ces agrégats.

Le registre appartient à un seul runspace. Le patch initial du 13 octobre
utilisait une limite de 512 avec purge générale à saturation. Le travail du
14 octobre remplace cette purge par LRU, avec une capacité par défaut de 1 024
mesurée à 500 employés et configurable : voir
[Chargement à froid](COLD-DASHBOARD-PERFORMANCE.md). Les caches de fichiers
restent distincts; valeur/dépendances/compteur d'accès sont évincés ensemble.

## Synchronisation entre processus

Le format sync existant conserve `version`, `changeId`, category/resource,
epoch et révisions par employé. Deux champs internes **additifs** sont publiés :

```json
{
  "dependencySchemaVersion": 1,
  "sourceRevisions": {
    "employee": "<identifiant de dernière modification>",
    "project": "<identifiant de dernière modification>",
    "auth": "<identifiant de dernière modification>"
  }
}
```

Ce vecteur conserve les dernières révisions de toutes les catégories connues.
Si trois employés puis un ticket changent entre deux lectures, le lecteur
compare toutes les révisions employé ET toutes les catégories, pas seulement
la dernière catégorie. Le DTO public `/sync/status` reste limité à cinq champs.
Les anciens lecteurs ignorent ces champs; un ancien éditeur qui les retire
déclenche le chemin prudent lors des notifications manquées.

Une version reculée, une epoch différente, un format inconnu, des révisions
malformées ou des contenus contradictoires sous une même identité déclenchent
une invalidation conservatrice. Une observation inchangée est réutilisée sans
revalider tout le vecteur à chaque hit. Le fingerprint exclut le timestamp
descriptif, dont PowerShell 7 peut changer la représentation string/DateTime.

### Commit réussi, publication ratée

Il ne s'agit pas d'une transaction distribuée. Le commit métier et sync
restent séparés; une interruption entre les deux reste possible.

1. FileStore invalide immédiatement les modèles locaux dépendants après un
   commit, sans remplacer la lecture fraîche sous verrou ni publier plusieurs
   changements par entrée.
2. Login, logout et révocation publient une catégorie `sessions` après le
   verrou. Une publication échouée émet un avertissement, pas une erreur de
   login/logout qui ferait répéter une mutation déjà réussie.
3. Le helper de backfill salarial publie par défaut. Les routes qui publient
   déjà leur transaction demandent explicitement `-DeferPublication`.
4. Les métadonnées des sources chargées sont réconciliées périodiquement,
   selon l'intervalle FileStore existant (30 secondes par défaut). Des stamps
   indépendants subsistent même si une écriture a vidé le cache FileStore.
5. Toutes les cinq minutes, les contenus sont forcés frais : cela couvre une
   édition externe conservant à la fois la taille et le timestamp, ainsi que
   les fichiers absents recréés hors protocole.
6. Une transition erreur de lecture sync / reconnexion invalide les modèles
   et caches de sources de façon prudente, même si la révision n'a pas changé.

Ces échéances sont contrôlées **à la prochaine requête**, pas par un nouveau
thread de fond. Une panne peut différer la relecture jusqu'au rétablissement
du partage. Les contrôles metadata/auth existants restent actifs. La révocation
est vérifiée côté backend sur les requêtes protégées, pas par le frontend.

Sans publication réussie, il n'y a pas de garantie de rafraîchissement immédiat
d'un écran déjà affiché : la réconciliation rend la prochaine lecture correcte,
mais n'invente pas une révision globale pour forcer le navigateur. Les warnings
post-commit existants et la possibilité de recharger restent importants.

Le patch frontend se limite au routage de la nouvelle catégorie `sessions` :
un poll authentifié ne marque pas les vues métier périmées pour un simple login
d'un collègue. Les changements `auth` et les gaps gardent le comportement
conservateur existant. Aucun changement de mise en page ni de polling.

## Fichiers modifiés

| Fichier | Rôle |
| --- | --- |
| `services/ReadModelCacheService.ps1` (nouveau) | Registre, propagation transitive, éviction, vecteur de catégories, réconciliation. |
| `services/EmployeeContributionService.ps1` (nouveau) | Contributions employé, portée et statistiques Personnel. |
| `services/ReadModelService.ps1` | Déclarations de sources, synchronisation ciblée, assemblage incrémental, séparation de l'historique. |
| `services/EmployeeDirectoryService.ps1` | Réutilisation des statistiques dans le chemin caché; chemin explicitement uncached conservé. |
| `services/SyncService.ps1` | Vecteur cumulatif additif, catégorie sessions, état d'échec de lecture observable. |
| `services/AuthService.ps1` | Publication de création/révocation de sessions, avertissement post-commit. |
| `services/OvertimeCostSnapshotService.ps1` et routes profil | Publication des backfills et coalescence avec les routes normales. |
| `services/ProjectMutationService.ps1` | Retrait de la purge générale locale au profit des dépendances projets/historique. |
| `lib/FileStore.ps1` | Notification locale après commit; aucun changement de verrou/retry/replace. |
| `frontend/scripts/AppShell.js` | Compatibilité de l'événement sessions, sans nouveau chargement métier inutile. |
| `scripts/audit-smb-performance.ps1` | Mode répété à deux serveurs HTTP, baseline alternative, médiane/p95 et compteurs. |
| Tests cache nouveaux / contrats existants | Isolation des fixtures, cache/mutations/sécurité/failures; contrats sync additifs mis à jour. |

La configuration SMB et les traces de l'audit précédent étaient déjà présentes
dans l'arbre de travail. Les fichiers DATA locaux modifiés avant cette tâche
n'ont pas été remis à zéro, déplacés ni utilisés comme fixtures d'écriture.

## Validation

Deux tests ciblés ajoutés : `test-dependency-cache-registry.ps1` et
`test-dependency-read-models.ps1`, avec fixtures/worker isolés. Ils vérifient :

- Propagation des dépendances sur hits, sources indépendantes, registre borné,
  cleanup d'une factory échouée, vecteurs malformés/legacy.
- Écritures depuis un autre processus : modification, ajout, approbation,
  rejet, réaffectation et suppression; projections égales à une reconstruction.
- Statistiques de projets/Personnel, collaborateurs inchangés, tickets/grille,
  suppression/restauration d'employé et scopes de permissions.
- Révocation distante, désactivation sans publication, publication de révocation
  injectée en échec, commit non publié, édition externe à métadonnées identiques,
  panne/reconnexion avec la même révision.

La suite complète sélectionne 126 tests, tous passants sur ce Mac. Deux tests
Windows ont un skip interne, comptabilisé comme succès par le runner existant.
Les contrats HTTP limitent toujours précisément les fichiers et propriétés
modifiés. Les tests FileStore multiprocess conservent leurs 80 transactions
sans perte. Les tests Windows spécifiques restent non exécutés sur ce Mac;
le scan de compatibilité PowerShell 5.1 ne remplace pas leur exécution Windows.

## Mesures de performance

Le mode de mesure utilise deux vrais backends HTTP avec leurs propres caches,
32 employés/128 entrées fictifs, dix lectures par scénario, la même machine et
le même harness avant/après. Les mutations sont réalisées par le deuxième
backend. Le TTL sync est fixé à 1 seconde dans le benchmark, avec une attente
de 1,1 seconde avant la lecture mesurée : la détection est comprise dans le
temps. Le TTL normal de l'application reste inchangé. Traces actives dans les
deux versions; coûts de démarrage et d'écriture exclus du temps de lecture.

Les mesures SMB sont exécutées depuis ce Mac sur le partage Windows
`192.168.2.17`, monté dans `/Volumes/OvertimeTest/data`. Elles reproduisent une
latence réseau, sans prédire les temps du disque partagé au travail. Les caches
SMB/Windows ne sont pas purgés. Les deux versions sont mesurées successivement;
aucune suite de tests n'est exécutée en parallèle.

### Comparatif SMB mesuré

Rapports complets : `output/cache-coherence-smb-before.json` et
`output/cache-coherence-smb-after.json` (ignorés par Git). Dix observations par
scénario et par version, 100 lectures mesurées au total. Les temps ci-dessous
sont les temps de traitement serveur, détection sync incluse; les durées HTTP
côté client figurent également dans les rapports.

| Scénario | Médiane avant → après | p95 avant → après | Contributions avant → après |
| --- | ---: | ---: | ---: |
| A. Chaud, inchangé | 4,0 → 4,4 ms | 6,8 → 16,2 ms | 0 → 0 |
| B. Un employé modifié | 617,0 → 375,1 ms | 1 511,9 → 682,0 ms | 32 → 1 |
| C. Trois employés entre lectures | 1 215,1 → 614,4 ms | 1 559,4 → 1 357,8 ms | 32 → 3 |
| D. Ticket modifié | 507,6 → 240,4 ms | 778,4 → 635,9 ms | 32 → 0 |
| E. Changement de rôle | 901,6 → 916,4 ms | 1 166,3 → 1 482,9 ms | 32 → 32 |

Les médianes B/C/D baissent respectivement de **39 %, 49 % et 53 %**.
Les dix lectures de chaque scénario A–D ne reconstruisent jamais toutes les
contributions après le patch; les dix lectures E les reconstruisent toutes,
comme prévu pour un changement de droits. A ne fait aucun appel réseau
supplémentaire : zéro métadonnée et zéro lecture dans les deux versions.
Sa médiane augmente de 0,4 ms. Le changement de droits n'est pas optimisé :
médiane +1,6 %, et p95 plus élevé, notamment pendant les validations périodiques.

| Scénario | Métadonnées par lecture avant → après (min–max) | Lectures de fichiers avant → après |
| --- | ---: | ---: |
| A | 0 → 0 | 0 → 0 |
| B | 5–30 → 5–43 | 3 → 3 |
| C | 13–34 → 7–46 | 9 → 5–6 |
| D | 4–25 → 4–42 | 2 → 2 |
| E | 10–31 → 10–49 | 6 → 6–7 |

Les compteurs hits/misses et modèles invalidés sont les mêmes que dans le
tableau de compteurs ci-dessous. Les contrôles périodiques metadata/auth
peuvent ajouter des appels et une lecture supplémentaire; aucun de ces
échantillons n'est écarté. Cela limite particulièrement l'amélioration du p95
de C. Les maxima plus élevés de metadata après sont aussi le coût mesuré du
filet de sécurité pour les commits non publiés, pas seulement des changements
observés via sync.

**La cible de moins de 200 ms sur SMB n'est pas atteinte.** B conserve trois
lectures (sync, employé, historique) et normalement cinq contrôles metadata.
La médiane du temps cumulé des trois appels `Read-TextFileWithRetry` est
240,9 ms; celle des appels `Get-FileItemWithRetry` est 58,5 ms. Ces appels
séquentiels restent le principal coût mesuré après réutilisation des
contributions. Les autres durées de fonctions sont imbriquées : ne pas les
additionner pour calculer un temps total ou un pourcentage CPU.

Ce comparatif montre un gain réel, sans promettre la même latence sur le
réseau du travail. Réduire encore les lectures/validations réseau nécessiterait
un chantier distinct, en conservant le secours aux publications ratées.
Les observations à froid et les mutations sont enregistrées, mais aucun gain
sur ces parcours n'est revendiqué par cette implémentation.

Les empreintes SHA-256 des **45 fichiers JSON existants** à la racine DATA
sont identiques avant/après. Les sous-dossiers synthétiques des deux versions
sont supprimés; aucun dossier `saphir-audit-*` ne reste sur le partage.

### Comparatif sur disque local

Les rapports complets sont sous `output/cache-coherence-local-before.json` et
`output/cache-coherence-local-after.json` (ignorés par Git). La baseline est une
copie du runtime avant cette implémentation, avec les traces de l'audit.
Elle est conservée localement dans `output/cache-coherence-baseline/app`.
Les chiffres de l'ancien audit SMB (~730 ms) ne sont pas une baseline comparable
à ces temps locaux.

| Scénario | Médiane avant → après | p95 avant → après | Contributions avant → après |
| --- | ---: | ---: | ---: |
| A. Chaud, inchangé | 6,9 → 9,0 ms | 14,8 → 16,4 ms | 0 → 0 |
| B. Un employé modifié | 322,6 → 78,1 ms | 571,6 → 177,3 ms | 32 → 1 |
| C. Trois employés entre lectures | 332,3 → 103,2 ms | 370,0 → 118,5 ms | 32 → 3 |
| D. Ticket modifié | 307,1 → 32,9 ms | 346,5 → 38,1 ms | 32 → 0 |
| E. Changement de rôle | 335,1 → 374,4 ms | 374,5 → 407,2 ms | 32 → 32 |

B réduit la médiane locale d'environ 76 %, **sans diminuer ses I/O** :
toujours cinq métadonnées et trois lectures (employé, sync, historique).
Le gain y vient de la réutilisation des projections. C passe généralement de
13 métadonnées/9 lectures à 7/5. Les validations périodiques peuvent augmenter
ces comptes : 41 métadonnées sur un C avant, 42 sur un D après, 39 sur un E
après. Ces pics sont conservés dans les rapports.

Compteurs après par lecture hors changements périodiques supplémentaires :

| Scénario | Hits / misses de modèles | Modèles invalidés | Contributions reconstruites |
| --- | ---: | ---: | ---: |
| A | 2 / 0 | 0 | 0 |
| B | 62 / 7 | 7 | 1 |
| C | 58 / 11 | 11 | 3 |
| D | 1 / 2 | 2 (historique) | 0 |
| E | 0 / 69 | 69 | 32 |

Il n'y a aucune reconstruction complète des contributions sur A–D après;
chaque E reconstruit toutes les contributions. Le coût supplémentaire du
registre/des factories lors des changements de droits (~39 ms de médiane
ici) est assumé et mesuré, pas masqué. Le chemin chaud prend environ 2 ms de
plus, sans métadonnée ni lecture partagée supplémentaire. Pas de gain annoncé
sur le démarrage à froid.

Les compteurs sont des tentatives d'API fichiers, pas des paquets SMB.
Les réconciliations périodiques restent dans les échantillons, sans exclusion
des passages plus coûteux. Le p95 avec dix observations est le maximum
observé, pas une estimation robuste en production.

Les contributions avant sont comptées via les appels de chargement employé
pendant la reconstruction; après, le compteur dédié mesure réellement les
factories recomputées. Les modèles invalidés n'étaient pas comptés dans la
baseline : seule la valeur après est instrumentée. Une « reconstruction
complète » signifie recalcul de toutes les contributions, pas assemblage/tri
des contributions déjà cachées.

## Limites et suites volontairement différées

- L'auth/directory, les epochs et les changements ambigus peuvent reconstruire
  toutes les projections. La sécurité passe avant un gain sur ces événements.
- L'expiration du contenu force une réconciliation large toutes les cinq
  minutes; les validations metadata périodiques restent visibles sur SMB.
- Tri, concaténation et agrégations par filtre parcourent encore des entrées en
  mémoire. Pas de delta arithmétique pour les montants, minimums ou tris.
- Les anciens clients et scripts externes restent couverts par fallback, pas
  par une garantie de publication transactionnelle universelle.
- Pas de migration de datastore, outbox distribuée, runspaces HTTP ou chantier
  cold-start. Les caches restent non thread-safe.
- Aucun commit/push ni changement de release n'est inclus dans cette demande.

Pour reproduire le comparatif SMB :

```powershell
pwsh -NoProfile -File scripts/audit-smb-performance.ps1 `
  -NetworkDataFolder /Volumes/OvertimeTest/data `
  -ApplicationRoot output/cache-coherence-baseline/app `
  -CoherenceIterations 10 -ReportPath output/cache-coherence-smb-before.json

pwsh -NoProfile -File scripts/audit-smb-performance.ps1 `
  -NetworkDataFolder /Volumes/OvertimeTest/data `
  -CoherenceIterations 10 -ReportPath output/cache-coherence-smb-after.json
```

Pour comparer, utiliser aussi `-ApplicationRoot <copie-de-la-baseline>/app`
avec le même partage et les mêmes paramètres. Le harness crée et nettoie ses
sous-dossiers UUID; il ne modifie pas les données existantes à la racine DATA.
