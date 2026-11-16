import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pd;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'data/database.dart';
import 'security/security_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GopsApp());
}

const navy = Color(0xFF10243A);
const background = Color(0xFF101820);
const surface = Color(0xFF1B2732);
const blue = Color(0xFF69B9F4);

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
              const Icon(Icons.shield_moon_outlined, size: 64, color: blue),
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
                'Utilisez uniquement des données fictives tant que l’application n’a pas été validée par les responsables compétents.',
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
  const HomePage({required this.onActivity, required this.onLock, super.key});
  final VoidCallback onActivity, onLock;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _search = TextEditingController();
  String _query = '';
  Future<List<Map<String, Object?>>> _load() =>
      GopsDatabase.instance.interventions(query: _query);
  Future<void> _refresh() async => setState(() {});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('GOPS'),
      actions: [
        IconButton(
          tooltip: 'Paramètres',
          onPressed: () async {
            widget.onActivity();
            await Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
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
              hintText: 'Rechercher référence, date ou nature',
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
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        title: Text(
                          (row['reference'] as String?) ?? 'Sans référence',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${row['date']} · ${row['time']} · ${(row['nature'] as String?)?.isEmpty == true ? 'Nature non renseignée' : row['nature']}',
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
  List<Map<String, Object?>> _identities = [], _vehicles = [], _photos = [];
  final _fields = const [
    'reference',
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
          'reference': 'GOPS-${DateFormat('yyyyMMdd-HHmmss').format(now)}',
          'date': DateFormat('yyyy-MM-dd').format(now),
          'time': DateFormat('HH:mm').format(now),
          'location': '',
          'nature': '',
          'observations': '',
          'report': '',
          'created_at': now.toIso8601String(),
        };
    _id ??= values['id'] as String;
    for (final f in _fields) {
      _controllers[f]!.text = (values[f] ?? '').toString();
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
        'reference': _controllers['reference']!.text.trim(),
        'date': _controllers['date']!.text.trim(),
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
      _field('reference', 'Référence'),
      Row(
        children: [
          Expanded(
            child: _field(
              'date',
              'Date (AAAA-MM-JJ)',
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
      _field('nature', 'Nature de l’intervention'),
      _field('observations', 'Observations complémentaires', maxLines: 4),
    ],
  );
  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_controllers['date']!.text) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      helpText: 'Date de l’intervention',
    );
    if (selected != null) {
      _controllers['date']!.text = DateFormat('yyyy-MM-dd').format(selected);
    }
  }

  Future<void> _pickTime() async {
    final pieces = _controllers['time']!.text.split(':');
    final hour = pieces.length == 2 ? int.tryParse(pieces[0]) : null;
    final minute = pieces.length == 2 ? int.tryParse(pieces[1]) : null;
    final selected = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: hour != null && hour >= 0 && hour < 24 ? hour : TimeOfDay.now().hour,
        minute: minute != null && minute >= 0 && minute < 60 ? minute : 0,
      ),
      helpText: 'Heure de l’intervention',
    );
    if (selected != null) {
      _controllers['time']!.text =
          '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    }
  }

  Widget _field(String key, String label, {int maxLines = 1, Widget? suffix}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: _controllers[key],
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label, suffixIcon: suffix),
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
        key: TextEditingController(text: (row?[key] ?? '').toString()),
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
                          decoration: InputDecoration(labelText: entry.value),
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
        child: FilledButton.icon(
          onPressed: () => _addPhoto(),
          icon: const Icon(Icons.add_a_photo_outlined),
          label: const Text('Ajouter une photo'),
        ),
      ),
    ],
  );
  Widget _reportSection() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'Compte rendu',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      _field('report', 'Rédiger le compte rendu', maxLines: 18),
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
    final date = _controllers['date']!.text;
    final info = [
      ('Référence', _controllers['reference']!.text),
      ('Date', date),
      ('Heure', _controllers['time']!.text),
      ('Lieu', _controllers['location']!.text),
      ('Nature', _controllers['nature']!.text),
      ('Observations', _controllers['observations']!.text),
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
    doc.addPage(
      pw.MultiPage(
        build: (context) => [
          pw.Header(
            level: 0,
            child: pw.Text(
              'GOPS · FICHE D’INTERVENTION',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (included.contains('Informations générales')) ...[
            pw.Text(
              'Informations générales',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            ...info
                .where((e) => e.$2.trim().isNotEmpty)
                .map(
                  (e) => pw.Padding(
                    padding: const pw.EdgeInsets.only(bottom: 4),
                    child: pw.Text('${e.$1} : ${e.$2}'),
                  ),
                ),
            pw.SizedBox(height: 16),
          ],
          if (included.contains('Identités')) ...[
            pw.Text(
              'Identités',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            ..._identities.map(
              (x) => pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 5),
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(
                    color: const pd.PdfColor(0.7, 0.7, 0.7),
                  ),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '${x['first_names']} ${x['surname']} · ${x['role']}',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    for (final key in [
                      'usage_name',
                      'birth_date',
                      'birth_place',
                      'nationality',
                      'address',
                      'postal_code',
                      'city',
                      'phone',
                      'email',
                      'observations',
                    ])
                      if ((x[key] ?? '').toString().trim().isNotEmpty)
                        pw.Text('${key.replaceAll('_', ' ')} : ${x[key]}'),
                  ],
                ),
              ),
            ),
            pw.SizedBox(height: 14),
          ],
          if (included.contains('Véhicules')) ...[
            pw.Text(
              'Véhicules',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            ..._vehicles.map(
              (x) => pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 5),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '${x['registration']} · ${x['make']} ${x['model']} · ${x['color']} · ${x['country']}',
                    ),
                    for (final key in ['kind', 'observations'])
                      if ((x[key] ?? '').toString().trim().isNotEmpty)
                        pw.Text(
                          '${key == 'kind' ? 'Type' : 'Observations'} : ${x[key]}',
                        ),
                  ],
                ),
              ),
            ),
            pw.SizedBox(height: 14),
          ],
          if (included.contains('Compte rendu') &&
              _controllers['report']!.text.trim().isNotEmpty) ...[
            pw.Text(
              'Compte rendu',
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Text(_controllers['report']!.text),
          ],
          for (final item in includedPhotos)
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 10),
              child: pw.Column(
                children: [
                  pw.Image(
                    pw.MemoryImage(Uint8List.fromList(item.bytes)),
                    height: 260,
                    fit: pw.BoxFit.contain,
                  ),
                  pw.Text((item.photo['description'] ?? '').toString()),
                ],
              ),
            ),
        ],
        footer: (context) => pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text('GOPS · Document local'),
            pw.Text('Page ${context.pageNumber} / ${context.pagesCount}'),
          ],
        ),
      ),
    );
    await Printing.sharePdf(
      bytes: await doc.save(),
      filename: 'GOPS-${_controllers['reference']!.text}.pdf',
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _biometric = false;
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
            if (v &&
                !await SecurityService.instance.authenticateBiometrically()) {
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Configurez d’abord la biométrie sur votre appareil.',
                    ),
                  ),
                );
              return;
            }
            await SecurityService.instance.setBiometric(v);
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
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Utiliser uniquement des données fictives avant validation institutionnelle du traitement et de l’appareil.',
            style: TextStyle(color: Colors.white60),
          ),
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
