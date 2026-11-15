# Protocole de mesure — BenchLibre

## Identifier un passage

Le rapport JSON conserve la version de format, la version de charge (`workloadVersion`), la version de l'application, les dates de début et de fin et les paramètres. Il décrit aussi le modèle, la puce, le GPU, la mémoire, les cœurs logiques, l'architecture, macOS et l'alimentation.

La version d’application **0.2.0** utilise le **format 2** et la charge **`benchlibre-suite-v2`**. `results` contient un résultat représentatif par test terminé, `trials` les passages complets bruts, `summaries` leur synthèse, `conditions` les observations du Mac et `omissions` les tests indisponibles avec leur raison. Les passages complets précédant l’indisponibilité d’un test restent dans `trials` ; ce test incomplet ne reçoit pas de résultat médian ni de synthèse complète.

Le format 1 reste pris en charge. Ses nouveaux champs absents restent absents ; un nombre de passages non enregistré est interprété comme 1. Une migration de lecture ne crée pas rétrospectivement des observations ou des répétitions.

Comparer seulement des passages utilisant la **même version de charge**, les mêmes tests et les mêmes paramètres. Une modification du noyau, du nombre d'opérations, de la taille des buffers, du compilateur ou du périmètre chronométré peut changer l'interprétation d'un résultat.

## Chronométrage et débit

Les moteurs utilisent une horloge monotone pour délimiter le passage. La préparation des ressources, la compilation des shaders, la calibration, l’échauffement et les validations hors chronométrage sont exclus de la mesure rapportée. Pour CPU, mémoire et latence, `elapsedSeconds` décrit la fenêtre murale de la boucle mesurée. Pour le GPU, le débit utilise les horodatages GPU cumulés : `timingSeconds` peut donc différer de la fenêtre murale. Pour les E/S fichier, `elapsedSeconds` et `timingSeconds` désignent la somme des fenêtres chronométrées, en excluant les validations intercalées. Les détails de chaque résultat précisent le périmètre utilisé.

Chaque résultat conserve `workAmount`, `workUnit`, `timingSeconds` et `timingSource`. Les débits se recalculent par travail / temps / 10⁹ ; la latence se recalcule par temps / accès × 10⁹. Les bornes `startedAtSeconds` et `endedAtSeconds` de chaque `trial` utilisent l’époque monotone du journal des conditions et couvrent l’invocation complète du moteur, préparation et validation incluses.

Le débit d'ensemble se calcule à partir du travail total et du temps total correspondant. Une moyenne non pondérée d'échantillons de durées différentes ne représente pas ce même débit. Les échantillons servent à observer la variabilité de la charge pendant le passage.

Les durées de mesure des profils sont de **2,5**, **10** et **30 secondes par passage et par test**. La durée réelle peut dépasser légèrement la cible pour terminer un lot déjà engagé. Les E/S peuvent finir plus tôt lorsqu’elles atteignent leur budget d’octets. La durée totale de session inclut la préparation et les changements de phase.

## Répétitions et statistiques

Le nombre de passages est **1, 3 ou 5**, avec 3 par défaut. La sélection par défaut contient CPU, GPU Metal, bande passante mémoire et latence ; les tests fichier s’activent explicitement. Le mode de vérification `--smoke` utilise un seul passage par défaut.

Chaque test est répété le nombre demandé avant de passer au test suivant. Une synthèse porte sur les valeurs finales des passages complets, sans pondération par leur durée. Avec un nombre impair de passages, la médiane est exactement la valeur d’un passage réel. Le résultat représentatif, ses compteurs, sa durée et ses échantillons proviennent tous de ce même passage ; des compteurs issus de passages différents ne sont pas combinés.

La synthèse conserve le nombre de passages, la médiane, le minimum, le maximum, l’écart-type d’échantillon corrigé (diviseur n − 1) et le coefficient de variation, **100 × écart-type / moyenne arithmétique**. Ces deux dernières statistiques ne sont pas définies avec un seul passage et restent absentes. Les échantillons à l’intérieur d’un passage sont distincts de ces statistiques entre passages. Aucun passage atypique n’est exclu automatiquement.

## CPU — calcul FP32 multicœur

La charge utilise **8 chaînes indépendantes de 4 voies FP32 par worker**. Les workers demandés exécutent le même noyau ; leur nombre est conservé dans la configuration. Le nombre d’itérations par lot est calibré avant la mesure pour permettre une interruption rapide.

