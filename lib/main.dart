import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pd;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import 'data/database.dart';
import 'data/intervention_bundle_service.dart';
import 'ai/cro_ai_service.dart';
import 'security/security_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GopsApp());
}

const navy = Color(0xFF10243A);
const background = Color(0xFF101820);
const surface = Color(0xFF1B2732);
const blue = Color(0xFF69B9F4);

DateTime? _parseDate(String value) {
  final raw = value.trim();
  final iso = DateTime.tryParse(raw);
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final parts = raw.split(RegExp(r'[/.-]'));
  if (parts.length != 3) return null;
  final day = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final year = int.tryParse(parts[2]);
  if (day == null || month == null || year == null) return null;
  final date = DateTime(year, month, day);
  if (date.day != day || date.month != month || date.year != year) return null;
  return date;
}

String _displayDate(Object? value) {
  final raw = (value ?? '').toString().trim();
  final date = _parseDate(raw);
  return date == null ? raw : DateFormat('dd/MM/yyyy').format(date);
}

String _storedDate(String value) {
  final date = _parseDate(value);
  return date == null ? value.trim() : DateFormat('yyyy-MM-dd').format(date);
}

Uint8List _compressPhotoForEmail(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('Image illisible.');
  decoded.exif = img.ExifData();
  decoded.iccProfile = null;
  decoded.textData = null;
  var image = decoded;
  for (final maxDimension in [1600, 1200, 900, 700]) {
    if (image.width > maxDimension || image.height > maxDimension) {
      image = img.copyResize(
        image,
        width: image.width >= image.height ? maxDimension : null,
        height: image.height > image.width ? maxDimension : null,
      );
    }
    for (final quality in [78, 68, 58, 48, 38]) {
      final result = img.encodeJpg(image, quality: quality);
      if (result.length <= 2_500_000) return Uint8List.fromList(result);
    }
  }
  throw StateError(
    'Cette photo est trop volumineuse pour être jointe à un e-mail.',
  );
}

class GopsApp extends StatefulWidget {
  const GopsApp({super.key});
  @override
  State<GopsApp> createState() => _GopsAppState();
}

class _GopsAppState extends State<GopsApp> with WidgetsBindingObserver {
  bool _ready = false;
  bool _locked = true;
  DateTime _lastActivity = DateTime.now();
  DateTime? _backgroundedAt;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _idleTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _checkIdle(),
    );
    _initialize();
  }

  Future<void> _checkIdle() async {
    if (!_ready || _locked || !await SecurityService.instance.hasPin) return;
    final timeout = await SecurityService.instance.lockTimeoutMinutes();
    if (DateTime.now().difference(_lastActivity) >=
            Duration(minutes: timeout) &&
        mounted) {
      setState(() => _locked = true);
    }
  }

  Future<void> _initialize() async {
    await GopsDatabase.instance.initialize();
    if (mounted) setState(() => _ready = true);
  }

  void touch() => _lastActivity = DateTime.now();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed && _backgroundedAt != null) {
      final timeout = await SecurityService.instance.lockTimeoutMinutes();
      if (DateTime.now().difference(_backgroundedAt!) >=
              Duration(minutes: timeout) ||
          DateTime.now().difference(_lastActivity) >=
              Duration(minutes: timeout)) {
        if (mounted) setState(() => _locked = true);
      }
      _backgroundedAt = null;
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'GOPS',
    locale: const Locale('fr', 'FR'),
    supportedLocales: const [Locale('fr', 'FR')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      colorScheme: const ColorScheme.dark(
        primary: blue,
        secondary: blue,
        surface: surface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: navy,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: const CardThemeData(
        color: surface,
        margin: EdgeInsets.symmetric(vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white12),
        ),
      ),
      useMaterial3: true,
    ),
    builder: (context, child) => Listener(
      onPointerDown: (_) => touch(),
      child: child ?? const SizedBox.shrink(),
    ),
    home: !_ready
        ? const Scaffold(body: Center(child: CircularProgressIndicator()))
        : FutureBuilder<bool>(
            future: SecurityService.instance.hasPin,
            builder: (context, snapshot) {
              if (!snapshot.hasData)
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              if (!snapshot.data!)
                return PinSetup(
                  onCreated: () => setState(() {
                    _locked = false;
                    touch();
                  }),
                );
              return _locked
                  ? PinUnlock(
                      onUnlocked: () => setState(() {
                        _locked = false;
                        touch();
                      }),
                    )
                  : HomePage(
                      onActivity: touch,
                      onLock: () => setState(() => _locked = true),
                      onReset: () => setState(() => _locked = true),
                    );
            },
          ),
  );
}

class PinSetup extends StatefulWidget {
  const PinSetup({required this.onCreated, super.key});
  final VoidCallback onCreated;
  @override
  State<PinSetup> createState() => _PinSetupState();
}

