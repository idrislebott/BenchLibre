# Vérifications effectuées

## Version 0.3.2 — anglais par défaut, français en option

Le 16 novembre 2026, sur Apple M2 et macOS 27.2.1 :

- Suite Release complète : 84 tests réussis, zéro échec. Neuf tests couvrent la localisation, les catalogues embarqués, les formats et la comparaison des versions macOS.
- Application native Release universelle compilée pour arm64 et x86_64 ; exécution arm64 vérifiée sur ce Mac.
- Signature ad hoc vérifiée strictement ; App Sandbox et Hardened Runtime actifs, seul entitlement sandbox, aucun droit réseau.
- Six moteurs exécutés dans l’application signée en validation courte : six résultats validés, aucune omission. Les messages sont en anglais par défaut ; aide et erreurs françaises vérifiées avec --language fr.
- Premier affichage anglais vérifié sur le Mac francophone ; passage immédiat au français, formats des dates/nombres et choix conservé après réouverture. Les menus macOS passent au français après réouverture.
- Réglages de langue accessibles dans la barre latérale, le menu et la fenêtre de réglages.
- Session graphique de 3 essais × 2,5 s pour chacun des quatre tests par défaut : changement du français à l’anglais pendant la mesure, puis 12 essais terminés et rapport enregistré sans interruption.
- Historique et comparaison de sessions 0.3.0/0.3.1 ouverts dans les deux langues. Les textes historiques sont conservés et identifiés comme texte original.
- Correction d’un faux avertissement de changement de macOS dû au libellé localisé « assemblage »/« Build ». Les nouvelles métadonnées système sont indépendantes de la langue ; les anciennes descriptions connues restent comparables.
- Charge suite-v3, noyaux C/Metal, comptage du travail, format JSON et unités canoniques inchangés. Les validations courtes ne sont pas des références de performance.
- Les résultats ASan historiques concernent la version 0.3.0 ; cette suite de 84 tests a été exécutée en Release normale.

## Version 0.3.1 — lecture des résultats

- Suite Release complète : 75 tests réussis, zéro échec ; neuf tests supplémentaires ciblent la sélection de référence, la compatibilité et les ratios extrêmes.
- Application native Release universelle compilée, puis ouverte sur Apple M2.
- Session réelle courte des six moteurs affichée avec les unités développées et les explications.
- Référence locale compatible sélectionnée : pourcentages signés, attente plus longue et débit plus faible vérifiés dans la fenêtre.
- Rechargement d’une session depuis l’historique et ouverture de « Comprendre ce résultat » vérifiés visuellement.
- Réglages d’une nouvelle mesure accessibles près du résumé ; données techniques conservées.
- Charge suite-v3 et format JSON inchangés. Les mesures courtes servent à vérifier le fonctionnement, pas à établir une référence de performance.
- Les résultats ASan ci-dessous concernent l’audit 0.3.0 ; la nouvelle suite de 75 tests a été exécutée en Release normale.


## Version 0.3.0 — audit historique

Le 16 novembre 2026, sur Apple M2 et macOS 27.2.1 :

- 66 tests Release réussis, zéro échec, aucun test ignoré.
- 66 tests réussis avec AddressSanitizer, dont le test Metal réel.
- Harnais des noyaux C avec AddressSanitizer et UndefinedBehaviorSanitizer : 64 cycles de création/calcul/validation/destruction, aucun diagnostic.
- Assemblage native Xcode Release, signature ad hoc avec App Sandbox et Hardened Runtime.
- Vérification stricte de signature et de ressources, diagnostic positif du confinement ; un droit réseau ajouté à une copie de test provoque un refus de démarrage.
- Six moteurs réellement exécutés en validation courte, six résultats validés sans omission, export JSON dans le conteneur.
- Chemin d'export externe refusé avant mesure ; tests des symlinks, hardlinks, FIFO, tailles JSON, tableaux excessifs et graphiques extrêmes.
- Durée de session monotone conservée et vérifiée, y compris après un recul simulé de l'horloge civile.
- Boucles CPU vectorielles et lectures dépendantes toujours présentes dans l'assembleur optimisé.

Le harnais C source est conservé dans Tests/NativeSafety/KernelSafetyHarness.c. Les tests Swift sont dans Tests/BenchCoreTests. Les journaux complets sont conservés dans le dossier de travail de cette session.

La cible universelle compile pour arm64 et x86_64 ; seules les exécutions arm64 ont été testées ici. Les durées courtes servent à vérifier le fonctionnement, sans établir une référence de performance. Les versions instrumentées ne sont pas des mesures de référence.

Le contrôle visuel de l'ancienne instance via l'interface macOS n'a pas permis de terminer le remplacement et l'essai visuel de la version 0.3. La version 0.2 est conservée. La version corrigée est livrée séparément ; il faut quitter l'ancienne instance avant de l'ouvrir.

Le rapport [SECURITY-AUDIT.md](SECURITY-AUDIT.md) décrit les corrections, les limites de l'audit, les dépendances et la distribution encore sans notarisation. Il ne faut pas assimiler une signature locale valide à une certification antivirus ou à une authentification matérielle des résultats.

## Vérifications historiques — versions 0.2 et 0.1

La version 0.2 avait passé 41 tests Release sur cette machine. Les six moteurs, les répétitions, l'historique et l'export via l'ancien panneau avaient été utilisés. La version 0.1 avait passé 12 tests et une session visuelle CPU/GPU/mémoire.

Ces résultats historiques concernent les anciens binaires, avant le confinement et les corrections de chronométrage de la version 0.3. Ils ne valident ni la sécurité actuelle, ni la comparabilité entre les suites v2 et v3. Les anciennes archives et les rapports de validation sont conservés en dehors du projet courant.
