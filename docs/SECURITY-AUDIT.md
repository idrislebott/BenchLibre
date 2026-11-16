> Complément 0.3.1 : lecture simplifiée et comparaison locale de sessions. Neuf tests supplémentaires valident les règles de référence et les pourcentages ; la suite Release complète passe à 75 tests. Aucune dépendance ni permission ajoutée. Le rapport ci-dessous documente l’audit de sécurité 0.3.0.

# Audit de sécurité et de mesure — BenchLibre 0.3.0

Date : 16 novembre 2026. Charge : `benchlibre-suite-v3`. Format JSON : 2, compatible avec les anciens rapports acceptés par les contrôles de lecture.

## Résultat et périmètre

Les sources Swift, C et Metal, le manifeste de package, le projet Xcode, les ressources, les réglages de signature et les tests ont été examinés. Les risques identifiés ont été corrigés et la cible native Release a été construite et exécutée sur Apple M2. Ce rapport décrit une revue et des essais locaux, sans constituer une certification de sécurité, d'authenticité d'un score ou d'antivirus.

Le projet ne contient aucun paquet tiers distant. Il n'exécute aucune commande shell, aucun script, aucun outil privilégié et n'utilise aucun appel à Process, NSTask, system(), popen(), sudo ou AppleScript. La recherche statique a été complétée par la lecture des chemins de stockage, de calcul et de concurrence ; une recherche de mots seule ne prouverait pas la sécurité.

La chaîne de validation a été pilotée par des lectures/écritures de fichiers et le lancement direct des outils natifs Swift, Clang, Xcode et codesign, sans interpréteur shell ni élévation de privilèges. Ces outils de développement ne sont pas embarqués dans l'application.

## Corrections appliquées

| Point examiné | Correction et effet |
| --- | --- |
| Confinement absent de l'ancien assemblage local | Cible Xcode native, App Sandbox et Hardened Runtime ; suppression des scripts de construction du projet courant. |
| Droits implicites ou futurs trop larges | Entitlement unique : `com.apple.security.app-sandbox = true`. Au démarrage, lecture publique Security de la signature complète : liste d'autorisations stricte, sandbox et runtime obligatoires. Seules les métadonnées normales d'identité de signature peuvent s'ajouter ; tout autre droit provoque un refus. Le lancement avec UID effectif zéro est également refusé. |
| Export vers un chemin arbitraire | Suppression du panneau de destination externe. L'interface et le mode sans interface créent les copies dans Exports, au sein du conteneur. Le mode sans interface accepte un nom JSON simple, jamais un chemin. |
| Liens et fichiers spéciaux | Accès relatifs à des descripteurs, O_NOFOLLOW, créations exclusives, fichiers privés 0600, répertoires privés 0700 ; rejet des symlinks, FIFO et fichiers à plusieurs liens physiques. Écriture dans un temporaire propre, fsync, puis renommage atomique. Les erreurs nettoient uniquement les fichiers appartenant à l'opération. |
| Entrées JSON pouvant saturer l'application | Rapport limité à 8 Mio ; au plus 6 résultats, 30 passages, 4 096 échantillons par passage, 10 000 observations et des chaînes bornées. Limites vérifiées pendant le décodage des tableaux. Chargement de l'historique plafonné en nombre de fichiers, octets lus et rapports conservés. Dates bornées avant formatage. |
| Pointeur de nom de fichier | Lecture du tableau d_name limitée à sa taille réelle et à son terminateur ; suppression d'une capacité de réinterprétation supposée. |
| Allocations C et compteurs | Tailles plafonnées avant allocation/multiplication ; vérification des erreurs et entrées nulles ; pointeurs posix_memalign intermédiaires du type correct ; destruction structurée sur succès, erreur et annulation ; contrôle de débordement du compteur CPU. |
| Boucles optimisées | Résultats CPU, échauffement compris, réellement consommés ; noyaux C non inline, sans LTO, sémantique flottante stricte. Une compilation C en fast-math est refusée. Les FMA vectorielles et les lectures dépendantes ont été retrouvées dans l'assembleur Clang optimisé. |
| Sorties GPU réécrites entre dispatchs | Chaque dispatch d'une commande possède une tranche de sortie distincte, pour 32 Mio au maximum. Valeurs sentinelles NaN, consommation après chaque commande, contrôle fini exhaustif final et comparaison scalaire de plusieurs positions de chaque tranche. |
| Chargement de shader de développement | Lecture de la seule ressource embarquée, bornée à 16 Kio, sans liens symboliques ni remplacement via dossier courant ou environnement. SHA-256 attendu fixé dans le code. CryptoKit est fourni par Apple. |
| Durée et ressources Metal | Horodatages GPU positifs, finis, ordonnés et cohérents avec le temps hôte. Aucun débit extrapolé en remplacement. Pools autorelease par commande et durée de vie explicite des propriétaires des vues mémoire. |
| Observateurs perturbant le chronométrage | Progression du runner transmise par une file asynchrone avec une seule mise à jour en attente. Attentes de synchronisation hors des fenêtres de calcul. Lecture IOKit lente séparée du verrou de consultation rapide des conditions. |
| Fin CPU retardée par le coordinateur | Débit final calculé avec le dernier lot effectivement terminé par les workers, plutôt qu'avec le réveil tardif du coordinateur. |
| Temps mémoire/latence incluant les callbacks | Somme des intervalles des appels aux noyaux C ; allocation, premier accès, calibration, contrôle et callbacks exclus. Les octets et accès proviennent du travail réellement terminé. |
| Horloge civile ajustée pendant la session | Durée totale monotone conservée dans le rapport, vérifiée contre l'observation finale. Un changement d'heure civile n'altère pas cette durée. Les anciens rapports dépourvus de cette durée conservent leurs contrôles chronologiques. |
| Interface et E/S pendant une mesure | Moteurs dans Task.detached ; chargement/sauvegarde/export hors du MainActor ; lancement interdit pendant l'export ou le chargement initial. Annulation coopérative et jonction des workers avant retour. |
| Valeurs extrêmes dans les graphiques | Normalisation des valeurs avant calcul des coordonnées, filtrage des non-finis et bornage de la série : une valeur JSON finie proche de Double.max ne provoque plus d'addition débordante. |