class _PinSetupState extends State<PinSetup> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;
  Future<void> _submit() async {
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'Les deux codes ne correspondent pas.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await SecurityService.instance.createPin(_pin.text);
      await GopsDatabase.instance.db;
      widget.onCreated();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('ArgumentError: ', ''));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Image.asset(
                  'assets/gops_logo.png',
                  width: 128,
                  height: 128,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Bienvenue dans GOPS',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              const Text(
                'Choisissez un code PIN personnel de 6 chiffres minimum.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _pin,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Nouveau PIN'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _confirm,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Confirmer le PIN',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? 'Initialisation…' : 'Créer mon accès'),
              ),
              const SizedBox(height: 20),
              const Text(
                '',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class PinUnlock extends StatefulWidget {
  const PinUnlock({required this.onUnlocked, super.key});
  final VoidCallback onUnlocked;
  @override
  State<PinUnlock> createState() => _PinUnlockState();
}

class _PinUnlockState extends State<PinUnlock> {
  final _pin = TextEditingController();
  String? _message;
  bool _busy = false;
  Future<void> _tryPin() async {
    setState(() => _busy = true);
    final failures = await SecurityService.instance.failedAttempts();
    final wait = failures < 3 ? 0 : (1 << ((failures - 3).clamp(0, 8) as int));
    if (wait > 0) await Future<void>.delayed(Duration(seconds: wait));
    if (await SecurityService.instance.verifyPin(_pin.text)) {
      await SecurityService.instance.resetFailures();
      widget.onUnlocked();
    } else {
      await SecurityService.instance.recordFailure();
      if (mounted) setState(() => _message = 'Code incorrect. Réessayez.');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _biometric() async {
    if (await SecurityService.instance.authenticateBiometrically())
      widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_outline, size: 60, color: blue),
              const SizedBox(height: 12),
              Text(
                'GOPS verrouillé',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 22),
              TextField(
                controller: _pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Code PIN'),
                onSubmitted: (_) => _tryPin(),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _message!,
                    style: const TextStyle(color: Colors.redAccent),
                  ),
                ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _tryPin,
                child: const Text('Déverrouiller'),
              ),
              FutureBuilder<bool>(
                future: SecurityService.instance.biometricEnabled,
                builder: (context, s) => s.data == true
                    ? TextButton.icon(
                        onPressed: _biometric,
                        icon: const Icon(Icons.fingerprint),
                        label: const Text('Utiliser la biométrie'),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({
    required this.onActivity,
    required this.onLock,
    required this.onReset,
    super.key,
  });
  final VoidCallback onActivity, onLock, onReset;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _search = TextEditingController();
  String _query = '';
  Future<List<Map<String, Object?>>> _load() =>
      GopsDatabase.instance.interventions(query: _query);
  Future<void> _refresh() async => setState(() {});

  Future<void> _importIntervention() async {
    try {
      final picked = await FilePicker.pickFile(
        dialogTitle: 'Importer une fiche GOPS',
        // iOS Files greys out custom .gops files because they have no system UTI.
        // Accept any file here; the bundle service validates its actual contents.
        type: FileType.any,
      );
      if (picked == null) return;
      final bundleSize = await picked.length();
      if (bundleSize != null && bundleSize > 256 * 1024 * 1024) {
        throw const FormatException(
          'Le fichier GOPS dépasse la taille maximale de 256 Mo.',
        );
      }
      final id = await InterventionBundleService.importBundle(
        await picked.readAsBytes(),
      );
      if (!mounted) return;
      widget.onActivity();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Fiche importée.')));
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InterventionEditor(
            id: id,
            onSaved: _refresh,
            onLock: widget.onLock,
          ),
        ),
      );
      _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import impossible : $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/gops_logo.png', width: 36, height: 36),
          ),
          const SizedBox(width: 10),
          const Text('GOPS'),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Importer une fiche GOPS',
          onPressed: _importIntervention,
          icon: const Icon(Icons.file_open_outlined),
        ),
        IconButton(
          tooltip: 'Paramètres',
          onPressed: () async {
            widget.onActivity();
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SettingsPage(onReset: widget.onReset),
              ),
            );
            _refresh();
          },
          icon: const Icon(Icons.settings_outlined),
        ),
        IconButton(
          tooltip: 'Verrouiller',
          onPressed: widget.onLock,
          icon: const Icon(Icons.lock_outline),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () async {
        widget.onActivity();
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => InterventionEditor(onSaved: _refresh),
          ),
        );
        _refresh();
      },
      icon: const Icon(Icons.add),
      label: const Text('Nouvelle intervention'),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (v) {
              setState(() => _query = v);
              widget.onActivity();
            },
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Rechercher nature, date ou lieu',
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, Object?>>>(
            future: _load(),
            builder: (context, snapshot) {
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final rows = snapshot.data!;
              if (rows.isEmpty)
                return EmptyState(isSearching: _query.isNotEmpty);
              return RefreshIndicator(
                onRefresh: () async => _refresh(),
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 96),
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final nature = (row['nature'] as String? ?? '').trim();
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        title: Text(
                          nature.isEmpty
                              ? 'Intervention sans intitulé'
                              : nature,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_displayDate(row['date'])} · ${row['time']} · ${row['location']}',
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${row['identity_count']} identité(s)  ·  ${row['vehicle_count']} véhicule(s)  ·  ${row['photo_count']} photo(s)',
                                style: const TextStyle(color: Colors.white60),
                              ),
                            ],
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          widget.onActivity();
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => InterventionEditor(
                                id: row['id']! as String,
                                onSaved: _refresh,
                                onLock: widget.onLock,
                              ),
                            ),
                          );
                          _refresh();
                        },
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({required this.isSearching, super.key});
  final bool isSearching;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isSearching ? Icons.search_off : Icons.folder_open,
            size: 52,
            color: Colors.white38,
          ),
          const SizedBox(height: 14),
          Text(
            isSearching
                ? 'Aucune fiche ne correspond à la recherche.'
                : 'Aucune intervention enregistrée.\nCréez votre première fiche.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60),
          ),
        ],
      ),
    ),
  );
}

class InterventionEditor extends StatefulWidget {
  const InterventionEditor({
    this.id,
    required this.onSaved,
    this.onLock,
    super.key,
  });
  final String? id;
  final VoidCallback onSaved;
  final VoidCallback? onLock;
  @override
  State<InterventionEditor> createState() => _InterventionEditorState();
}

