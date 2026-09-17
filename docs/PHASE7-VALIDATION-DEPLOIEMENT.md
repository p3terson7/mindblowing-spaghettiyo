# Phase 7 — validation et déploiement progressif

Cette étape sert à vérifier les phases 0 à 6 ensemble et à préparer une livraison
testable. Une suite locale réussie ne confirme pas encore le comportement sur
les postes Windows du département. Les essais Windows et SMB ci-dessous restent
à faire sur place; aucune publication en production n'est effectuée par les tests.

État du candidat local du 17 septembre 2026 : la suite complète réussit avec
110 tests sur 110 et son rapport se trouve dans
`output/test-reports/phase7-local.json`. Les deux tests d'exécution propres à
Windows se déclarent ignorés à l'intérieur de leur scénario sur macOS; les
contrôles statiques du lanceur réussissent. Ce résultat ne remplace donc pas le
pilote Windows/SMB décrit plus bas.

## 1. Garder une preuve des tests

Depuis la racine du dépôt, avec PowerShell 7 pour la validation locale :

```powershell
pwsh -NoLogo -NoProfile -File ./scripts/test-all.ps1 `
  -ReportPath ./output/test-reports/phase7-local.json
```

Sur le poste de validation Windows, avec Node.js disponible pour les tests UI :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-all.ps1 `
  -ReportPath .\output\test-reports\phase7-windows.json
```

Le code de sortie doit être zéro. Garder les rapports avec l'identifiant de la
version, la date et la révision source. Si le dépôt contient des modifications
non commitées, conserver également une copie exacte des sources utilisées :
l'identifiant Git seul ne permet pas de reproduire ce paquet.

La suite couvre notamment les permissions, les calculs, les contrats JSON, les
routes HTTP, le contenu du paquet, l'intégrité SHA-256 et les retours à une
version locale précédente. Les tests de publication vérifient aussi qu'un ID de
version refusé laisse le ZIP, le pointeur et le lanceur existants intacts, et que
la publication ne modifie aucun fichier du DATA de test.

## 2. Fabriquer un candidat local isolé

Ce bloc fonctionne depuis PowerShell à la racine du dépôt. Il crée une cible
DATA vide dans un nouveau dossier temporaire, sans utiliser le DATA du dépôt :

```powershell
$candidateId = 'phase7-local-' + [Guid]::NewGuid().ToString('N')
$candidateRoot = Join-Path ([IO.Path]::GetTempPath()) ('saphir-' + $candidateId)
$candidateData = Join-Path $candidateRoot 'data-test'
$candidateOutput = Join-Path $candidateRoot 'distribution'
New-Item -ItemType Directory -Path $candidateData -ErrorAction Stop | Out-Null
$candidate = & ./scripts/package-app.ps1 `
  -OutputRoot $candidateOutput -DataFolderPath $candidateData `
  -ReleaseId $candidateId -AllowLocalDataPath -NoZip
$candidate

$pointerPath = Join-Path $candidate.DistributionFolder 'deployment/current.json'
$pointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
$archivePath = Join-Path $candidate.DistributionFolder $pointer.packagePath
$actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
if ($actualHash -ne $pointer.sha256) { throw 'Le SHA-256 ne correspond pas.' }
if ($pointer.dataFolderPath -ne $candidateData) { throw 'Mauvaise cible DATA.' }
```

Ce candidat vérifie la construction et le contenu livré; son DATA vide ne sert
pas de pilote métier. `-AllowLocalDataPath` reste réservé à ces essais locaux.
`-NoZip` supprime seulement le ZIP extérieur facultatif : le ZIP de l'application
est toujours créé dans `deployment/releases`.

Un paquet contient son chemin DATA dans sa configuration. Le paquet local ne
doit donc pas être copié tel quel en production. Les builds ne sont pas garantis
identiques octet pour octet : garder le ZIP exact et son SHA-256, et employer un
nouvel identifiant pour toute nouvelle construction.

## 3. Préparer le pilote sur le partage Windows

1. Choisir un dossier de distribution pilote distinct et un DATA de test
   distinct. Utiliser des données fictives représentatives ou une copie du DATA
   obtenue par la procédure de sauvegarde ci-dessous, avec les mêmes restrictions
   d'accès que l'original.
2. Utiliser au moins deux postes ou profils Windows de test. Le raccourci, le
   lanceur et le cache `%LOCALAPPDATA%\SAPHIR` sont communs à un même profil :
   deux raccourcis ne créent pas deux environnements isolés. Arrêter SAPHIR avant
   de changer de distribution sur un profil.
3. Depuis les sources validées, publier uniquement vers les chemins pilotes
   choisis. Remplacer les exemples avant d'exécuter la commande :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\package-app.ps1 `
  -OutputRoot '\\serveur\departement\SAPHIR-Pilote' `
  -DataFolderPath '\\serveur\departement\SAPHIR-DATA-Pilote' `
  -ReleaseId 'phase7-pilote-01' -NoZip
