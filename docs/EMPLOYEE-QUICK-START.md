# SAPHIR — démarrage rapide

## Première utilisation

1. Ouvrez le dossier partagé `SAPHIR-Distribution` sur le réseau.
2. Supprimez l’ancien raccourci de l’application de votre Bureau, s’il existe.
3. Double-cliquez une fois sur `Installer SAPHIR sur le Bureau.vbs`. Il crée le raccourci **SAPHIR** avec le logo bleu sur votre Bureau; aucun droit administrateur n’est requis.
4. Le lanceur s’ouvre automatiquement après l’installation. S’il est fermé, double-cliquez simplement sur le nouveau raccourci **SAPHIR**.
5. Si l’application est arrêtée, cliquez sur **Mettre à jour et démarrer** si ce bouton est affiché, sinon sur **Démarrer SAPHIR**. Au premier démarrage, SAPHIR copie sa version depuis le réseau interne vers `%LOCALAPPDATA%\SAPHIR`; aucun téléchargement Internet ni droit administrateur n’est nécessaire.
6. Lorsque l’état passe à **En ligne**, cliquez sur **Ouvrir SAPHIR**, puis connectez-vous normalement.

Quand une nouvelle version est disponible, le lanceur affiche **Mettre à jour et démarrer** ou **Mettre à jour et redémarrer**. Il vérifie le téléchargement, conserve la version précédente au cas où la nouvelle ne démarre pas, puis ouvre SAPHIR. **Ouvrir SAPHIR** ouvre seulement le navigateur et ne redémarre pas une instance qui fonctionne déjà. **Arrêter** ferme le serveur SAPHIR local.

## En cas de problème

1. Vérifiez que vous êtes connecté au réseau du ministère.
2. Ouvrez le lanceur et regardez séparément l’état de l’application et celui des données partagées.
3. Cliquez sur **Réparer SAPHIR** si une mise à jour échoue ou si la copie locale semble endommagée. Le lanceur arrête seulement l’instance SAPHIR qu’il peut identifier, retélécharge la version publiée, vérifie son intégrité, puis la redémarre. Vos données partagées ne sont pas supprimées.
4. Si les scripts VBS sont bloqués sur votre poste, créez plutôt un raccourci vers `Launch SAPHIR.bat` (type **Fichier de commandes Windows**). Ce raccourci de secours n’aura peut-être pas le logo personnalisé.
5. Si le problème continue, utilisez **Ouvrir les journaux** dans le lanceur ou exécutez `Stop SAPHIR.bat`, puis `Launch SAPHIR.bat` pour voir le message d’erreur.

Fermer le navigateur ne ferme pas nécessairement le petit serveur SAPHIR local. Ce comportement est normal.

---

# SAPHIR — quick start

## First use

1. Open the shared `SAPHIR-Distribution` network folder.
2. Delete the application's old Desktop shortcut, if one exists.
3. Double-click `Installer SAPHIR sur le Bureau.vbs` once. It creates a **SAPHIR** Desktop shortcut with the blue logo; administrator rights are not required.
4. The launcher opens automatically after installation. If it is closed, simply double-click the new **SAPHIR** shortcut.
5. If the application is stopped, select **Update and start** when that button is shown; otherwise select **Start SAPHIR**. On first start, SAPHIR copies its release from the internal network to `%LOCALAPPDATA%\SAPHIR`; it needs neither an Internet download nor administrator rights.
6. When the state changes to **Online**, select **Open SAPHIR**, then sign in normally.

When a new release is available, the launcher displays **Update and start** or **Update and restart**. It validates the download, keeps the previous release for rollback, and then opens SAPHIR. **Open SAPHIR** only opens the browser and leaves a healthy running instance untouched. **Stop** closes the local SAPHIR server.

## If SAPHIR does not start

1. Confirm that you are connected to the department network.
2. Open the launcher and check the application and shared-data states separately.
3. Select **Repair SAPHIR** if an update fails or the local copy appears damaged. The launcher stops only the SAPHIR instance it can identify, downloads and validates the published release again, and restarts it. Your shared data is not deleted.
4. If VBS files are blocked on your computer, create a shortcut to `Launch SAPHIR.bat` (type **Windows Batch File**) instead. This fallback shortcut may not show the custom logo.
5. If the problem continues, use **Open logs** in the launcher, or run `Stop SAPHIR.bat` followed by `Launch SAPHIR.bat` to keep the error visible.

Closing the browser does not necessarily stop the small local SAPHIR server. This is normal.