Les données applicatives sont stockées sous le dossier Application Support fourni par Foundation dans le conteneur `org.benchlibre.mac`, avec Reports, Exports et Temporary. L'application lit aussi son propre bundle signé et utilise les ressources système autorisées par macOS. Il ne serait pas exact de promettre qu'un programme macOS ne lit littéralement aucun framework ou fichier système hors de son conteneur de données.

Aucun droit réseau client/serveur, accès aux fichiers choisis par l'utilisateur, automation, accès à Downloads, exception de bibliothèque, JIT ou droit de débogage n'est accordé. Il n'existe aucun téléchargement de code ou transmission de résultats. La révélation dans Finder et la copie au presse-papiers résultent d'une action explicite.

## Mémoire et calcul

- CPU : tableaux locaux bornés ; au plus 4 194 304 itérations par appel. Huit chaînes SIMD FP32 de quatre voies, 64 FLOP par itération.
- Triade mémoire : trois allocations séparées de 64 Mio, soit 192 Mio, libérées par defer ; validation complète des résultats et checksum consommé.
- Latence : 64 Mio de nœuds espacés de 64 octets, ordre temporaire d'environ 4 Mio et bitmap de validation borné. Le graphe opaque est créé, vérifié puis immuable ; chaque lot de production est limité à 65 536 lectures. L'index final est consommé et comparé à une traversée de référence.
- GPU : entrées de 512 Kio et sorties d'au plus 32 Mio ; limites du périphérique vérifiées. Le travail est terminé avant lecture hôte et libération.
- Fichier : deux tampons de 64 Mio maximum, fichier temporaire de 64 Mio, accès par blocs bornés, gestion des lectures/écritures partielles et d'EINTR. F_NOCACHE est obligatoire. Les fenêtres d'écriture comprennent fsync ; le budget mesuré est plafonné à 512 Mio par passage, plus 64 Mio de préparation.

Les charges s'exécutent successivement. Les allocations C sont explicitement libérées ; les objets Swift/Metal suivent leurs propriétaires et les pools locaux. Les essais ne signalent pas de débordement, use-after-free ou double libération dans les chemins exercés. Ils ne constituent pas une preuve formelle d'absence de fuite ni un profilage Instruments de plusieurs heures.

Les workers CPU demandent une QoS userInitiated et une activité utilisateur via ProcessInfo. macOS décide de leur placement sur les cœurs Performance/Efficacité. Une API publique ne permet pas de certifier une occupation physique de 100 %, une fréquence fixe ou une affinité P/E forcée. Le test mémoire est volontairement mono-thread. Aucun chiffre d'utilisation, température en °C ou consommation en watts n'est fabriqué.

## Vérifications réalisées

Sur Apple M2, macOS 27.2.1, avec Swift 6 et le SDK Xcode installé :