```

4. Vérifier `deployment/current.json` et le SHA-256 comme dans le bloc précédent.
   Un ZIP déposé seul dans `releases` n'est pas une mise à jour : le lanceur suit
   `current.json`.
5. Lancer `Installer SAPHIR sur le Bureau.vbs` depuis la distribution pilote,
   puis **Update and start** ou **Update and restart**. Vérifier la nouvelle
   version dans `%LOCALAPPDATA%\SAPHIR\versions` et la cible DATA dans
   `app\backend\saphir-config.psd1` de cette version.

Si les postes possèdent encore le lanceur historique, appliquer d'abord la
[transition du bootstrap](LOCAL-CACHE-DEPLOYMENT.md#required-two-step-transition-from-an-existing-deployment).
`-BootstrapOnly` met à jour le lanceur partagé; il ne publie aucune application.

## 4. Vérifications manuelles à consigner

Pour chaque ligne, noter le résultat, la date, les postes, les rôles utilisés et
l'ID de release. Toutes ces lignes sont **à valider sur les postes réels**.

| Essai | Résultat attendu |
| --- | --- |
| Installation sans droits administrateur, chemin UNC réel ou lecteur réseau utilisé au travail | Raccourci fonctionnel, interface du lanceur réactive, version installée localement. |
| Première connexion, puis première création/modification | L'action réussit du premier coup et reste présente après rechargement; aucune erreur de mise à jour. |
| Mise à jour depuis la version précédente, navigateur déjà ouvert | Styles et scripts cohérents, changement de version proposé sans demander de vider le cache manuellement. |
| Nom de l'employé et heures | Identité lisible dans les formulaires, durées cohérentes dans Personnel, Révision, dashboard et rapports. |
| Entrée Divers avec et sans privilège | Création autorisée seulement pour l'employé habilité, refus aussi côté serveur. |
| Temps comprimé global, puis création et modification d'entrées | Préférence visible et conservée; chaque entrée garde le régime prévu, les anciennes entrées ne changent pas à cause d'une nouvelle préférence. |
| Groupe, sous-groupe et niveau | `as`, `3`, `1` donnent `AS`, `03`, `01`; lettres/chiffres invalides refusés; champs GC179 corrects. |
| P1–P4 et tranches personnalisées | Dates limites incluses comme prévu, périodes sans données lisibles, totaux identiques aux entrées retenues. |
| Grille salariale | Seul un super admin peut l'ajuster; `01` et l'ancien niveau `1` restent compatibles; les réglages survivent au redémarrage. |
| Deux postes modifient des entrées différentes | Chaque écriture est conservée et devient visible sur l'autre poste. |
| Deux superviseurs modifient la même entrée | Aucun écrasement silencieux; conflit signalé et résolution après actualisation. |
| Coupure du partage pendant une sauvegarde sur DATA de test | Erreur claire, aucun succès affiché à tort, JSON encore lisible, pas de doublon après reconnexion. |
| Partage de distribution indisponible après installation | Lanceur local accessible; état réseau indiqué; vérifier séparément la disponibilité du DATA. |
| Entrées rejetées et À vérifier | Temps rejeté lisible dans la vue concernée, cas moins de 15 minutes/punch-out manquant identifiés. |
| GC179 et rapports | Export/import sur copie de test, notes et attribution conservées, totaux et noms de fichiers corrects. |
| Arrêt, redémarrage, mise à jour et réparation | Une seule instance gérée, aucun autre processus interrompu, DATA inchangé par installation/réparation. |

Conserver les erreurs et horaires précis si un essai échoue. Éviter les essais
de coupure réseau ou de double modification sur des données opérationnelles.

## 5. Sauvegarde et retour arrière

Avant le pilote métier puis avant la publication générale :

- Prévoir une courte fenêtre sans écriture et arrêter **tous** les backends qui
  utilisent le DATA concerné, ou utiliser un instantané cohérent du serveur de
  fichiers. Copier des JSON un à un pendant des modifications ne garantit pas
  une sauvegarde cohérente.
- Sauvegarder le DATA complet, y compris les fichiers de profils, d'historique,
  de schéma, de synchronisation, de grille salariale et de périodes budgétaires.
  Conserver les permissions et une trace de la date/source. Tester sa restauration
  vers un nouveau dossier isolé avant de compter dessus.
- Archiver le ZIP précédent, son `current.json`, les sources/configurations
  correspondantes et le bootstrap validé dans un dossier distinct. La publication
  ne garde que la release courante et deux anciens ZIP sur le partage; cette
  rétention n'est pas une archive durable.

Si une nouvelle version ne démarre pas, le lanceur tente la précédente version
locale lorsqu'elle est disponible. Ce mécanisme ne couvre pas un bug fonctionnel
après démarrage et ne restaure jamais DATA. Un poste neuf n'a pas forcément de
version de secours. Conserver le bootstrap compatible, arrêter la diffusion et
publier une version corrigée avec un nouvel ID.

Pour revenir fonctionnellement à des sources plus anciennes, vérifier leur
compatibilité avec une copie du DATA actuel avant de les republier sous un nouvel
ID. Ne pas modifier `current.json` à la main ni effacer les caches pour forcer
le retour. Restaurer DATA est une opération distincte : arrêter tous les accès,
conserver une copie de l'état en échec, puis faire restaurer la sauvegarde validée
par la personne responsable. Les modifications postérieures à la sauvegarde
doivent être identifiées et réconciliées avant de rouvrir l'application.

## 6. Passage en production

Après la suite Windows et la checklist pilote réussies, publier depuis les mêmes
sources figées avec la commande habituelle, en utilisant le vrai chemin DATA et
un nouvel ID de release. Contrôler le pointeur et le SHA-256, puis faire valider
la première action par un employé et un superviseur avant d'élargir à l'équipe.
Garder la sauvegarde et les archives jusqu'à la fin de cette observation.

Le déploiement reste bloqué si une écriture est perdue/dupliquée, si les totaux
sont faux, si une permission est contournée ou si la première action échoue.
Un rapport local vert, à lui seul, ne valide pas cette étape Windows/SMB.