- **GFLOP/s** = opérations flottantes comptées / secondes chronométrées / 10⁹.
- Une multiplication-addition fusionnée, `a × b + c`, compte pour **deux** opérations flottantes.
- Chaque itération exécute 8 × 4 FMA, soit **64 opérations flottantes**.
- Le débit est la somme des opérations de tous les workers divisée par le temps monotone écoulé.
- Une référence scalaire vérifie les 32 voies sur un petit lot ; le checksum des lots mesurés est consommé et doit rester fini.
- Les sorties sont consommées et contrôlées pour empêcher l'élimination du calcul comme travail inutilisé.

Le résultat représente le noyau FP32 de BenchLibre. Il dépend notamment du compilateur, de la vectorisation, des fréquences, du nombre de workers et de la répartition de la charge entre les cœurs.

## GPU — calcul Metal FP32

Le noyau Metal utilise des entrées dépendantes de l'exécution et écrit des résultats lus pour validation. La préparation des buffers et la création du pipeline ne font pas partie du débit de calcul.

Le temps GPU provient des horodatages du `MTLCommandBuffer` terminé. Des horodatages absents, non finis ou non positifs doivent rendre la mesure indisponible plutôt que produire un débit inventé. Un temps de soumission mesuré sur le CPU n'est pas interchangeable avec un temps d'exécution GPU.

Chaque dispatch mesuré exécute **32 768 threads × 512 itérations × 16 FMA × 2 opérations**, soit **536 870 912 FLOP**. Ces dimensions restent fixes entre les Mac. La calibration change seulement le nombre de dispatchs regroupés dans une commande.

Le débit est la somme des FLOP comptés divisée par la somme des durées GPU correspondantes. L'initialisation et la réduction du résultat ne sont pas ajoutées au compte de FLOP, bien qu'elles appartiennent au noyau chronométré. Une référence CPU contrôle **7 positions × 4 composantes**, soit 28 composantes, avant et après la mesure ; ce contrôle est échantillonné, pas exhaustif sur toutes les sorties. Le champ `details` rappelle les dimensions de la charge et le périmètre du chronométrage.

Ce test ne rend pas une scène de jeu. Il n'évalue pas la synchronisation verticale, les FPS d'affichage, les textures, le ray tracing, les interpolations d'images ou la performance d'une application réelle.

## Mémoire — bande passante logique

- **Go/s** utilise des gigaoctets décimaux : **1 Go = 10⁹ octets**.
- Le noyau est une triade **mono-thread** : `A[i] = B[i] + 3 × C[i]`.
- Trois tableaux de **64 Mio** représentent un ensemble de travail de **192 Mio**.
- Chaque élément traite deux lectures FP32 et une écriture FP32 : **12 octets logiques**. Un passage complet compte **192 Mio**, soit 201 326 592 octets logiques.
- Le débit est le total de ces octets logiques divisé par le temps monotone écoulé.
- Le résultat complet est vérifié, avec un checksum de référence ; cette validation, l’allocation et le premier accès sont exclus de la fenêtre mesurée.
- Le champ `details` précise le nombre de passages réalisés.
- Les buffers sont dimensionnés pour dépasser les petits caches ; leur trafic passe toutefois toujours par la hiérarchie mémoire de la machine.

Ce chiffre n'est pas une lecture du compteur de trafic DRAM. Les caches, la cohérence et les stratégies d'écriture du processeur peuvent faire différer le trafic physique du nombre d'octets logiques.

## Mémoire — latence des accès dépendants

La charge **Pointer-chase-v1** utilise un cycle aléatoire déterministe de **1 048 576 indices UInt32** dans un ensemble de travail de **64 Mio**. Chaque nœud occupe un emplacement espacé de **64 octets**, avec la graine `0x4c4154454e435931`. Cet espacement fait partie du protocole et n’est pas une hypothèse sur la taille réelle des lignes de cache de la machine.

Chaque lecture dépend de l’index obtenu par la précédente. Le noyau consomme l’index final et compte les accès effectivement exécutés. Le résultat est **ns/accès = secondes mesurées / accès dépendants × 10⁹** ; une valeur plus basse est meilleure. La boucle murale inclut les appels au noyau et le contrôle des lots. Le nombre d’accès par lot est calibré et borné ; la taille de l’ensemble de travail reste fixe.

L’allocation, la création du cycle, une traversée complète d’échauffement, la calibration et les validations sont exclues de la fenêtre mesurée. Le cycle complet est contrôlé et l’index final est comparé à une traversée scalaire de référence. Le nombre d’accès, la durée et l’index final restent dans le rapport.

Ce test mesure la latence effective de cette charge à travers la hiérarchie mémoire. Il ne certifie pas une latence physique de DRAM, et l’ensemble de 64 Mio n’est pas garanti hors de tous les caches sur chaque modèle.

## Stockage — E/S séquentielles de fichier