- Suite complète Release : **66 tests, zéro échec, aucun test ignoré**.
- Même suite avec AddressSanitizer : **66 tests, zéro échec** ; le test Metal réel est exécuté.
- Harnais C optimisé avec AddressSanitizer et UndefinedBehaviorSanitizer : **64 cycles** d'allocation/calcul/validation/destruction, entrées nulles et tailles excessives ; sortie normale, aucun diagnostic des analyseurs.
- Inspection de l'assembleur Clang -O3 : huit FMA vectorielles dans la boucle CPU et lectures à adresses dépendantes dans la boucle de latence.
- Application native Release universelle arm64/x86_64 construite ; exécution validée sur arm64 uniquement.
- Signature locale vérifiée avec contrôle strict des ressources. Drapeaux observés : adhoc et runtime. Entitlement observé : App Sandbox seul.
- Diagnostic du binaire signé : politique acceptée, sandbox/runtime actifs, aucun droit réseau ou fichier externe ; chemins dans le conteneur réel.
- Exécution courte des **six moteurs** : six résultats validés, aucune omission, export dans le conteneur.
- Nom d'export `../BenchLibre-external.json` refusé avant calcul.
- Copie de test resignée avec un droit réseau supplémentaire : démarrage refusé, code de sortie 78.

Les valeurs de l'exécution courte vérifient le fonctionnement, pas les performances de référence. La machine exécutait aussi des outils de développement. Les tests d'optimisation/instrumentation servent à la validité et à la sûreté ; les mesures instrumentées ne doivent pas être comparées aux mesures Release normales.

La vérification visuelle de la nouvelle interface n'a pas pu être achevée : le contrôle macOS de l'ancienne instance a renvoyé des délais dépassés et refusé les actions. Aucun succès d'installation par remplacement ou de test visuel 0.3 n'est revendiqué. La version 0.2 et ses anciennes archives sont conservées ; la nouvelle version est livrée séparément. Quitter l'ancienne instance avant d'ouvrir la nouvelle application.

## Dépendances et MIT

**Zéro dépendance tierce de package ou binaire embarqué tiers.** BenchLibre, BenchCore, BenchKernels et Compute.metal sont les composants propres au projet sous MIT. Les frameworks SwiftUI, AppKit, Foundation, Dispatch, Metal, IOKit.ps, CryptoKit, Security et Darwin sont fournis par Apple et restent soumis à leurs propres licences/conditions du SDK. XCTest et les analyseurs sont des outils de développement. L'icône est une ressource locale créée pour le projet. L'inventaire détaillé figure dans [DEPENDENCIES.md](DEPENDENCIES.md).

Aucun paquet ancien ou suspect n'a été identifié. Cette conclusion porte sur cet inventaire précis, sans garantie sur une chaîne de compilation compromise ou de futures dépendances.

## Limites restantes et distribution

1. **Signature ad hoc locale, sans Developer ID ni notarisation.** La validation de signature n'atteste pas d'une identité développeur reconnue par Gatekeeper. Une distribution publique devra être signée avec une identité Developer ID appropriée, puis notariée et vérifiée. Rien n'a été soumis à Apple ou VirusTotal.
2. **Aucune garantie de zéro faux positif.** XProtect, Gatekeeper et les moteurs VirusTotal ont des rôles et règles différents, susceptibles d'évoluer. Un avertissement de développeur non identifié ne constitue pas à lui seul une détection de malware. Les protections macOS et la quarantaine n'ont pas été désactivées.
3. **Pas d'authentification matérielle des scores.** Les contrôles vérifient les calculs et la cohérence du JSON ; une personne qui contrôle le client peut fabriquer un rapport. Le hash du shader ne résout pas cette limite.
4. **Variations du matériel et de l'OS.** Autres Mac, exécution Intel, macOS 14 et longues sessions sous pression mémoire restent à valider. Le produit compilé contient les deux architectures ; cela ne prouve pas leur équivalence mesurée.
5. **Observabilité partielle.** État thermique public, économie d'énergie et alimentation sont échantillonnés environ chaque seconde. Des transitions courtes, des processus concurrents ou du throttling peuvent échapper au journal. Les E/S mesurent le fichier et les caches matériels éventuels, pas le bus physique du SSD ; fsync ne certifie pas la persistance face à une perte d'alimentation.
6. **Frontière de confiance.** Les accès sécurisés réduisent les risques liés aux fichiers malformés et aux liens, mais ne protègent pas contre un OS compromis ou un processus disposant déjà des droits nécessaires sur le conteneur. La cohérence des rapports n'est pas un mécanisme anti-triche.
7. **Historique de l'ancienne version.** Aucune lecture ou migration automatique hors du nouveau conteneur. Les anciens rapports restent à leur emplacement ; leur copie manuelle avec Finder est possible, sous réserve des contrôles de lecture.

## Références Apple

- [Configuration App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox).
- [Configuration Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime).
- [Protection contre les logiciels malveillants : Gatekeeper, notarisation et XProtect](https://support.apple.com/guide/security/protecting-against-malware-sec469d47bd8/web).

Les déclarations ci-dessus reposent également sur les en-têtes publics du SDK local et les sorties de validation conservées dans le dossier de travail.
