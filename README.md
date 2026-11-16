# GOPS

Application Flutter de gestion personnelle d'interventions. Les données sont stockées dans une base SQLite chiffrée et les secrets dans le stockage sécurisé du système. Les photos peuvent être préparées localement puis jointes à des courriels via l'application mail du téléphone, après validation de l'utilisateur.

## Démarrage

1. Avoir Flutter stable et les outils Android/iOS installés.
2. Exécuter `flutter pub get`, puis `flutter run`.
3. Si les dossiers natifs sont régénérés, exécuter `powershell -ExecutionPolicy Bypass -File .\tool\configure-platforms.ps1` pour appliquer les permissions photo/Face ID, l'écran protégé des captures et les réglages SQLCipher natifs.

Les dossiers natifs Android et iOS sont inclus. Sur iOS, ouvrir `ios/Runner.xcworkspace` avec Xcode. La configuration scriptée doit être revue avec les versions Android/iOS ciblées avant diffusion.

## Première ouverture

Créer un PIN de 6 chiffres ou plus. Pour la prise en main, saisir uniquement des exemples fictifs. Ne pas saisir de données opérationnelles avant validation institutionnelle des traitements et de l'appareil.

## Fonctions présentes dans la V1

- Verrouillage PIN, temporisation progressive et biométrie si disponible.
- Base locale chiffrée, fiches datées, sauvegarde automatique des formulaires.
- Liste et recherche d'interventions.
- Sections générales, identités, véhicules, photographies et compte rendu.
- Import/capture et copie des photos dans le stockage privé.
- Export PDF local partageable via le dialogue système.
- Envoi des photos par courriel, avec réduction des images et répartition en lots de moins de 5 Mo.
- Association de véhicules à une ou plusieurs identités.

## Limites à valider avant usage réel

Cette base constitue un socle logiciel, pas une homologation de sécurité. La récupération du PIN repose sur le secret de chiffrement conservé par le système : aucune procédure de récupération distante n'existe. Le chiffrement de la base dépend de SQLCipher fourni par `sqflite_sqlcipher`. Vérifier les réglages générés, le verrouillage et la protection de l'aperçu sur chaque version Android/iOS ciblée. Les tests de sécurité et la validation institutionnelle restent indispensables.