Les tests **`disk-read`** et **`disk-write`** utilisent chacun un fichier propre de **64 Mio**, dans un dossier temporaire unique du volume choisi par macOS pour ses fichiers temporaires. Ils ne ciblent pas directement un périphérique brut et ne permettent pas de sélectionner un disque externe dans cette version. Le fichier et son dossier sont supprimés à la fin, y compris après annulation ou erreur ; aucun autre fichier n’est utilisé.

Les transferts s’effectuent par blocs de **1 Mio**, avec gestion des appels partiels et interruptions. Des données pseudo-aléatoires déterministes sont préparées hors chronométrage. Chaque invocation écrit initialement **64 Mio**, effectue un `fsync`, relit et vérifie le fichier avant la mesure. Cette préparation est exclue des débits.

Le descripteur utilise **`F_NOCACHE`**. Si ce réglage échoue, le test est signalé indisponible. Il désactive le cache de données pour le descripteur ; les effets du système de fichiers et des caches du contrôleur ou du périphérique peuvent toujours influencer le résultat. Aucune garantie de contournement de ces caches ou de persistance physique sur le support n’est déduite.

- **Lecture :** chaque fenêtre chronomètre le repositionnement et la lecture complète du fichier. Tous les octets sont comparés au tampon de référence après la fenêtre ; cette validation et le checksum sont exclus du temps d’E/S. Le budget de lectures mesurées est **64 Gio par invocation**.
- **Écriture :** chaque fenêtre chronomètre le repositionnement, la réécriture complète et le `fsync` associé. Le budget d’écritures mesurées est **512 Mio par invocation**, en plus des 64 Mio de préparation. Le contenu final est relu et vérifié hors chronométrage.

La mesure s’arrête à la durée cible ou au budget d’octets, après un fichier complet. Le rapport précise la raison de terminaison. Les limites s’appliquent à chaque passage : plusieurs répétitions multiplient les E/S. Le débit est **Go/s = octets logiques transférés / somme des fenêtres mesurées / 10⁹**. Les progressions et contrôles de boucle à l’intérieur des fenêtres appartiennent au coût mesuré ; les intervalles de validation intercalés n’y appartiennent pas.

Ces résultats décrivent les E/S de cette charge sur le volume temporaire. Ils ne sont pas une mesure isolant le bus SSD, son débit constructeur ou le trafic physique exact du support.

## Vérification numérique

Les moteurs effectuent des contrôles de cohérence et exposent un checksum. Les débits et latences doivent être finis et strictement positifs. Un calcul qui échoue à sa validation interrompt la session, sans créer de rapport complet validé.

Une session annulée ne doit pas être présentée comme un passage complet validé. De même, un GPU absent ou une fonctionnalité indisponible doit être distingué d'un résultat faible.

## Conditions du Mac

L’alimentation, le mode économie d’énergie et l’état thermique sont enregistrés au début, environ **une fois par seconde**, puis à la fin de la session, avec un horodatage monotone. Des callbacks retardés par la charge peuvent espacer les observations ; un changement bref entre deux observations peut être manqué. Le journal est borné à **10 000 observations**, en conservant la première et les observations les plus récentes lorsque la limite est atteinte.

Un état thermique non nominal, un mode économie d’énergie observé ou un changement d’alimentation sont signalés dans les notes. L’état thermique est le niveau fourni par macOS, **pas une température en °C**. Deux niveaux identiques ne garantissent pas une température ou des fréquences constantes. Ce journal documente les conditions observées, sans certifier l’absence de bridage ni l’authenticité physique d’un résultat.

Pendant une session, BenchLibre déclare une activité utilisateur à macOS pour éviter App Nap et la veille automatique d’inactivité. Cette activité prend fin à la réussite, à l’arrêt ou à l’échec du passage. Elle ne garantit pas la poursuite d’un test lorsque le capot est fermé ou que la mise en veille est forcée.

Pour une comparaison pratique :

1. Utiliser la même version Release et les mêmes réglages.
2. Conserver la même alimentation et le même mode d'énergie.
3. Fermer les jeux et les tâches intensives qui disputent le CPU, le GPU ou la mémoire.
4. Attendre que les conditions thermiques se stabilisent entre les passages.
5. Effectuer plusieurs passages et examiner les échantillons plutôt qu'un nombre isolé.

Les résultats ne sont pas agrégés en un score universel. Les six mesures exercent des chemins différents du matériel ; leurs unités restent visibles. La charge CPU de cette version reste du calcul FP32. Le rendu 3D, le ray tracing matériel, l’inférence IA/NPU, les capteurs avancés et une base mondiale sont des étapes de développement futures.
