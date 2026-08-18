# Validation de SAPHIR

La phase 0 fournit un filet de sécurité commun avant les refactorisations. Elle
ne modifie ni le format DATA ni les règles métier. Les tests qui effectuent des
écritures utilisent toujours un dossier temporaire propre à leur exécution.

## Commande complète

Depuis la racine du dépôt :

```powershell
./scripts/test-all.ps1
```

Sous Windows PowerShell 5.1 :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-all.ps1
```

Le lanceur exécute, dans le même ordre que la CI :

1. l'audit de compatibilité Windows PowerShell 5.1;
2. tous les tests PowerShell trouvés récursivement sous `tests/powershell`;
3. tous les tests JavaScript trouvés récursivement sous `tests/frontend`, avec Node.js.

`scripts/test-all.ps1` est l’unique commande de la suite. Les helpers propres
aux tests vivent sous `tests/lib` et les données de référence sous
`tests/fixtures`; aucun nouveau fichier `test-*.ps1` ou `test-*.js` ne doit être
ajouté sous `scripts`.

Il retourne un code d'échec si un test échoue ou n'a pas pu être exécuté.
Les tests qui démarrent un serveur ou des processus enfants réutilisent la même
édition de PowerShell que le lanceur : Windows PowerShell 5.1 dans la CI Windows
et `pwsh` lors d'une exécution locale sous PowerShell 7. La CI ne peut donc pas
masquer un problème 5.1 en lançant silencieusement le serveur avec PowerShell 7.

## Exécutions ciblées

Lister les tests sans les exécuter :

```powershell
./scripts/test-all.ps1 -List
```

Exécuter uniquement certains contrats :

```powershell
./scripts/test-all.ps1 -Filter "*phase0*", "*data-contract*"
```

Exécuter une catégorie :

```powershell
./scripts/test-all.ps1 -Category PowerShell
./scripts/test-all.ps1 -Category JavaScript
```

Arrêter au premier échec et conserver un rapport JSON :

```powershell
./scripts/test-all.ps1 -FailFast -ReportPath ./output/test-reports/phase0-local.json
```

Ajouter la baseline synthétique de performance :

```powershell
./scripts/test-all.ps1 -IncludeBenchmark -ReportPath ./output/test-reports/phase0-baseline.json
```

La baseline mesure les durées médianes/p95 ainsi que le nombre de lectures,
d'analyses JSON et d'écritures. Elle n'importe pas la configuration de
l'application et travaille dans un répertoire temporaire unique.

## Contrat de topologie

La suite protège également la structure de source et le contenu livré :

- l’unique application de production se trouve sous `app/backend` et
  `app/frontend`;
- les points d’entrée sont `app/backend/saphir-server.ps1`,
  `app/backend/saphir-config.psd1` et `app/backend/lib/AppContext.ps1`;
- aucun arbre d’application employé séparé ne peut réapparaître;
- les sources des lanceurs restent sous `deploy/bootstrap`, alors que le paquet
  les publie à la racine de `SAPHIR-Distribution`;
- une release nouvellement produite contient la topologie canonique et aucun
  dossier DATA;
- le résolveur du lanceur reconnaît encore une fixture de release historique
  pour permettre le retour arrière, sans autoriser cette structure comme source
  d’une nouvelle release.

Cette compatibilité historique doit rester testée tant que des postes peuvent
encore posséder une ancienne release sous `%LOCALAPPDATA%\SAPHIR\versions`.

## Données de référence

Les fixtures suivies se trouvent dans
`tests/fixtures/data-contract/reference-v1`. Elles couvrent :

- un employé sans entrée;
- un employé avec exactement une entrée;
- plusieurs entrées;
- une entrée active;
- un singleton JSON legacy sans les propriétés optionnelles récentes;
- un projet actif et un projet archivé.

Les fixtures sont immuables. Un test doit les copier vers un dossier temporaire
avant de démarrer SAPHIR ou d'effectuer une mutation.

## Contrats protégés

Le test HTTP de phase 0 démarre une copie temporaire du serveur et vérifie :

- authentification valide et invalide;
- protection du dashboard;
- forme du bootstrap dashboard;
- lecture d'un employé, incluant le tableau à une seule entrée;
- ajout manuel et approbation par `entryId`;
- statuts HTTP et propriétés essentielles des réponses;
- fichiers et chemins JSON autorisés pour chaque mutation.

Une lecture doit laisser DATA strictement inchangé. Une écriture échoue au test
si elle crée, supprime ou modifie un fichier ou une propriété non autorisée.

## Ce que la phase 0 ne remplace pas

La suite locale simule les erreurs de partage et la concurrence, mais elle ne
peut pas reproduire parfaitement un vrai serveur SMB. Avant une livraison au
département, il faut toujours :

1. laisser la CI Windows terminer avec succès;
2. tester le paquet sur une copie du DATA réel;
3. utiliser au moins deux postes Windows contre le même partage de test;
4. tester une coupure réseau et des écritures concurrentes;
5. conserver le paquet précédent et une sauvegarde pour le retour arrière;
6. pour la première release canonique seulement, publier d’abord
   `-BootstrapOnly`, faire réinstaller le raccourci, puis publier la release;
7. vérifier sur le poste pilote qu’une release canonique démarre et que le
   lanceur mis à jour peut encore sélectionner la release précédente.
