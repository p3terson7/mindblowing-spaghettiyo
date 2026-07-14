# GÉEM — démarrage rapide

## Première utilisation

1. Ouvrez le dossier GÉEM de votre département sur le réseau.
2. Faites un clic droit sur `Launch GEEM.vbs` (type **Fichier de script VBScript**), puis choisissez **Envoyer vers > Bureau (créer un raccourci)**. Sous Windows 11, choisissez d'abord **Afficher plus d'options** si **Envoyer vers** n'apparaît pas.
3. Ne copiez pas et ne déplacez pas le fichier `Launch GEEM.vbs` lui-même. Le raccourci doit continuer à pointer vers le dossier réseau.
4. Double-cliquez une seule fois sur le raccourci **Launch GEEM** créé sur votre bureau, puis attendez. La fenêtre de démarrage est volontairement masquée.
5. Au premier démarrage, GÉEM télécharge automatiquement sa copie locale. Cela peut prendre un peu de temps; les démarrages suivants seront plus rapides.
6. Lorsque le navigateur s’ouvre, connectez-vous normalement.

Les mises à jour sont installées automatiquement au prochain démarrage. Aucune installation manuelle n’est nécessaire.
Le raccourci **Launch GEEM** arrête automatiquement toute ancienne instance GÉEM vérifiée sur votre ordinateur avant de lancer la version courante. Il n'est normalement pas nécessaire d'exécuter **Stop GEEM** séparément.

## En cas de problème

1. Vérifiez que vous êtes connecté au réseau du ministère.
2. Relancez votre raccourci **Launch GEEM**; il redémarre automatiquement le serveur local.
3. Si les scripts VBS sont bloqués sur votre poste, créez plutôt un raccourci vers `Launch GEEM.bat` (type **Fichier de commandes Windows**). La colonne **Type** permet de distinguer les deux fichiers si Windows masque leurs extensions.
4. Si le problème continue, exécutez `Stop GEEM.bat`, puis relancez **Launch GEEM.bat** afin de voir le message d'erreur.
5. Transmettez au soutien le dossier de journaux suivant : `%LOCALAPPDATA%\OvertimeManager\runtime\logs`.

Fermer le navigateur ne ferme pas nécessairement le petit serveur GÉEM local. Ce comportement est normal.

---

# GEEM — quick start

## First use

1. Open your department’s shared GEEM network folder.
2. Right-click `Launch GEEM.vbs` (type **VBScript Script File**), then select **Send to > Desktop (create shortcut)**. On Windows 11, first select **Show more options** if **Send to** is hidden.
3. Do not copy or move `Launch GEEM.vbs` itself. The shortcut must continue pointing to the network folder.
4. Double-click the **Launch GEEM** shortcut once, then wait. The startup window is intentionally hidden.
5. On the first start, GEEM automatically downloads its local copy. This may take a little while; later starts will be faster.
6. Sign in normally when the browser opens.

Updates install automatically the next time GEEM starts. No manual installation is required.
The **Launch GEEM** shortcut automatically stops any verified older GEEM instance on your computer before starting the current version. You normally do not need to run **Stop GEEM** separately.

## If GEEM does not start

1. Confirm that you are connected to the department network.
2. Open your **Launch GEEM** shortcut again; it automatically restarts the local server.
3. If VBS files are blocked on your computer, create a shortcut to `Launch GEEM.bat` (type **Windows Batch File**) instead. Use the **Type** column to distinguish the two files if Windows hides extensions.
4. If the problem continues, run `Stop GEEM.bat`, then run **Launch GEEM.bat** so the error remains visible.
5. Give support this log-folder location: `%LOCALAPPDATA%\OvertimeManager\runtime\logs`.

Closing the browser does not necessarily stop the small local GEEM server. This is normal.
