# BenchLibre

Un benchmark natif et open source pour macOS, construit avec SwiftUI, C et Metal. La version **0.2.0** propose six mesures distinctes et conserve leurs unités réelles :

| Test | Mesure | Charge |
| --- | --- | --- |
| CPU | GFLOP/s | 8 chaînes FP32 de 4 voies par worker, sur les threads CPU demandés |
| GPU Metal | GFLOP/s | Noyau Metal fixe de 536 870 912 FLOP par dispatch |
| Mémoire | Go/s | Triade mono-thread sur 3 × 64 Mio : `A = B + 3 × C` |
| Latence mémoire | ns/accès | Cycle d’indices dépendants et aléatoires dans 64 Mio ; plus bas est meilleur |
| Lecture SSD | Go/s | Lecture séquentielle d’un fichier temporaire de 64 Mio avec `F_NOCACHE` |
| Écriture SSD | Go/s | Écriture séquentielle du fichier temporaire, avec `fsync` chronométré |

Les quatre premiers tests sont sélectionnés par défaut dans l’application et en ligne de commande. Les tests fichier/SSD s’activent explicitement. Les résultats restent séparés, sans score global.

Chaque session peut répéter les mesures pour afficher une médiane et leur dispersion. Le rapport conserve les passages complets, leurs échantillons et contrôles numériques, ainsi qu’un journal des conditions du Mac.

## Utiliser l'application

Ouvrir **BenchLibre.app**, sélectionner les tests, la durée et le nombre de passages, puis lancer la session. Le bouton d’arrêt interrompt la session sans enregistrer de rapport incomplet. Le menu **Données pour les nerds** affiche les détails du protocole. Un rapport terminé peut être exporté en JSON.

Si macOS grise le bouton d’enregistrement, sélectionner explicitement un dossier accessible dans le panneau ; le raccourci ⌘⇧G permet aussi de saisir son chemin. L’historique est enregistré dans `~/Library/Application Support/BenchLibre/Reports`.

Trois durées sont proposées, pour chaque passage de chaque test sélectionné :

- **Rapide** : 2,5 secondes ; utile pour vérifier une configuration.
- **Standard** : 10 secondes ; un passage de mesure courant.
- **Endurance** : 30 secondes ; pour observer une charge plus soutenue.

Le nombre de passages peut être **1, 3 ou 5**, avec **3 par défaut**. La valeur affichée est celle du passage médian réel : son travail, sa durée, son checksum et ses échantillons restent auditables ensemble. La dispersion décrit les écarts entre les passages ; avec un seul passage, elle n’est pas estimée.

La préparation, la calibration, l’échauffement et la validation ajoutent du temps à la session. Par exemple, quatre tests de 10 secondes répétés trois fois demandent environ 120 secondes de fenêtres mesurées, puis ces opérations supplémentaires. Les tests fichier peuvent terminer plus tôt lorsqu’ils atteignent leur budget d’octets.

Les tests fichier utilisent le volume du dossier temporaire de macOS. Chaque passage crée et supprime son propre fichier de **64 Mio**, avec **64 Mio d’écriture de préparation** hors chronométrage. Un passage d’écriture transfère ensuite au maximum **512 Mio mesurés** ; un passage de lecture, au maximum **64 Gio mesurés**. Ces limites se multiplient par le nombre de passages. `F_NOCACHE` désactive le cache de données du descripteur ; il ne certifie pas le contournement des caches du contrôleur ou du périphérique. Il s’agit d’E/S de fichier, pas d’une mesure brute du SSD.

Pour comparer deux passages, conserver la même version de charge, les mêmes réglages et des conditions proches : alimentation, mode d'énergie, applications ouvertes et état thermique. Répéter le passage aide à voir la variabilité.

L’alimentation, le mode économie d’énergie et l’état thermique sont observés au début, environ chaque seconde et à la fin de la session. Ce suivi peut manquer un changement entre deux observations. L’état thermique est le niveau signalé par macOS, pas une température en degrés Celsius ni une certification d’absence de bridage.

## Construire depuis les sources

Prérequis : **macOS 14 ou ultérieur**, Xcode avec **Swift 6** et le SDK macOS, puis les outils de développement sélectionnés dans Xcode.

```sh
swift build -c release
./scripts/build-app.sh
```

Le script de packaging affiche le chemin de l'application produite, par défaut `~/Library/Caches/BenchLibre/Build/BenchLibre.app`. Un dossier local évite les métadonnées ajoutées par certains services de synchronisation, qui peuvent empêcher la vérification de signature. La variable `BENCHLIBRE_APP_OUTPUT` permet de choisir un autre chemin se terminant par `/BenchLibre.app` ; une application existante à ce chemin est sauvegardée avant remplacement.

