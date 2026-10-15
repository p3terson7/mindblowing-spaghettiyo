# Contrat des signalements

Ce document décrit le contrat des signalements livré jusqu’à la phase 5 : base
backend, interface de suivi, captures d’écran, triage et discussion.

## Stockage partagé

Les signalements sont conservés dans `bug-reports.json`, à côté des autres
fichiers du dossier DATA partagé. Il s’agit d’un fichier secondaire indépendant
des heures, des employés et des projets. Son ajout ne change donc pas la version
du schéma des données métier et ne réécrit aucun fichier existant.

Chaque écriture utilise le verrou interprocessus et le remplacement atomique de
`FileStore.ps1`. Une publication de synchronisation de catégorie `bug-reports`
rafraîchit seulement ce fichier et l’historique sur les autres postes; les gros
fichiers d’heures demeurent en cache.

## Structure d’un signalement

Un enregistrement de schéma 1 contient notamment :

- `reportId`, identifiant immuable `bug-` suivi de 32 caractères hexadécimaux;
- `revision`, entier augmenté après chaque modification;
- `title`, `description`, `category`, ainsi que les champs facultatifs de
  reproduction, résultat attendu et résultat observé;
- `technicalContext`, réservé à la version, la page, le navigateur, le système
  et la langue;
- `status`, `priority`, `rank` et `assignedTo` pour le triage;
- `createdBy`, `createdAtUtc` et `updatedAtUtc`;
- `attachments`, `comments` et `history`.

Les images ne sont jamais encodées en base64 dans le JSON. Elles sont conservées
dans `bug-report-attachments/{reportId}` et seules leurs métadonnées se trouvent
dans `attachments` : identifiant, nom original nettoyé, type détecté, taille,
empreinte SHA-256, auteur et date. Les chemins absolus du disque partagé ne sont
jamais exposés au client.

Le serveur vérifie la signature réelle du fichier plutôt que de faire confiance
à son extension. Seuls PNG, JPEG, GIF et WebP sont permis, avec une limite de
8 Mo par image et de 5 images par signalement. Le SVG est volontairement refusé
pour éviter l’exécution de contenu actif.

Valeurs reconnues :

- catégories : `bug`, `performance`, `visual`, `data`, `suggestion`, `other`;
- statuts : `new`, `acknowledged`, `inProgress`, `waitingForUser`, `resolved`,
  `closed`;
- priorités : `unranked`, `p1`, `p2`, `p3`, `p4`.

## Permissions

- Un employé voit uniquement les signalements qu’il a créés. Il peut corriger
  leur contenu tant qu’ils sont encore au statut `new`.
- Un admin voit tous les signalements, mais ne peut pas modifier le triage.
- Un super admin voit tous les signalements et peut modifier contenu, statut,
  priorité, rang et assignation.
- Le rapporteur peut ajouter des captures tant que le signalement est `new`.
  Un super admin peut en ajouter pendant le triage; un admin régulier demeure
  en lecture seule.
- Une demande faite par un employé pour le signalement d’un collègue répond
  `404`, afin de ne pas confirmer l’existence d’un dossier privé.

## Concurrence

Toute modification envoie `expectedRevision`. Si le fichier contient déjà une
autre révision, le serveur répond `409 Conflict` et ne modifie aucun octet. Le
client devra alors recharger le signalement avant de proposer une nouvelle
sauvegarde. Les changements réussis ajoutent un événement horodaté à `history`.

## Triage de la phase 4

Le panneau de triage apparaît uniquement pour un super admin. Il permet de
modifier le statut, la priorité P1 à P4, l’assignation et l’ordre dans une même
priorité. La valeur `rank` est un entier positif ou nul; les plus petites valeurs
sont affichées en premier. La priorité demeure le premier critère de classement,
donc une P1 passe toujours avant une P2, peu importe son rang.

Les admins réguliers peuvent voir l’assignation et le rang, mais ne peuvent pas
les changer. Tous les utilisateurs autorisés à voir un signalement voient aussi
son activité : création, ajout de capture et changements. Le nom de l’acteur et
l’heure sont conservés dans chaque événement. Un triage basé sur une ancienne
révision reçoit `409`; l’interface recharge alors automatiquement la version la
plus récente plutôt que d’écraser le travail fait sur un autre poste.

## Discussion de la phase 5

Toute personne qui peut voir un signalement peut participer à sa discussion :
le rapporteur, un admin ou un super admin. Chaque commentaire conserve un
identifiant immuable, son texte, un instantané de l’auteur et sa date UTC. Les
commentaires sont limités à 3 000 caractères et à 250 par signalement afin de
garder le fichier partagé raisonnable.

Un signalement `closed` ne reçoit plus de commentaires. Un super admin peut le
rouvrir en changeant son statut avant de poursuivre la discussion. Chaque ajout
incrémente `revision`, ajoute un événement `commentAdded` à l’activité et publie
une synchronisation ciblée. Une réponse basée sur une ancienne révision reçoit
`409` et l’interface recharge automatiquement le fil récent.

## API jusqu’à la phase 5

- `GET /bug-reports` : retourne une liste résumée. Les filtres `scope`,
  `status`, `priority` et `category` sont facultatifs.
- `POST /bug-reports` : crée un signalement au statut `new`.
- `GET /bug-reports/{reportId}` : retourne le détail autorisé.
- `PATCH /bug-reports/{reportId}` : modifie les champs autorisés et exige
  `expectedRevision`.
- `POST /bug-reports/{reportId}/attachments` : téléverse les octets bruts de
  l’image. Les en-têtes `X-SAPHIR-Expected-Revision` et `X-SAPHIR-File-Name`
  portent respectivement la révision et le nom encodé.
- `GET /bug-reports/{reportId}/attachments/{attachmentId}` : retourne une image
  seulement si l’utilisateur peut voir le signalement parent.
- `POST /bug-reports/{reportId}/comments` : ajoute un commentaire avec `body` et
  `expectedRevision`. Le détail retourné contient immédiatement le fil à jour.

La liste n’inclut pas la description complète, les commentaires, les pièces
jointes ni l’historique. Ces champs sont chargés seulement à l’ouverture du
détail afin de garder la future page rapide sur le réseau partagé.
