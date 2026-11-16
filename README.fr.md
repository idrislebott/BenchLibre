# BenchLibre

Benchmark natif open source pour **macOS 14 ou ultérieur**, écrit en Swift 6, C et Metal. La version **0.3.2** utilise la charge **`benchlibre-suite-v3`** et conserve six mesures dans leurs unités réelles :

| Test | Mesure | Charge |
| --- | --- | --- |
| CPU | GFLOP/s | 8 chaînes FP32 de 4 voies par worker |
| GPU Metal | GFLOP/s | 536 870 912 FLOP par dispatch, dimensions fixes |
| Mémoire | Go/s | Triade mono-thread sur 3 × 64 Mio : `A = B + 3 × C` |
| Latence mémoire | ns/accès | Cycle d’indices dépendants dans 64 Mio ; plus bas est meilleur |
| Lecture fichier | Go/s | Fichier de 64 Mio avec `F_NOCACHE` |
| Écriture fichier | Go/s | Réécriture du fichier de 64 Mio, `fsync` compris |

CPU, GPU, mémoire et latence sont sélectionnés par défaut. Les E/S fichier s’activent explicitement. Il n’existe pas de score global.

## Lecture des résultats

Les cartes présentent un nom courant, une phrase sur le travail mesuré et une unité écrite en toutes lettres. « Comprendre ce résultat » explique l'unité et la portée du test. Le sens de lecture est explicite : davantage de débit, ou moins d'attente pour la latence mémoire.

Lorsqu'une session antérieure est compatible, les cartes décrivent l'écart observé en mots et en pourcentage. La référence doit avoir la même configuration matérielle, le même protocole, les mêmes tests mesurés, les mêmes réglages et les mêmes métadonnées de calcul. Les différences de système, alimentation et état thermique sont signalées. Le choix de la référence s'effectue hors du fil de l'interface.

Une première session sans référence devient un point de départ. Ces explications ne donnent pas de note absolue, de classement mondial, de certification de santé ni de prédiction de FPS. Les noyaux et la charge suite-v3 restent inchangés ; le format de rapport reste compatible. Les détails techniques et les données brutes restent accessibles.

## Langues

L’anglais est la langue par défaut, même sur un Mac réglé en français. Choisir **Français** dans **Language**, en bas de la barre latérale, ou dans les réglages de l’application. Le choix est mémorisé et l’interface change immédiatement. Les menus fournis par macOS peuvent nécessiter une réouverture. Les nombres et les dates suivent la langue choisie ; les textes des rapports existants restent dans leur langue d’origine.

Le mode sans interface utilise l’anglais par défaut et accepte **--language fr**. Voir [la documentation de localisation](docs/LOCALIZATION.md).

## Utiliser l’application

Ouvrir **BenchLibre.app**, choisir les tests, la durée et **1, 3 ou 5 passages** — 3 par défaut — puis lancer la session. L’arrêt annule la session sans enregistrer un rapport incomplet. Le menu **Données pour les nerds** affiche le détail du protocole.

La valeur affichée est celle du passage médian réel : son travail, sa durée, son checksum et ses échantillons restent associés. Le rapport JSON conserve aussi tous les passages, leur dispersion et les conditions observées du Mac. Avec un seul passage, l’écart-type et le coefficient de variation restent absents.

Trois durées cibles sont proposées, pour **chaque passage et chaque test** :

- **Rapide** : 2,5 secondes, pour vérifier le fonctionnement.
- **Standard** : 10 secondes.
- **Endurance** : 30 secondes.

La préparation, la calibration, l’échauffement et la validation ajoutent du temps. Les tests fichier peuvent finir plus tôt lorsqu’ils atteignent leur budget d’octets.

Le bouton **Exporter les résultats** crée un fichier dans le dossier **Exports du conteneur**, puis le révèle dans Finder. Vous pouvez ensuite le copier manuellement. L’application n’a pas de droit d’écriture dans un dossier externe choisi par l’utilisateur.

## Stockage et confinement