class _InterventionEditorState extends State<InterventionEditor>
    with SingleTickerProviderStateMixin {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _picker = ImagePicker();
  late final TabController _tabs;
  Timer? _debounce;
  String? _id;
  String _saveState = 'Chargement…';
  bool _loading = true;
  bool _sendingPhotos = false;
  bool _generatingCro = false;
  int _croModelDownloadProgress = 0;
  List<Map<String, Object?>> _identities = [], _vehicles = [], _photos = [];
  final _fields = const [
    'date',
    'time',
    'location',
    'nature',
    'observations',
    'report',
  ];
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 5, vsync: this);
    for (final f in _fields) {
      _controllers[f] = TextEditingController()..addListener(_scheduleSave);
    }
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _tabs.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    Map<String, Object?>? data;
    if (widget.id != null) {
      data = await GopsDatabase.instance.intervention(widget.id!);
      _id = widget.id;
    }
    final now = DateTime.now();
    final values =
        data ??
        {
          'id': DateTime.now().microsecondsSinceEpoch.toString(),
          'reference': '',
          'date': DateFormat('dd/MM/yyyy').format(now),
          'time': DateFormat('HH:mm').format(now),
          'location': '',
          'nature': '',
          'observations': '',
          'report': '',
          'created_at': now.toIso8601String(),
        };
    _id ??= values['id'] as String;
    for (final f in _fields) {
      _controllers[f]!.text = f == 'date'
          ? _displayDate(values[f])
          : (values[f] ?? '').toString();
    }
    await _reloadChildren();
    if (mounted)
      setState(() {
        _loading = false;
        _saveState = data == null ? 'Nouveau brouillon' : 'Enregistré';
      });
    if (data == null) await _save();
  }

  Future<void> _reloadChildren() async {
    final db = GopsDatabase.instance;
    _identities = await db.rows('identities', _id!);
    _vehicles = await db.rows('vehicles', _id!);
    _photos = await db.photos(_id!);
    if (mounted) setState(() {});
  }

  void _scheduleSave() {
    if (_loading) return;
    setState(() => _saveState = 'Enregistrement…');
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    try {
      final now = DateTime.now().toIso8601String();
      final existing = await GopsDatabase.instance.intervention(_id!);
      await GopsDatabase.instance.saveIntervention({
        'id': _id,
        'reference': existing?['reference'] ?? '',
        'date': _storedDate(_controllers['date']!.text),
        'time': _controllers['time']!.text.trim(),
        'location': _controllers['location']!.text.trim(),
        'nature': _controllers['nature']!.text.trim(),
        'observations': _controllers['observations']!.text.trim(),
        'report': _controllers['report']!.text,
        'created_at': existing?['created_at'] ?? now,
        'updated_at': now,
      });
      if (mounted) setState(() => _saveState = 'Enregistré');
      widget.onSaved();
    } catch (_) {
      if (mounted) setState(() => _saveState = 'Erreur d’enregistrement');
    }
  }

  Future<void> _addPhoto({String? identityId, String? vehicleId}) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (c) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(c, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Importer une photo'),
              onTap: () => Navigator.pop(c, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 2400,
        imageQuality: 92,
        requestFullMetadata: false,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null)
        throw const FormatException('Format d’image non reconnu.');
      decoded.exif = img.ExifData();
      decoded.iccProfile = null;
      decoded.textData = null;
      final clean = img.encodeJpg(
        decoded,
        quality: 90,
      ); // Réencodage : les métadonnées EXIF ne sont pas réutilisées.
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(docs.path, 'gops_photos'));
      await folder.create(recursive: true);
      final filename = '${DateTime.now().microsecondsSinceEpoch}.jpg';
      final file = File(p.join(folder.path, filename));
      await file.writeAsBytes(clean, flush: true);
      final description = TextEditingController();
      if (mounted)
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Description de la photo'),
            content: TextField(
              controller: description,
              decoration: const InputDecoration(hintText: 'Facultatif'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Ignorer'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Ajouter'),
              ),
            ],
          ),
        );
      await GopsDatabase.instance.saveRow('photos', {
        'id': filename,
        'intervention_id': _id,
        'identity_id': identityId,
        'vehicle_id': vehicleId,
        'local_path': file.path,
        'description': description.text.trim(),
        'category': identityId != null
            ? 'identite'
            : vehicleId != null
            ? 'vehicule'
            : 'intervention',
        'created_at': DateTime.now().toIso8601String(),
      });
      description.dispose();
      await _reloadChildren();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Photo non ajoutée : $e')));
    }
  }

  Future<void> _deletePhoto(Map<String, Object?> photo) async {
    final yes = await _confirm('Supprimer cette photographie ?');
    if (!yes) return;
    final file = File(photo['local_path']! as String);
    if (await file.exists()) await file.delete();
    await GopsDatabase.instance.deleteRow('photos', photo['id']! as String);
    await _reloadChildren();
  }

  Future<void> _editPhotoDescription(Map<String, Object?> photo) async {
    final controller = TextEditingController(
      text: (photo['description'] ?? '').toString(),
    );
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Description de la photo'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Description facultative',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (value != null) {
      await GopsDatabase.instance.updatePhotoDescription(
        photo['id']! as String,
        value.trim(),
      );
      await _reloadChildren();
    }
    controller.dispose();
  }

  Future<bool> _confirm(String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Confirmer'),
            ),
          ],
        ),
      ) ??
      false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.id == null ? 'Nouvelle intervention' : 'Intervention'),
      actions: [
        IconButton(
          tooltip: 'Exporter en PDF',
          onPressed: _exportPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
        ),
        IconButton(
          tooltip: 'Partager la fiche GOPS',
          onPressed: _shareIntervention,
          icon: const Icon(Icons.ios_share_outlined),
        ),
        IconButton(
          tooltip: 'Supprimer',
          onPressed: widget.id == null ? null : _deleteIntervention,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
      bottom: TabBar(
        controller: _tabs,
        isScrollable: true,
        tabs: const [
          Tab(text: 'Général'),
          Tab(text: 'Identités'),
          Tab(text: 'Véhicules'),
          Tab(text: 'Photos'),
          Tab(text: 'Compte rendu'),
        ],
      ),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    _general(),
                    _identitySection(),
                    _vehicleSection(),
                    _photoSection(),
                    _reportSection(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _saveState == 'Enregistré'
                          ? Icons.check_circle_outline
                          : Icons.cloud_done_outlined,
                      size: 16,
                      color: _saveState == 'Enregistré'
                          ? Colors.greenAccent
                          : Colors.white54,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _saveState,
                      style: const TextStyle(color: Colors.white60),
                    ),
                  ],
                ),
              ),
            ],
          ),
  );
  Widget _general() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      _field(
        'nature',
        'Nature / intitulé de l’intervention',
        hintText: 'Ex. VIF Dupont et Dupond - ARANDON',
      ),
      Row(
        children: [
          Expanded(
            child: _field(
              'date',
              'Date (JJ/MM/AAAA)',
              readOnly: true,
              suffix: IconButton(
                tooltip: 'Choisir une date',
                icon: const Icon(Icons.calendar_today_outlined),
                onPressed: _pickDate,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _field(
              'time',
              'Heure (HH:MM)',
              suffix: IconButton(
                tooltip: 'Choisir une heure',
                icon: const Icon(Icons.access_time),
                onPressed: _pickTime,
              ),
            ),
          ),
        ],
      ),
      _field('location', 'Lieu'),
      _field(
        'observations',
        'Bloc note',
        minLines: 6,
        maxLines: 12,
        helperText:
            'Saisissez vos notes librement. L’IA s’appuiera dessus pour rédiger et améliorer le compte rendu.',
      ),
    ],
  );
  Future<void> _pickDate() async {
    final current = _parseDate(_controllers['date']!.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      helpText: 'Date de l’intervention',
    );
    if (selected != null) {
      _controllers['date']!.text = DateFormat('dd/MM/yyyy').format(selected);
    }
  }

  Future<void> _pickTime() async {
    final pieces = _controllers['time']!.text.split(':');
    final hour = pieces.length == 2 ? int.tryParse(pieces[0]) : null;
    final minute = pieces.length == 2 ? int.tryParse(pieces[1]) : null;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: hour != null && hour >= 0 && hour < 24
            ? hour
            : TimeOfDay.now().hour,
        minute: minute != null && minute >= 0 && minute < 60 ? minute : 0,
      ),
      helpText: 'Heure de l’intervention',
    );
    if (selected != null) {
      _controllers['time']!.text =
          '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    }
  }

  Widget _field(
    String key,
    String label, {
    int maxLines = 1,
    int? minLines,
    String? hintText,
    String? helperText,
    Widget? suffix,
    bool readOnly = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: _controllers[key],
      minLines: minLines,
      maxLines: maxLines,
      readOnly: readOnly,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        helperText: helperText,
        suffixIcon: suffix,
      ),
    ),
  );
  Widget _identitySection() => _recordSection(
    'Identités',
    _identities,
    Icons.person_outline,
    () => _editRecord('identities', null),
    (row) => _editRecord('identities', row),
  );
  Widget _vehicleSection() => _recordSection(
    'Véhicules',
    _vehicles,
    Icons.directions_car_outlined,
    () => _editRecord('vehicles', null),
    (row) => _editRecord('vehicles', row),
  );
  Widget _recordSection(
    String title,
    List<Map<String, Object?>> rows,
    IconData icon,
    VoidCallback add,
    ValueChanged<Map<String, Object?>> edit,
  ) => Column(
    children: [
      Expanded(
        child: rows.isEmpty
            ? Center(child: Text('Aucun élément dans cette rubrique.'))
            : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: rows.length,
                itemBuilder: (c, i) {
                  final row = rows[i];
                  final isIdentity = title == 'Identités';
                  final headline = isIdentity
                      ? '${row['first_names']} ${row['surname']}'
                      : '${row['registration']} · ${row['make']} ${row['model']}';
                  final details = isIdentity ? row['role'] : row['color'];
                  return Card(
                    child: ListTile(
                      leading: Icon(icon, color: blue),
                      title: Text(
                        headline.trim().isEmpty
                            ? 'Fiche sans titre'
                            : headline.trim(),
                      ),
                      subtitle: Text((details ?? '').toString()),
                      onTap: () => edit(row),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) {
                          if (action == 'edit') edit(row);
                          if (action == 'photo')
                            _addPhoto(
                              identityId: isIdentity
                                  ? row['id']! as String
                                  : null,
                              vehicleId: isIdentity
                                  ? null
                                  : row['id']! as String,
                            );
                          if (action == 'delete')
                            _deleteRecord(
                              isIdentity ? 'identities' : 'vehicles',
                              row,
                            );
                        },
                        itemBuilder: (c) => const [
                          PopupMenuItem(value: 'edit', child: Text('Modifier')),
                          PopupMenuItem(
                            value: 'photo',
                            child: Text('Ajouter une photo'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('Supprimer'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton.icon(
          onPressed: add,
          icon: const Icon(Icons.add),
          label: Text('Ajouter ${title.toLowerCase()}'),
        ),
      ),
    ],
  );
  Future<void> _deleteRecord(String table, Map<String, Object?> row) async {
    if (!await _confirm('Supprimer cette fiche ?')) return;
    final id = row['id']! as String;
    for (final photo in _photos.where(
      (p) => p['identity_id'] == id || p['vehicle_id'] == id,
    )) {
      final file = File(photo['local_path']! as String);
      if (await file.exists()) await file.delete();
    }
    await GopsDatabase.instance.deleteRow(table, id);
    await _reloadChildren();
  }

  Future<void> _editRecord(String table, Map<String, Object?>? row) async {
    final identity = table == 'identities';
    final fields = identity
        ? <String, String>{
            'surname': 'Nom',
            'usage_name': 'Nom d’usage',
            'first_names': 'Prénom(s)',
            'birth_date': 'Date de naissance',
            'birth_place': 'Lieu de naissance',
            'nationality': 'Nationalité',
            'address': 'Adresse',
            'postal_code': 'Code postal',
            'city': 'Ville',
            'phone': 'Téléphone',
            'email': 'Adresse électronique',
            'role': 'Qualité',
            'observations': 'Observations',
          }
        : <String, String>{
            'registration': 'Immatriculation',
            'make': 'Marque',
            'model': 'Modèle',
            'color': 'Couleur',
            'kind': 'Type de véhicule',
            'country': 'Pays',
            'observations': 'Observations',
          };
    final controllers = {
      for (final key in fields.keys)
        key: TextEditingController(
          text: key == 'birth_date'
              ? _displayDate(row?[key])
              : (row?[key] ?? '').toString(),
        ),
    };
    String role = controllers['role']?.text.isNotEmpty == true
        ? controllers['role']!.text
        : 'Autre';
    final vehicleId =
        row?['id'] as String? ??
        DateTime.now().microsecondsSinceEpoch.toString();
    final linked = <String>{};
    if (!identity && row != null)
      linked.addAll(await GopsDatabase.instance.vehicleIdentityIds(vehicleId));
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(row == null ? 'Nouvelle fiche' : 'Modifier la fiche'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in fields.entries)
                    if (entry.key != 'role')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextField(
                          controller: controllers[entry.key],
                          readOnly: entry.key == 'birth_date',
                          decoration: InputDecoration(
                            labelText: entry.value,
                            suffixIcon: entry.key == 'birth_date'
                                ? IconButton(
                                    tooltip: 'Choisir une date',
                                    icon: const Icon(
                                      Icons.calendar_today_outlined,
                                    ),
                                    onPressed: () => _pickRecordDate(
                                      context,
                                      controllers[entry.key]!,
                                      setDialog,
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ),
                  if (identity)
                    DropdownButtonFormField<String>(
                      value: role,
                      decoration: const InputDecoration(labelText: 'Qualité'),
                      items:
                          const [
                                'Auteur',
                                'Mis en cause',
                                'Victime',
                                'Témoin',
                                'Autre',
                              ]
                              .map(
                                (v) =>
                                    DropdownMenuItem(value: v, child: Text(v)),
                              )
                              .toList(),
                      onChanged: (v) => setDialog(() => role = v ?? 'Autre'),
                    ),
                  if (!identity && _identities.isNotEmpty) ...[
                    const Divider(),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Personnes associées'),
                    ),
                    for (final person in _identities)
                      CheckboxListTile(
                        dense: true,
                        value: linked.contains(person['id']),
                        title: Text(
                          '${person['first_names']} ${person['surname']}',
                        ),
                        onChanged: (checked) => setDialog(() {
                          if (checked == true) {
                            linked.add(person['id']! as String);
                          } else {
                            linked.remove(person['id']);
                          }
                        }),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (result == 'save') {
      final values = <String, Object?>{
        'id': identity
            ? (row?['id'] ?? DateTime.now().microsecondsSinceEpoch.toString())
            : vehicleId,
        'intervention_id': _id,
      };
      for (final entry in controllers.entries)
        values[entry.key] = entry.value.text.trim();
      if (identity) values['role'] = role;
      await GopsDatabase.instance.saveRow(table, values);
      if (!identity)
        await GopsDatabase.instance.replaceVehicleIdentityLinks(
          vehicleId,
          linked,
        );
      await _reloadChildren();
    }
    for (final c in controllers.values) c.dispose();
  }

  Future<void> _pickRecordDate(
    BuildContext dialogContext,
    TextEditingController controller,
    StateSetter setDialog,
  ) async {
    final selected = await showDatePicker(
      context: dialogContext,
      initialDate: _parseDate(controller.text) ?? DateTime(2000),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      helpText: 'Date de naissance',
    );
    if (selected != null) {
      setDialog(
        () => controller.text = DateFormat('dd/MM/yyyy').format(selected),
      );
    }
  }

  Future<void> _emailPhotos() async {
    if (_photos.isEmpty || _sendingPhotos) return;
    try {
      final capabilities = await FlutterEmailSender.getCapabilities();
      if (!capabilities.canSend || !capabilities.supportsAttachments) {
        _showPhotoEmailMessage(
          'Aucune application mail avec pièces jointes n’est disponible. Sur iPhone, configurez un compte dans l’app Mail d’Apple.',
        );
        return;
      }
    } catch (_) {
      _showPhotoEmailMessage('Impossible d’ouvrir une application mail.');
      return;
    }
    final recipient = await _askPhotoRecipient();
    if (recipient == null || !mounted) return;
    setState(() => _sendingPhotos = true);
    Directory? temp;
    try {
      temp = await Directory.systemTemp.createTemp('gops_mail_');
      final attachments = <File>[];
      for (var i = 0; i < _photos.length; i++) {
        if (mounted)
          setState(
            () => _saveState = 'Préparation ${i + 1}/${_photos.length}…',
          );
        final source = File(_photos[i]['local_path']! as String);
        final reduced = await compute(
          _compressPhotoForEmail,
          await source.readAsBytes(),
        );
        final file = File(
          p.join(temp.path, 'photo_${(i + 1).toString().padLeft(2, '0')}.jpg'),
        );
        await file.writeAsBytes(reduced, flush: true);
        attachments.add(file);
      }
      const maxBatchBytes =
          3_200_000; // L’encodage MIME augmente la taille des pièces jointes.
      final batches = <List<File>>[];
      var batch = <File>[];
      var batchSize = 0;
      for (final file in attachments) {
        final size = await file.length();
        if (batch.isNotEmpty && batchSize + size > maxBatchBytes) {
          batches.add(batch);
          batch = <File>[];
          batchSize = 0;
        }
        batch.add(file);
        batchSize += size;
      }
      if (batch.isNotEmpty) batches.add(batch);
      final intervention = _controllers['nature']!.text.trim();
      final subject = intervention.isEmpty
          ? 'Photos de l’intervention'
          : 'Photos – $intervention';
      for (var i = 0; i < batches.length; i++) {
        if (!mounted) break;
        setState(() => _saveState = 'Envoi ${i + 1}/${batches.length}…');
        final result = await FlutterEmailSender.send(
          Email(
            recipients: [recipient],
            subject: batches.length == 1
                ? subject
                : '$subject (${i + 1}/${batches.length})',
            body:
                'Photos de l’intervention${intervention.isEmpty ? '' : ' : $intervention'}.',
            attachmentPaths: batches[i].map((f) => f.path).toList(),
          ),
        );
        if (result == EmailSendResult.cancelled ||
            result == EmailSendResult.saved)
          break;
        if (result == EmailSendResult.unknown && i + 1 < batches.length) {
          if (!await _confirmNextPhotoEmail(i + 2, batches.length)) break;
        }
      }
    } catch (e) {
      _showPhotoEmailMessage(
        'Préparation ou ouverture du mail impossible : $e',
      );
    } finally {
      if (temp != null && await temp.exists())
        await temp.delete(recursive: true);
      if (mounted)
        setState(() {
          _sendingPhotos = false;
          _saveState = 'Enregistré';
        });
    }
  }

  Future<String?> _askPhotoRecipient() async {
    final controller = TextEditingController();
    final recipient = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Envoyer les photos'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Les images seront réduites et réparties en plusieurs mails si nécessaire. Chaque mail reste sous 5 Mo.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Adresse e-mail du destinataire',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (!value.contains('@') ||
                  value.endsWith('@') ||
                  !value.contains('.'))
                return;
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
    controller.dispose();
    return recipient;
  }

  Future<bool> _confirmNextPhotoEmail(int next, int total) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Mail suivant'),
          content: Text(
            'L’application mail ne confirme pas l’envoi. Si vous avez envoyé le mail précédent, ouvrez le suivant ($next sur $total).',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Arrêter'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Continuer'),
            ),
          ],
        ),
      ) ??
      false;

  void _showPhotoEmailMessage(String message) {
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _photoSection() => Column(
    children: [
      Expanded(
        child: _photos.isEmpty
            ? const Center(child: Text('Aucune photographie.'))
            : GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: _photos.length,
                itemBuilder: (c, i) {
                  final photo = _photos[i];
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(
                          onTap: () => showDialog(
                            context: context,
                            builder: (c) => Dialog(
                              child: InteractiveViewer(
                                child: Image.file(
                                  File(photo['local_path']! as String),
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ),
                          child: Image.file(
                            File(photo['local_path']! as String),
                            fit: BoxFit.cover,
                            errorBuilder: (c, e, s) => const ColoredBox(
                              color: surface,
                              child: Icon(Icons.broken_image),
                            ),
                          ),
                        ),
                        if ((photo['description'] as String).isNotEmpty)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              width: double.infinity,
                              color: Colors.black87,
                              padding: const EdgeInsets.all(6),
                              child: Text(
                                photo['description']! as String,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        Align(
                          alignment: Alignment.topRight,
                          child: PopupMenuButton<String>(
                            color: surface,
                            onSelected: (v) {
                              if (v == 'description')
                                _editPhotoDescription(photo);
                              if (v == 'delete') _deletePhoto(photo);
                            },
                            itemBuilder: (c) => const [
                              PopupMenuItem(
                                value: 'description',
                                child: Text('Modifier la description'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Supprimer'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: _sendingPhotos ? null : () => _addPhoto(),
              icon: const Icon(Icons.add_a_photo_outlined),
              label: const Text('Ajouter une photo'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _photos.isEmpty || _sendingPhotos
                  ? null
                  : _emailPhotos,
              icon: _sendingPhotos
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.email_outlined),
              label: Text(_sendingPhotos ? _saveState : 'Envoyer par e-mail'),
            ),
          ],
        ),
      ),
    ],
  );
  Future<Map<String, Object?>> _croSourceFacts() async {
    final identitiesById = {
      for (final person in _identities) person['id']! as String: person,
    };
    final people = _identities.map((person) {
      final data = <String, Object?>{
        'Identité': '${person['first_names'] ?? ''} ${person['surname'] ?? ''}'
            .trim(),
        'Nom d’usage': person['usage_name'],
        'Qualité de la personne': person['role'],
        'Date de naissance': _displayDate(person['birth_date']),
        'Lieu de naissance': person['birth_place'],
        'Nationalité': person['nationality'],
        'Téléphone': person['phone'],
        'Adresse électronique': person['email'],
        'Adresse': [
          person['address'],
          person['postal_code'],
          person['city'],
        ].where((part) => (part ?? '').toString().trim().isNotEmpty).join(', '),
        'Observations': person['observations'],
      };
      data.removeWhere((_, value) => (value ?? '').toString().trim().isEmpty);
      return data;
    }).toList();
    final vehicles = <Map<String, Object?>>[];
    for (final vehicle in _vehicles) {
      final linkedIds = await GopsDatabase.instance.vehicleIdentityIds(
        vehicle['id']! as String,
      );
      final linkedPeople = linkedIds
          .map((id) => identitiesById[id])
          .whereType<Map<String, Object?>>()
          .map(
            (person) =>
                '${person['first_names'] ?? ''} ${person['surname'] ?? ''}'
                    .trim(),
          )
          .where((name) => name.isNotEmpty)
          .toList();
      final data = <String, Object?>{
        'Immatriculation': vehicle['registration'],
        'Marque': vehicle['make'],
        'Modèle': vehicle['model'],
        'Type': vehicle['kind'],
        'Couleur': vehicle['color'],
        'Pays': vehicle['country'],
        'Personnes associées': linkedPeople,
        'Observations': vehicle['observations'],
      };
      data.removeWhere(
        (_, value) =>
            value == null ||
            (value is String && value.trim().isEmpty) ||
            (value is List && value.isEmpty),
      );
      vehicles.add(data);
    }
    final photos = _photos
        .map(
          (photo) => <String, Object?>{
            'Catégorie': photo['category'],
            'Description': photo['description'],
          },
        )
        .where(
          (photo) => (photo['Description'] ?? '').toString().trim().isNotEmpty,
        )
        .toList();
    return {
      'Intervention': {
        'Nature': _controllers['nature']!.text.trim(),
        'Date': _displayDate(_controllers['date']!.text),
        'Heure': _controllers['time']!.text.trim(),
        'Lieu': _controllers['location']!.text.trim(),
        'Bloc note': _controllers['observations']!.text.trim(),
        'Notes de compte rendu déjà saisies': _controllers['report']!.text
            .trim(),
      },
      'Personnes': people,
      'Véhicules': vehicles,
      'Photographies décrites': photos,
    };
  }

  String _composeCro(Map<String, Object?> facts, String narrative) {
    final intervention = facts['Intervention'] as Map<String, Object?>;
    final out = StringBuffer('COMPTE RENDU OPÉRATIONNEL\n\n');
    final context = <String, Object?>{
      'Nature intervention': intervention['Nature'],
      'Date': intervention['Date'],
      'Heure': intervention['Heure'],
      'Lieu': intervention['Lieu'],
    };
    for (final entry in context.entries) {
      final value = (entry.value ?? '').toString().trim();
      if (value.isNotEmpty) out.writeln('${entry.key} : $value');
    }
    out.write('\nFAITS ET DÉROULEMENT\n\n');
    out.writeln(narrative.trim());

    void appendRecords(String title, String key) {
      final records = facts[key] as List<Map<String, Object?>>? ?? [];
      if (records.isEmpty) return;
      out.write('\n$title\n');
      for (var i = 0; i < records.length; i++) {
        out.write('\n${i + 1}. ');
        out.writeln(
          records[i].entries
              .map((entry) {
                final value = entry.value;
                final rendered = value is List
                    ? value.join(', ')
                    : value.toString();
                return '${entry.key} : $rendered';
              })
              .join(' · '),
        );
      }
    }

    appendRecords('PERSONNES CONCERNÉES', 'Personnes');
    appendRecords('VÉHICULES CONCERNÉS', 'Véhicules');
    appendRecords('PHOTOGRAPHIES', 'Photographies décrites');
    return out.toString().trim();
  }

  Future<void> _generateCro() async {
    if (_generatingCro) return;
    setState(() {
      _generatingCro = true;
      _croModelDownloadProgress = 0;
    });
    try {
      if (!mounted) return;
      final qualityInstalled = await CroAiService.isModelInstalled(
        highQuality: true,
      );
      final useHighQuality = qualityInstalled
          ? true
          : await showDialog<bool>(
              context: context,
              builder: (dialogContext) => AlertDialog(
                title: const Text('Améliorer la rédaction des comptes rendus'),
                content: const Text(
                  'Le modèle renforcé (Gemma 4 E2B, environ 2,6 Go) produit des textes plus développés. Il est téléchargé une seule fois et fonctionne ensuite hors connexion. Le modèle compact (345 Mo) reste disponible pour les téléphones disposant de moins de stockage. Les données de la fiche restent sur ce téléphone.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Annuler'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Modèle compact'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Modèle renforcé'),
                  ),
                ],
              ),
            );
      if (useHighQuality == null) return;
      if (!await CroAiService.isModelInstalled(highQuality: useHighQuality)) {
        final download = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Télécharger le modèle IA'),
            content: Text(
              'Le modèle sélectionné (environ ${useHighQuality ? '2,6 Go' : '345 Mo'}) doit être téléchargé une seule fois. Préférez une connexion Wi-Fi et vérifiez que le téléphone dispose d’assez d’espace libre.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Plus tard'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Télécharger'),
              ),
            ],
          ),
        );
        if (download != true) return;
        await CroAiService.installModel(
          highQuality: useHighQuality,
          onProgress: (progress) {
            if (mounted) setState(() => _croModelDownloadProgress = progress);
          },
        );
      }
      if (!mounted) return;
      setState(() => _croModelDownloadProgress = 100);
      final facts = await _croSourceFacts();
      final result = await CroAiService.generate(
        facts,
        highQuality: useHighQuality,
      );
      if (!mounted) return;
      _controllers['report']!.text = _composeCro(facts, result);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Compte rendu généré. Relisez-le avant utilisation.'),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Génération impossible : $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _generatingCro = false);
    }
  }

  Future<void> _copyCro() async {
    final text = _controllers['report']!.text.trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Compte rendu copié.')));
  }

  Widget _reportSection() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Compte rendu opérationnel',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text(
        'L’IA rédige sur ce téléphone à partir des faits, identités et véhicules de la fiche. Relisez toujours le texte généré.',
        style: TextStyle(color: Colors.white70),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _generatingCro ? null : _generateCro,
              icon: _generatingCro
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(
                _generatingCro
                    ? _croModelDownloadProgress < 100
                          ? 'Téléchargement $_croModelDownloadProgress %'
                          : 'Rédaction du compte rendu…'
                    : 'Générer avec l’IA',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Copier le compte rendu',
            onPressed: _controllers['report']!.text.trim().isEmpty
                ? null
                : _copyCro,
            icon: const Icon(Icons.copy_outlined),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _field('report', 'Compte rendu à relire et modifier', maxLines: 18),
    ],
  );

  Future<void> _deleteIntervention() async {
    final pin = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Confirmer la suppression'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Cette suppression est définitive. Saisissez votre PIN.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Code PIN'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, pin.text),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (entered == null) return;
    if (!await SecurityService.instance.verifyPin(entered)) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Code PIN incorrect.')));
      return;
    }
    if (!await _confirm(
      'Confirmer définitivement la suppression de cette intervention et de ses photos ?',
    ))
      return;
    await GopsDatabase.instance.deleteIntervention(_id!);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _shareIntervention() async {
    await _save();
    if (!await _confirm(
      'Le fichier partagé contiendra les informations de la fiche, les identités, les véhicules et les photos. Il peut inclure des données personnelles. Continuer ?',
    )) {
      return;
    }
    try {
      final bytes = await InterventionBundleService.exportBundle(_id!);
      final temp = await getTemporaryDirectory();
      final filename =
          'GOPS-${_safeFilename(_controllers['nature']!.text, _displayDate(_controllers['date']!.text))}.gops';
      final file = File(p.join(temp.path, filename));
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType: 'application/vnd.gops.intervention+zip',
              name: filename,
            ),
          ],
          subject: 'Fiche GOPS · ${_controllers['nature']!.text.trim()}',
          title: 'Partager la fiche GOPS',
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Partage impossible : $error')));
      }
    }
  }

  Future<void> _exportPdf() async {
    await _save();
    final selection = <String, bool>{
      'Informations générales': true,
      'Identités': true,
      'Photos des identités': false,
      'Véhicules': true,
      'Photos des véhicules': false,
      'Compte rendu': true,
      'Photographies générales': false,
    };
    final included = await showDialog<Set<String>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialog) => AlertDialog(
          title: const Text('Rubriques du PDF'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: selection.keys
                .map(
                  (key) => CheckboxListTile(
                    value: selection[key],
                    title: Text(key),
                    onChanged: (v) =>
                        setDialog(() => selection[key] = v ?? false),
                  ),
                )
                .toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                c,
                selection.entries
                    .where((e) => e.value)
                    .map((e) => e.key)
                    .toSet(),
              ),
              child: const Text('Créer le PDF'),
            ),
          ],
        ),
      ),
    );
    if (included == null) return;
    final doc = pw.Document();
    final date = _displayDate(_controllers['date']!.text);
    final info = [
      ('Nature de l’intervention', _controllers['nature']!.text),
      ('Date', date),
      ('Heure', _controllers['time']!.text),
      ('Lieu', _controllers['location']!.text),
      ('Bloc note', _controllers['observations']!.text),
    ];
    final includedPhotos = <({Map<String, Object?> photo, List<int> bytes})>[];
    for (final photo in _photos) {
      final category = photo['category'];
      final include = category == 'intervention'
          ? included.contains('Photographies générales')
          : category == 'identite'
          ? included.contains('Photos des identités')
          : included.contains('Photos des véhicules');
      final file = File(photo['local_path']! as String);
      if (include && await file.exists())
        includedPhotos.add((photo: photo, bytes: await file.readAsBytes()));
    }
    const ink = pd.PdfColor(0.06, 0.13, 0.21);
    const accent = pd.PdfColor(0.10, 0.34, 0.56);
    const pale = pd.PdfColor(0.95, 0.97, 0.99);
    const line = pd.PdfColor(0.82, 0.86, 0.90);
    pw.Widget sectionTitle(String title) => pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 14, bottom: 8),
      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: const pw.BoxDecoration(
        color: ink,
        border: pw.Border(left: pw.BorderSide(color: accent, width: 4)),
      ),
      child: pw.Text(
        title.toUpperCase(),
        style: pw.TextStyle(
          color: pd.PdfColors.white,
          fontSize: 11,
          fontWeight: pw.FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
    pw.Widget detail(String label, String value) => pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: const pw.BoxDecoration(
        color: pale,
        border: pw.Border(bottom: pw.BorderSide(color: line, width: 0.5)),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 132,
            child: pw.Text(
              label,
              style: pw.TextStyle(
                color: accent,
                fontSize: 9,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(value, style: const pw.TextStyle(fontSize: 9.5)),
          ),
        ],
      ),
    );
    pw.Widget card(List<pw.Widget> children) => pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(bottom: 7),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: pd.PdfColors.white,
        border: pw.Border.all(color: line, width: 0.8),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: children,
      ),
    );
    String valueOf(Map<String, Object?> row, String key) =>
        (row[key] ?? '').toString().trim();

    final regularFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Rubik-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Rubik-Medium.ttf'),
    );
    doc.addPage(
      pw.MultiPage(
        theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
        pageFormat: pd.PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(38, 62, 38, 54),
        header: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: accent, width: 1.2)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'GOPS  /  FICHE D’INTERVENTION',
                style: pw.TextStyle(
                  color: ink,
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
              pw.Text(
                date,
                style: const pw.TextStyle(
                  color: pd.PdfColors.grey,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ),
        build: (context) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.only(bottom: 9),
            decoration: const pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: line, width: 1)),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'COMPTE RENDU D’INTERVENTION',
                  style: pw.TextStyle(
                    color: ink,
                    fontSize: 19,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                if (_controllers['nature']!.text.trim().isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text(
                    _controllers['nature']!.text.trim(),
                    style: pw.TextStyle(color: accent, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          if (included.contains('Informations générales')) ...[
            sectionTitle('Informations générales'),
            ...info
                .where((entry) => entry.$2.trim().isNotEmpty)
                .map((entry) => detail(entry.$1, entry.$2.trim())),
          ],
          if (included.contains('Identités')) ...[
            sectionTitle('Personnes concernées'),
            if (_identities.isEmpty)
              pw.Text(
                'Aucune identité renseignée.',
                style: const pw.TextStyle(color: pd.PdfColors.grey),
              )
            else
              ..._identities.asMap().entries.map((entry) {
                final index = entry.key + 1;
                final person = entry.value;
                final name =
                    '${valueOf(person, 'first_names')} ${valueOf(person, 'surname')}'
                        .trim();
                final role = valueOf(person, 'role');
                final heading = [
                  if (name.isNotEmpty) name,
                  if (role.isNotEmpty) role,
                ].join('  ·  ');
                return card([
                  pw.Text(
                    '${index.toString().padLeft(2, '0')}  ${heading.isEmpty ? 'Personne' : heading}',
                    style: pw.TextStyle(
                      color: ink,
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  pw.SizedBox(height: 5),
                  for (final field in const {
                    'usage_name': 'Nom d’usage',
                    'birth_date': 'Date de naissance',
                    'birth_place': 'Lieu de naissance',
                    'nationality': 'Nationalité',
                    'address': 'Adresse',
                    'postal_code': 'Code postal',
                    'city': 'Ville',
                    'phone': 'Téléphone',
                    'email': 'Adresse électronique',
                    'observations': 'Observations',
                  }.entries)
                    if (valueOf(person, field.key).isNotEmpty)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(top: 2),
                        child: pw.Text(
                          '${field.value} : ${field.key == 'birth_date' ? _displayDate(person[field.key]) : valueOf(person, field.key)}',
                          style: const pw.TextStyle(fontSize: 9.5),
                        ),
                      ),
                ]);
              }),
          ],
          if (included.contains('Véhicules')) ...[
            sectionTitle('Véhicules concernés'),
            if (_vehicles.isEmpty)
              pw.Text(
                'Aucun véhicule renseigné.',
                style: const pw.TextStyle(color: pd.PdfColors.grey),
              )
            else
              ..._vehicles.asMap().entries.map((entry) {
                final index = entry.key + 1;
                final vehicle = entry.value;
                final heading = [
                  valueOf(vehicle, 'registration'),
                  valueOf(vehicle, 'make'),
                  valueOf(vehicle, 'model'),
                ].where((part) => part.isNotEmpty).join('  ·  ');
                return card([
                  pw.Text(
                    '${index.toString().padLeft(2, '0')}  ${heading.isEmpty ? 'Véhicule' : heading}',
                    style: pw.TextStyle(
                      color: ink,
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  for (final field in const {
                    'kind': 'Type',
                    'color': 'Couleur',
                    'country': 'Pays',
                    'observations': 'Observations',
                  }.entries)
                    if (valueOf(vehicle, field.key).isNotEmpty)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(top: 3),
                        child: pw.Text(
                          '${field.value} : ${valueOf(vehicle, field.key)}',
                          style: const pw.TextStyle(fontSize: 9.5),
                        ),
                      ),
                ]);
              }),
          ],
          if (included.contains('Compte rendu') &&
              _controllers['report']!.text.trim().isNotEmpty) ...[
            sectionTitle('Compte rendu opérationnel'),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(
                color: pale,
                border: pw.Border.all(color: line, width: 0.8),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(5)),
              ),
              child: pw.Text(
                _controllers['report']!.text.trim(),
                style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 3),
              ),
            ),
          ],
          if (includedPhotos.isNotEmpty) ...[
            sectionTitle('Photographies'),
            for (final item in includedPhotos)
              card([
                pw.Text(
                  item.photo['category'] == 'identite'
                      ? 'Photo d’identité'
                      : item.photo['category'] == 'vehicule'
                      ? 'Photo de véhicule'
                      : 'Photo générale',
                  style: pw.TextStyle(
                    color: accent,
                    fontSize: 9,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 6),
                pw.Center(
                  child: pw.Image(
                    pw.MemoryImage(Uint8List.fromList(item.bytes)),
                    height: 280,
                    fit: pw.BoxFit.contain,
                  ),
                ),
                if ((item.photo['description'] ?? '')
                    .toString()
                    .trim()
                    .isNotEmpty) ...[
                  pw.SizedBox(height: 5),
                  pw.Text(
                    (item.photo['description'] ?? '').toString().trim(),
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ],
              ]),
          ],
        ],
        footer: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: line, width: 0.8)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'GOPS  ·  Document généré le ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
                style: const pw.TextStyle(
                  color: pd.PdfColors.grey,
                  fontSize: 8,
                ),
              ),
              pw.Text(
                'Page ${context.pageNumber} / ${context.pagesCount}',
                style: const pw.TextStyle(
                  color: pd.PdfColors.grey,
                  fontSize: 8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'GOPS-${_safeFilename(_controllers['nature']!.text, date)}.pdf',
    );
  }

  String _safeFilename(String value, String date) {
    final name = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')
        .replaceAll(RegExp(r'\s+'), '_');
    return name.isEmpty ? 'intervention-$date' : name;
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.onReset, super.key});
  final VoidCallback onReset;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _biometric = false;
  bool _resetting = false;
  int _minutes = 5;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = await SecurityService.instance.biometricEnabled;
    final m = await SecurityService.instance.lockTimeoutMinutes();
    if (mounted)
      setState(() {
        _biometric = b;
        _minutes = m;
      });
  }

  Future<void> _changePin() async {
    final old = TextEditingController(), next = TextEditingController();
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Modifier le PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: old,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'PIN actuel'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Nouveau PIN (6 chiffres minimum)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, (old.text, next.text)),
            child: const Text('Modifier'),
          ),
        ],
      ),
    );
    if (result == null) return;
    if (!await SecurityService.instance.verifyPin(result.$1)) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('PIN actuel incorrect.')));
      return;
    }
    await SecurityService.instance.createPin(result.$2);
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('PIN modifié.')));
  }

  Future<void> _resetApplication() async {
    final pin = TextEditingController();
    final enteredPin = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Réinitialiser l’application ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Cette action effacera définitivement toutes les interventions, les personnes, les véhicules, les photos, le code PIN et les réglages. Un nouveau code PIN sera demandé au prochain démarrage.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Code PIN actuel'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(dialogContext, pin.text),
            child: const Text('Tout effacer'),
          ),
        ],
      ),
    );
    pin.dispose();
    if (enteredPin == null || enteredPin.isEmpty || !mounted) return;
    final pinIsValid = await SecurityService.instance.verifyPin(enteredPin);
    if (!mounted) return;
    if (!pinIsValid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Code PIN incorrect. Rien n’a été effacé.'),
        ),
      );
      return;
    }
    setState(() => _resetting = true);
    try {
      await GopsDatabase.instance.reset();
      await SecurityService.instance.reset();
      await GopsDatabase.instance.initialize();
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      widget.onReset();
    } catch (error) {
      if (mounted) {
        setState(() => _resetting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('La réinitialisation a échoué : $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Paramètres')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const ListTile(
          title: Text(
            'Sécurité',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.password),
          title: const Text('Modifier le PIN'),
          onTap: _changePin,
        ),
        SwitchListTile(
          secondary: const Icon(Icons.fingerprint),
          title: const Text('Biométrie'),
          subtitle: const Text('Empreinte ou reconnaissance faciale'),
          value: _biometric,
          onChanged: (v) async {
            if (v) {
              final authenticated = await SecurityService.instance
                  .authenticateBiometrically();
              if (!mounted) return;
              if (!authenticated) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Configurez d’abord la biométrie sur votre appareil.',
                    ),
                  ),
                );
                return;
              }
            }
            await SecurityService.instance.setBiometric(v);
            if (!mounted) return;
            setState(() => _biometric = v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Verrouillage automatique'),
          subtitle: Text('Après $_minutes minute(s)'),
          onTap: () async {
            final v = await showDialog<int>(
              context: context,
              builder: (c) => SimpleDialog(
                title: const Text('Délai d’inactivité'),
                children: [
                  for (final m in [1, 5, 10, 15])
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(c, m),
                      child: Text('$m minute(s)'),
                    ),
                ],
              ),
            );
            if (v != null) {
              await SecurityService.instance.setLockTimeoutMinutes(v);
              setState(() => _minutes = v);
            }
          },
        ),
        const Divider(),
        const ListTile(
          title: Text(
            'Stockage et confidentialité',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.storage),
          title: const Text('Stockage local chiffré'),
          subtitle: FutureBuilder<int>(
            future: GopsDatabase.instance.storageBytes(),
            builder: (c, s) => Text(
              s.hasData
                  ? 'Base SQLCipher et photos · ${_formatBytes(s.data!)}'
                  : 'Calcul de l’espace utilisé…',
            ),
          ),
        ),
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('GOPS V1'),
          subtitle: Text(
            'Application individuelle · fonctionnement hors connexion. Export PDF via le partage système à l’initiative de l’utilisateur.',
          ),
        ),
        const Divider(),
        const ListTile(
          title: Text(
            'Réinitialisation',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(
            Icons.delete_forever_outlined,
            color: Colors.redAccent,
          ),
          title: const Text('Réinitialiser l’application'),
          subtitle: const Text('Effacer les données et recommencer'),
          enabled: !_resetting,
          onTap: _resetting ? null : _resetApplication,
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('', style: TextStyle(color: Colors.white60)),
        ),
      ],
    ),
  );
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes o';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} Ko';
    return '${(kb / 1024).toStringAsFixed(1)} Mo';
  }
}
