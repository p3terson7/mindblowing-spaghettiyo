# SAPHIR — démarrage rapide

## Première utilisation

1. Ouvrez le dossier partagé `SAPHIR-Distribution` sur le réseau.
2. Supprimez l’ancien raccourci de l’application de votre Bureau, s’il existe.
3. Double-cliquez une fois sur `Install SAPHIR Shortcut.vbs`. Il crée le raccourci **SAPHIR** avec le logo bleu sur votre Bureau; aucun droit administrateur n’est requis.
4. Ne copiez et ne déplacez aucun fichier du dossier réseau. Le raccourci doit continuer à pointer vers ce dossier.
5. Double-cliquez une seule fois sur le nouveau raccourci **SAPHIR**, puis attendez. La fenêtre de démarrage est volontairement masquée.
6. Au premier démarrage, SAPHIR télécharge automatiquement sa copie dans `%LOCALAPPDATA%\SAPHIR`. Cela peut prendre un peu de temps; les démarrages suivants seront beaucoup plus rapides.
7. Lorsque le navigateur s’ouvre, connectez-vous normalement.

Les mises à jour sont installées automatiquement au prochain démarrage. Aucune installation manuelle n’est nécessaire.
Le raccourci **SAPHIR** arrête automatiquement toute ancienne instance SAPHIR vérifiée sur votre ordinateur avant de lancer la version courante. Il n'est normalement pas nécessaire d'exécuter **Stop SAPHIR** séparément.

## En cas de problème

1. Vérifiez que vous êtes connecté au réseau du ministère.
2. Relancez votre raccourci **SAPHIR**; il redémarre automatiquement le serveur local.
3. Si les scripts VBS sont bloqués sur votre poste, créez plutôt un raccourci vers `Launch SAPHIR.bat` (type **Fichier de commandes Windows**). Ce raccourci de secours n’aura peut-être pas le logo personnalisé. La colonne **Type** permet de distinguer les fichiers si Windows masque leurs extensions.
4. Si le problème continue, exécutez `Stop SAPHIR.bat`, puis relancez **Launch SAPHIR.bat** afin de voir le message d'erreur.
5. Transmettez au soutien le dossier de journaux suivant : `%LOCALAPPDATA%\SAPHIR\runtime\logs`.

Fermer le navigateur ne ferme pas nécessairement le petit serveur SAPHIR local. Ce comportement est normal.

---

# SAPHIR — quick start

## First use

1. Open the shared `SAPHIR-Distribution` network folder.
2. Delete the application's old Desktop shortcut, if one exists.
3. Double-click `Install SAPHIR Shortcut.vbs` once. It creates a **SAPHIR** Desktop shortcut with the blue logo; administrator rights are not required.
4. Do not copy or move any file from the network folder. The shortcut must continue pointing to that folder.
5. Double-click the new **SAPHIR** shortcut once, then wait. The startup window is intentionally hidden.
6. On the first start, SAPHIR automatically downloads its copy to `%LOCALAPPDATA%\SAPHIR`. This may take a little while; later starts will be much faster.
7. Sign in normally when the browser opens.

Updates install automatically the next time SAPHIR starts. No manual installation is required.
The **SAPHIR** shortcut automatically stops any verified older SAPHIR instance on your computer before starting the current version. You normally do not need to run **Stop SAPHIR** separately.

## If SAPHIR does not start

1. Confirm that you are connected to the department network.
2. Open your **SAPHIR** shortcut again; it automatically restarts the local server.
3. If VBS files are blocked on your computer, create a shortcut to `Launch SAPHIR.bat` (type **Windows Batch File**) instead. This fallback shortcut may not show the custom logo. Use the **Type** column to distinguish files if Windows hides extensions.
4. If the problem continues, run `Stop SAPHIR.bat`, then run **Launch SAPHIR.bat** so the error remains visible.
5. Give support this log-folder location: `%LOCALAPPDATA%\SAPHIR\runtime\logs`.

Closing the browser does not necessarily stop the small local SAPHIR server. This is normal.