L’application utilise **App Sandbox** et **Hardened Runtime**. Elle vérifie sa propre signature au démarrage et refuse les droits supplémentaires à ceux de sa politique. Aucun accès réseau, script, exécution de commande shell, service privilégié ou demande de mot de passe administrateur n’est nécessaire.

Les données sont dérivées du dossier Application Support fourni par Foundation dans le conteneur macOS :

- **Reports** : historique des rapports validés.
- **Exports** : copies JSON créées à votre demande.
- **Temporary** : fichiers temporaires des tests de stockage, supprimés en fin de passage.

Avec l’identifiant actuel, ce dossier se trouve normalement dans `~/Library/Containers/org.benchlibre.mac/Data/Library/Application Support/BenchLibre`. Le mode de diagnostic décrit plus bas affiche les chemins réellement fournis par le système. L’application lit aussi ses ressources signées et utilise les frameworks système.

L’ancien historique de la version 0.2, situé hors du conteneur, **n’est pas importé automatiquement**. Les anciens fichiers ne sont pas supprimés. Après la création du conteneur par le premier lancement, vous pouvez copier vous-même des rapports compatibles dans son dossier Reports avec Finder. Leur lecture applique les contrôles de taille et de cohérence.

Les accès aux rapports sont bornés ; les liens symboliques, fichiers spéciaux et fichiers à plusieurs liens physiques sont refusés. Cela ne constitue pas une protection contre un système compromis ou un autre processus déjà autorisé à modifier le conteneur.

## E/S fichier

Chaque passage utilise un fichier privé de **64 Mio**, sur le volume du conteneur de l’application, et écrit **64 Mio de préparation** hors chronométrage. Il transfère ensuite au maximum **512 Mio mesurés en écriture** ou **64 Gio mesurés en lecture**. Plusieurs passages multiplient ces E/S.

`F_NOCACHE` doit être accepté pour que le test s’exécute. Il désactive le cache de données du descripteur sans certifier le contournement des caches du contrôleur ou du périphérique. Il s’agit d’E/S séquentielles de fichier, sans accès brut au SSD ni sélection de disque externe.

## Construire avec Xcode

Prérequis : **Xcode avec Swift 6 et le SDK macOS**, macOS 14 ou ultérieur. Le GPU doit être compatible avec le noyau Metal.

1. Ouvrir **BenchLibre.xcodeproj** dans Xcode.
2. Choisir le schéma partagé **BenchLibre** et la destination **My Mac**.
3. Conserver la configuration **Release** du schéma et lancer **Product → Build**.
4. Dans le groupe Products de Xcode, révéler **BenchLibre.app** dans Finder, puis ouvrir l’application.

La cible Xcode assemble les ressources et applique le sandbox et Hardened Runtime sans phase de script. Sa signature locale ad hoc ne demande pas de compte développeur. Le schéma lance Release sans débogueur et sans droit `get-task-allow`. Les paramètres de sécurité ne doivent pas être assouplis pour contourner un problème de construction.

Laisser les produits de compilation dans le dossier DerivedData local de Xcode : certains dossiers synchronisés peuvent ajouter des métadonnées incompatibles avec la vérification stricte d’une signature.

**Package.swift décrit uniquement la bibliothèque BenchCore, ses noyaux C et ses tests.** Il ne produit pas l’application signée. Pour développer la bibliothèque, ouvrir le package dans Xcode et exécuter ses tests avec **Product → Test**. La réussite des tests ne remplace pas une mesure Release sur le matériel cible ; les tests Metal peuvent être ignorés en l’absence de GPU utilisable.

Une compilation Debug sert au développement et ses mesures ne sont pas comparables à celles de Release. Une compilation instrumentée par un analyseur mémoire ne sert pas non plus de référence de performance.

## Modes sans interface

L’exécutable contenu dans l’application signée conserve des modes de diagnostic et de mesure. Ils peuvent être configurés comme arguments de lancement dans **Product → Scheme → Edit Scheme → Run → Arguments**, sans script ni commande shell :

