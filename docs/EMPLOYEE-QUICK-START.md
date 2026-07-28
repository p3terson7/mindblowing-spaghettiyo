# SAPHIR — démarrage rapide

## Première utilisation

1. Ouvrez le dossier partagé `SAPHIR-Distribution` sur le réseau.
2. Supprimez l’ancien raccourci de l’application de votre Bureau, s’il existe.
3. Double-cliquez une fois sur `Install SAPHIR Shortcut.vbs`. Il crée le raccourci **SAPHIR** avec le logo bleu sur votre Bureau; aucun droit administrateur n’est requis.
4. Double-cliquez sur le nouveau raccourci **SAPHIR**. Une petite fenêtre indique si l’application et le dossier de données partagé sont disponibles.
5. Si l’application est arrêtée, cliquez sur **Démarrer SAPHIR**. Au premier démarrage, SAPHIR copie sa version depuis le réseau interne vers `%LOCALAPPDATA%\SAPHIR`; aucun téléchargement Internet ni droit administrateur n’est nécessaire.
6. Lorsque l’état passe à **En ligne**, cliquez sur **Ouvrir SAPHIR**, puis connectez-vous normalement.

Pour appliquer une mise à jour ou récupérer une instance qui ne répond plus, utilisez **Redémarrer** dans le lanceur. **Ouvrir SAPHIR** ouvre seulement le navigateur et ne redémarre pas une instance qui fonctionne déjà. **Arrêter** ferme le serveur SAPHIR local.

## En cas de problème

1. Vérifiez que vous êtes connecté au réseau du ministère.
2. Ouvrez le lanceur et regardez séparément l’état de l’application et celui des données partagées.
3. Utilisez **Redémarrer** si SAPHIR ne répond plus. Le lanceur affiche une animation pendant l’opération et reste utilisable.
4. Si les scripts VBS sont bloqués sur votre poste, créez plutôt un raccourci vers `Launch SAPHIR.bat` (type **Fichier de commandes Windows**). Ce raccourci de secours n’aura peut-être pas le logo personnalisé.
5. Si le problème continue, utilisez **Ouvrir les journaux** dans le lanceur ou exécutez `Stop SAPHIR.bat`, puis `Launch SAPHIR.bat` pour voir le message d’erreur.

Fermer le navigateur ne ferme pas nécessairement le petit serveur SAPHIR local. Ce comportement est normal.

---

# SAPHIR — quick start

## First use

1. Open the shared `SAPHIR-Distribution` network folder.
2. Delete the application's old Desktop shortcut, if one exists.
3. Double-click `Install SAPHIR Shortcut.vbs` once. It creates a **SAPHIR** Desktop shortcut with the blue logo; administrator rights are not required.
4. Double-click the new **SAPHIR** shortcut. A small window shows the application and shared-data states separately.
5. If the application is stopped, select **Start SAPHIR**. On first start, SAPHIR copies its release from the internal network to `%LOCALAPPDATA%\SAPHIR`; it needs neither an Internet download nor administrator rights.
6. When the state changes to **Online**, select **Open SAPHIR**, then sign in normally.

Use **Restart** in the launcher to apply an update or recover an instance that no longer responds. **Open SAPHIR** only opens the browser and leaves a healthy running instance untouched. **Stop** closes the local SAPHIR server.

## If SAPHIR does not start

1. Confirm that you are connected to the department network.
2. Open the launcher and check the application and shared-data states separately.
3. Select **Restart** if SAPHIR is no longer responding. The launcher remains responsive and shows progress during the operation.
4. If VBS files are blocked on your computer, create a shortcut to `Launch SAPHIR.bat` (type **Windows Batch File**) instead. This fallback shortcut may not show the custom logo.
5. If the problem continues, use **Open logs** in the launcher, or run `Stop SAPHIR.bat` followed by `Launch SAPHIR.bat` to keep the error visible.

Closing the browser does not necessarily stop the small local SAPHIR server. This is normal.
