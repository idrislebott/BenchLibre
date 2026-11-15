# Vérifications effectuées

## Version 0.2.0

Sur le même Apple M2, macOS 27.2.1, Swift 6.4.2 et Xcode 27.2, la suite Release complète a exécuté **41 tests avec zéro échec** : CPU/mémoire (6), E/S fichier (4), GPU Metal (3), latence mémoire (5), rapports (3), cohérence et compatibilité des rapports (10), passages répétés du runner (2), statistiques et conditions (8).

Les tests d’E/S utilisent de petits fichiers et vérifient les octets transférés, le recalcul des débits, l’annulation et la conservation d’un fichier témoin extérieur au test. Le noyau C de latence a aussi été vérifié isolément avec AddressSanitizer et UndefinedBehaviorSanitizer ; son assembleur optimisé conserve les lectures dépendantes.

Une exécution Release courte des six moteurs a réellement produit six résultats validés, avec données brutes, résumés et conditions. Le plafond d’écriture a été respecté. Une autre session a exécuté trois passages sur chacun des quatre tests sélectionnés par défaut ; les médianes et les formules travail/temps ont été recalculées indépendamment à partir du JSON. Les arguments CLI invalides ont été rejetés avant les mesures.

Dans l’application installée, une session de latence de **trois passages de 2,5 secondes** a été réalisée. La médiane, l’intervalle min–max, le coefficient de variation et les échantillons du passage médian ont été affichés. Le journal contenait dix observations initiale, périodiques et finale. L’historique a affiché le rapport court des six moteurs et les anciens rapports v0.1, interprétés comme un passage.

L’export JSON a réussi depuis l’interface, puis la fenêtre principale a repris le focus. Sur ce système, un dossier restauré par le panneau d’export pouvait laisser le bouton d’enregistrement grisé ; une sélection explicite du dossier avec ⌘⇧G a permis l’enregistrement local.

Ces passages servent à vérifier le fonctionnement ; ils n’établissent pas une référence de performances ni une validation entre différents modèles de Mac. Les contrôles du format 2 vérifient la cohérence interne des données, sans certifier l’authenticité matérielle d’une exécution. Les autres modèles de Mac, macOS 14 et les Mac Intel restent non testés en exécution ici.

## Version 0.1 — historique

Ces vérifications concernent la version locale de BenchLibre sur la machine suivante :

- Puce : Apple M2.
- Système : macOS 27.2.1.
- Compilation : Swift 6.4.2 et Xcode 27.2.

La commande `swift test -c release` a exécuté 12 tests, avec zéro échec : 6 tests CPU/mémoire, 3 tests GPU et 3 tests de rapports. La validation du résultat GPU contre la référence CPU a réellement été exécutée sur le GPU de cette machine.

Une revue du code en lecture seule n’a relevé aucun problème critique dans le comptage des opérations et des octets, les dénominateurs temporels ou la gestion de l’annulation. Cette revue ne constitue pas une certification des performances.

L’application Release installée a également été vérifiée avec une session de 2,5 secondes par test CPU, GPU Metal et mémoire. Les trois résultats ont réussi leurs contrôles numériques. L’annulation n’a pas créé de rapport ; l’historique a conservé une session après redémarrage. Le menu « Données pour les nerds » et l’export JSON vers un dossier local ont été utilisés dans l’interface. Les débits exportés ont été recalculés à partir du travail et du dénominateur enregistrés.

Le chargement des ressources Metal de l’application autonome a réussi avec le bundle de ressources de compilation temporairement déplacé. La signature locale du paquet installé a été vérifiée. Le dossier iCloud des livrables a été signalé comme indisponible à l’écriture par le panneau d’export natif pendant une vérification ; un export local a fonctionné.

Les exécutions automatisées courtes servent à vérifier le fonctionnement et la cohérence des calculs. Elles ne constituent pas des résultats de performance de référence.

Les autres modèles de Mac, macOS 14 et les Mac Intel n’ont pas été testés ici.