| Argument | Fonction |
| --- | --- |
| `--info` | Métadonnées matérielles en JSON, sans benchmark |
| `--security-info` | Politique de signature et chemins du conteneur |
| `--smoke` | Vérification courte : 0,25 s, un passage, au plus deux workers CPU |
| `--cli` | Session sans interface, mêmes valeurs par défaut que l’application |
| `--seconds N` | Durée cible par passage entre 0,1 et 120 s |
| `--repetitions N` | 1, 3 ou 5 passages |
| `--threads N` | Nombre de workers CPU |
| `--tests LIST` | Liste séparée par virgules ou `all` |
| `--language en` / `--language fr` | Langue des messages sans modifier la préférence de l’interface |
| `--output NOM.json` | Copie dans Exports du conteneur, sans chemin externe |

La liste des tests accepte `cpu,gpu,memory,latency,disk-read,disk-write`. `all` inclut les E/S. Sans sélection, les quatre premiers sont utilisés. Sans `--output`, le rapport est écrit sur la sortie standard. Le nom d’export accepte seulement lettres ASCII, chiffres, tirets, points et soulignements ; les chemins absolus et relatifs vers un autre dossier sont rejetés avant le calcul.

Le mode `--smoke` vérifie l’exécution et les contrôles numériques ; il ne fournit pas un score de référence.

## Comparer et interpréter

Conserver la même version de charge, la même compilation Release, les mêmes réglages et des conditions proches : alimentation, mode d’énergie, applications concurrentes et état thermique. Les résultats de `benchlibre-suite-v2` et `benchlibre-suite-v3` ne doivent pas être regroupés automatiquement : les fenêtres mesurées et la gestion des sorties GPU ont changé.

Le calcul FP32 ne mesure pas les FPS d’un jeu, le ray tracing ou un moteur 3D. La triade compte les octets logiques, pas le trafic physique de DRAM. La latence traverse la hiérarchie mémoire dans un ensemble fixe de 64 Mio ; les emplacements de 64 octets ne prétendent pas reproduire les lignes de cache de chaque processeur.

macOS choisit l’affectation des workers aux cœurs Performance et Efficacité. Une charge soutenue ne garantit pas une occupation matérielle de 100 %. Le journal d’alimentation, du mode économie d’énergie et de l’état thermique est échantillonné environ une fois par seconde. Il peut manquer un événement bref ; l’état thermique n’est pas une température en °C ni une preuve d’absence de bridage.

Les validations numériques et structurelles contrôlent la cohérence locale. Elles ne certifient pas l’authenticité d’un score partagé, l’intégrité d’un ordinateur distant ou la stabilité exhaustive du matériel. Le rendu 3D, le ray tracing, le NPU, les capteurs avancés et un classement mondial restent des évolutions futures.

## Distribution, données et licence

La version locale est signée **ad hoc**, sans signature Developer ID ni notarisation Apple. Pour une distribution publique reconnue par Gatekeeper, une procédure Developer ID et notarisation reste nécessaire. Un avertissement Gatekeeper sur l’identité du développeur n’est pas une détection de malware. Aucune absence de faux positif XProtect ou VirusTotal n’est garantie ; aucun envoi automatique à ces services n’est effectué.

BenchLibre ne collecte pas de télémétrie, ne téléverse aucun rapport et ne nécessite pas de compte. Le partage d’un JSON est manuel. Aucune dépendance tierce externe n’est intégrée ; le code propre au projet est sous [licence MIT](LICENSE). Les frameworks Apple conservent leurs propres conditions de licence.

- [Protocole détaillé](docs/PROTOCOL.md)
- [Inventaire des dépendances et licences](docs/DEPENDENCIES.md)
- [Sources des moteurs](Sources/BenchCore)
- [Noyaux C](Sources/BenchKernels)
- [Application macOS](Sources/BenchLibre)

La licence MIT permet l’étude, la modification et la redistribution du code. Ce dossier n’a pas été publié automatiquement sur Internet.