La compilation cible l'architecture du Mac qui la construit : Apple Silicon ou Intel. Le test GPU nécessite un périphérique Metal compatible. L'application est signée localement, sans notarisation Apple ; les sources permettent de la reconstruire sur son propre Mac.

Utiliser une **compilation Release** pour mesurer les performances. Une compilation Debug sert au développement ; ses nombres ne sont pas comparables à ceux de Release.

## Ligne de commande

Depuis le dossier du projet :

```sh
# Vérification rapide du fonctionnement
.build/release/BenchLibre --smoke

# Trois passages courts des quatre tests sélectionnés par défaut
.build/release/BenchLibre --cli --seconds 2.5 --repetitions 3 --tests cpu,gpu,memory,latency --output result.json

# Tests fichier explicitement choisis, un seul passage chacun
.build/release/BenchLibre --cli --seconds 1 --repetitions 1 --tests disk-read,disk-write --output storage.json
```

`--seconds` définit la durée cible de chaque passage, entre 0,1 et 120 secondes. `--repetitions` accepte 1, 3 ou 5. `--tests` accepte une liste parmi `cpu,gpu,memory,latency,disk-read,disk-write`, ou `all` pour les six mesures, y compris les E/S fichier. `--threads` fixe le nombre de workers CPU. `--info` affiche la configuration matérielle sans lancer de mesure.

Sans option de sélection, CPU, GPU, mémoire et latence sont utilisés. Le mode `--smoke` utilise par défaut un passage court et au plus deux workers CPU ; il sert à vérifier l’exécution et les validations, sans fournir un résultat de performance de référence. Les E/S restent désactivées tant qu’elles ne sont pas choisies avec `--tests`.

Les nouveaux rapports utilisent le **format 2**, la version de charge **`benchlibre-suite-v2`** et contiennent `results`, `trials`, `summaries`, `conditions` et `omissions`. Les rapports de format 1 restent lisibles ; l’absence de nombre de passages y est interprétée comme un seul passage. Les protocoles différents ne doivent pas être regroupés automatiquement dans un classement.

## Développer et vérifier

```sh
swift test
```

Les tests couvrent les comportements et les contrôles numériques définis par chaque moteur. Un test Metal peut être ignoré si aucun GPU Metal n'est disponible. La réussite d'un test automatisé ne remplace pas un passage Release sur le matériel à mesurer.

- [`Sources/BenchCore`](Sources/BenchCore) : modèles, moteurs et rapports.
- [`Sources/BenchKernels`](Sources/BenchKernels) : noyaux CPU et mémoire en C.
- [`Sources/BenchLibre`](Sources/BenchLibre) : application macOS.
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) : définition des unités et limites de comparaison.

## Ce que les chiffres représentent

Le calcul FP32 mesure la charge fournie avec BenchLibre. Il ne mesure pas les FPS d'un jeu, les performances de ray tracing, ni l'efficacité d'un moteur 3D. Les noyaux CPU et GPU sont différents : leurs GFLOP/s ne forment pas un indice global de « puissance du Mac ».

La bande passante mémoire compte les octets logiques traités par la charge. Elle inclut les effets des caches et du contrôleur mémoire ; elle ne constitue pas une mesure directe du trafic physique de la DRAM.

La latence mesure une chaîne d’accès dépendants dans un ensemble fixe de 64 Mio, à travers la hiérarchie de caches. L’espacement de 64 octets entre les nœuds définit la charge et ne prétend pas reproduire la taille des lignes de cache de chaque processeur.

La couverture CPU reste, dans cette version, un noyau de calcul FP32. Le rendu graphique 3D, les profils de ray tracing matériel, l’inférence IA/NPU, les capteurs avancés et le classement mondial sont des évolutions futures.

Une validation numérique vérifie la cohérence du calcul effectué. Elle n'est ni un diagnostic exhaustif du matériel ni une certification de stabilité.

## Données et licence

Les calculs et les résultats restent locaux. BenchLibre n'envoie pas de télémétrie, ne téléverse pas les rapports et ne nécessite pas de compte. Le partage d'un export JSON est une action manuelle.

Le code est fourni sous [licence MIT](LICENSE). Il peut être étudié, modifié et redistribué. Ce dossier est prêt à être placé dans un dépôt public ; la licence seule ne publie pas automatiquement un dépôt sur Internet.
