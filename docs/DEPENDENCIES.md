# Dépendances et licences — BenchLibre 0.3.0

Inventaire établi à partir de `Package.swift`, du projet Xcode, des imports Swift/C et des ressources du dépôt. L’application utilise les API natives de macOS ; elle ne télécharge aucune dépendance à l’exécution.

## Paquets externes

**Nombre de dépendances tierces de package : 0.**

Le manifeste Swift Package Manager ne déclare aucun paquet distant. Le projet Xcode référence seulement le package local situé à sa racine. Aucun gestionnaire CocoaPods, Carthage, npm ou binaire tiers n’est requis par la cible de l’application. Il n’existe pas de phase de script de construction dans le projet Xcode.

| Composant propre au projet | Contenu | Licence |
| --- | --- | --- |
| BenchLibre | Application SwiftUI/AppKit, interface et modes sans interface | MIT |
| BenchCore | Moteurs, modèles, statistiques, suivi des conditions et stockage | MIT |
| BenchKernels | Noyaux C de calcul FP32, triade mémoire et accès dépendants | MIT |
| Compute.metal | Shader de calcul FP32 embarqué et vérifié par SHA-256 | MIT |

La [licence MIT du dépôt](../LICENSE) s’applique au code propre au projet. Elle autorise sa publication, sa modification et sa redistribution sous ses conditions de conservation de la notice.

## Frameworks et bibliothèques système

Ces éléments sont fournis par Apple avec le système ou le SDK. Ils ne sont pas des paquets tiers copiés dans ce dépôt et ne sont pas relicenciés en MIT par BenchLibre.

| Élément | Usage dans BenchLibre |
| --- | --- |
| SwiftUI | Présentation des vues et cycle de vie de l’application |
| AppKit | Presse-papiers et révélation d’une copie JSON dans Finder, à la demande |
| Foundation / ProcessInfo | Modèles, JSON, dates, verrous, informations système, état thermique, mode économie d’énergie et activité utilisateur |
| Dispatch / GCD | Workers CPU, file de progression, horloge monotone et suivi périodique |
| Metal | Périphérique, buffers bornés, compilation du shader, commandes de calcul et horodatages GPU |
| IOKit.ps | Lecture publique des informations d’alimentation |
| CryptoKit | Vérification SHA-256 de la ressource Metal embarquée |
| Security | Lecture et validation de la propre signature et de ses entitlements |
| Darwin / bibliothèque C / math | `sysctlbyname` en code natif, allocations bornées, FMA, descripteurs et E/S locales |
| XCTest | Tests de développement uniquement, absent du produit distribué |

Le langage Swift, sa bibliothèque standard et les outils Swift/Clang/Xcode font partie de la chaîne de développement. Le dépôt ne redistribue pas leurs sources. Leur propre licence et les conditions du SDK Apple restent applicables. L’utilisation de ces frameworks système ne transforme pas le code MIT de BenchLibre en framework Apple libre.

Aucune bibliothèque Accelerate n’est actuellement utilisée ; les noyaux CPU et mémoire sont du C propre au projet.

## Ressources et intégrité

Le shader est une ressource locale du package, copiée dans le bundle de l’application. Le code de production n’utilise pas le dossier courant, une variable d’environnement ou un chemin de développement de remplacement pour le charger. Sa lecture est bornée et refuse les liens symboliques.

Empreinte attendue de `Sources/BenchCore/Shaders/Compute.metal` :

`a7dfa6d8eb168939869b17df232fe4b3733efdadb87a04d1dbf1381023ac5041`

L’icône est un fichier local du projet, sans bibliothèque de rendu ou service distant requis à l’exécution.

## Sécurité et limites de cet inventaire

Aucune dépendance externe ancienne à mettre à jour ou source tierce suspecte n’a été identifiée dans cet inventaire. Cela ne constitue pas une preuve formelle d’absence de vulnérabilité ni un certificat antivirus. Il faut maintenir le SDK et la chaîne de développement, réexaminer toute dépendance ajoutée ultérieurement, et vérifier le produit signé avant distribution.

Le produit local est signé ad hoc avec App Sandbox et Hardened Runtime. Il n’intègre ni outil privilégié, ni client réseau, ni mécanisme d’installation de code externe. La signature Developer ID, la notarisation et la réputation auprès des moteurs antivirus sont des sujets distincts de la licence MIT et de cet inventaire.
