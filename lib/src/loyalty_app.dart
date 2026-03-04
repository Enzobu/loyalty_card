import 'dart:async';
import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart' as ms;
import 'package:provider/provider.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CardCodeType { barcode, qr }

enum CardSortMode { alphabetical, custom }

enum AppThemePreference { system, light, dark }

class StoreBrand {
  const StoreBrand({required this.id, required this.name});

  final String id;
  final String name;
}

const List<StoreBrand> kMockBrands = <StoreBrand>[
  StoreBrand(id: 'carrefour', name: 'Carrefour'),
  StoreBrand(id: 'leclerc', name: 'E.Leclerc'),
  StoreBrand(id: 'intermarche', name: 'Intermarche'),
  StoreBrand(id: 'auchan', name: 'Auchan'),
  StoreBrand(id: 'lidl', name: 'Lidl'),
  StoreBrand(id: 'decathlon', name: 'Decathlon'),
  StoreBrand(id: 'fnac', name: 'Fnac'),
  StoreBrand(id: 'ikea', name: 'IKEA'),
  StoreBrand(id: 'sephora', name: 'Sephora'),
  StoreBrand(id: 'monoprix', name: 'Monoprix'),
  StoreBrand(id: 'other', name: 'Autre'),
];

class LoyaltyCardModel {
  LoyaltyCardModel({
    required this.id,
    required this.brandId,
    required this.brandName,
    required this.cardNumber,
    required this.codeType,
    required this.createdAt,
  });

  final String id;
  final String brandId;
  final String brandName;
  final String cardNumber;
  final CardCodeType codeType;
  final DateTime createdAt;

  LoyaltyCardModel copyWith({
    String? brandId,
    String? brandName,
    String? cardNumber,
    CardCodeType? codeType,
  }) {
    return LoyaltyCardModel(
      id: id,
      brandId: brandId ?? this.brandId,
      brandName: brandName ?? this.brandName,
      cardNumber: cardNumber ?? this.cardNumber,
      codeType: codeType ?? this.codeType,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'brandId': brandId,
      'brandName': brandName,
      'cardNumber': cardNumber,
      'codeType': codeType.name,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  static LoyaltyCardModel fromJson(Map<String, dynamic> json) {
    return LoyaltyCardModel(
      id: json['id'] as String,
      brandId: json['brandId'] as String,
      brandName: json['brandName'] as String,
      cardNumber: json['cardNumber'] as String,
      codeType: (json['codeType'] as String) == CardCodeType.qr.name
          ? CardCodeType.qr
          : CardCodeType.barcode,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }
}

class AppState extends ChangeNotifier {
  AppState() {
    _load();
  }

  static const String _cardsKey = 'cards';
  static const String _sortModeKey = 'sort_mode';
  static const String _themeKey = 'theme_pref';

  bool _isLoaded = false;
  List<LoyaltyCardModel> _cards = <LoyaltyCardModel>[];
  String _searchQuery = '';
  CardSortMode _sortMode = CardSortMode.alphabetical;
  AppThemePreference _themePreference = AppThemePreference.system;

  bool get isLoaded => _isLoaded;
  String get searchQuery => _searchQuery;
  CardSortMode get sortMode => _sortMode;
  AppThemePreference get themePreference => _themePreference;

  ThemeMode get themeMode {
    switch (_themePreference) {
      case AppThemePreference.light:
        return ThemeMode.light;
      case AppThemePreference.dark:
        return ThemeMode.dark;
      case AppThemePreference.system:
        return ThemeMode.system;
    }
  }

  List<LoyaltyCardModel> get filteredCards {
    final String normalizedQuery = _searchQuery.trim().toLowerCase();
    final List<LoyaltyCardModel> list = _cards.where((LoyaltyCardModel card) {
      if (normalizedQuery.isEmpty) {
        return true;
      }
      return card.brandName.toLowerCase().contains(normalizedQuery) ||
          card.cardNumber.toLowerCase().contains(normalizedQuery);
    }).toList();

    if (_sortMode == CardSortMode.alphabetical) {
      list.sort(
        (LoyaltyCardModel a, LoyaltyCardModel b) =>
            a.brandName.toLowerCase().compareTo(b.brandName.toLowerCase()),
      );
    }

    return list;
  }

  LoyaltyCardModel? getCardById(String id) {
    for (final LoyaltyCardModel card in _cards) {
      if (card.id == id) {
        return card;
      }
    }
    return null;
  }

  Future<void> _load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    final String? cardsRaw = prefs.getString(_cardsKey);
    if (cardsRaw != null && cardsRaw.isNotEmpty) {
      final List<dynamic> decoded = jsonDecode(cardsRaw) as List<dynamic>;
      _cards = decoded
          .map(
            (dynamic e) => LoyaltyCardModel.fromJson(
              Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
            ),
          )
          .toList();
    }

    final String? sortRaw = prefs.getString(_sortModeKey);
    if (sortRaw != null) {
      _sortMode = sortRaw == CardSortMode.custom.name
          ? CardSortMode.custom
          : CardSortMode.alphabetical;
    }

    final String? themeRaw = prefs.getString(_themeKey);
    if (themeRaw != null) {
      _themePreference = AppThemePreference.values.firstWhere(
        (AppThemePreference pref) => pref.name == themeRaw,
        orElse: () => AppThemePreference.system,
      );
    }

    _isLoaded = true;
    notifyListeners();
  }

  Future<void> _saveCards() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(
      _cards.map((LoyaltyCardModel card) => card.toJson()).toList(),
    );
    await prefs.setString(_cardsKey, encoded);
  }

  Future<void> addCard({
    required StoreBrand brand,
    required String cardNumber,
    required CardCodeType codeType,
  }) async {
    final LoyaltyCardModel newCard = LoyaltyCardModel(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      brandId: brand.id,
      brandName: brand.name,
      cardNumber: cardNumber,
      codeType: codeType,
      createdAt: DateTime.now(),
    );
    _cards.add(newCard);
    await _saveCards();
    notifyListeners();
  }

  Future<void> updateCard(
    String id, {
    required String cardNumber,
    required CardCodeType codeType,
  }) async {
    final int index = _cards.indexWhere((LoyaltyCardModel c) => c.id == id);
    if (index == -1) {
      return;
    }

    _cards[index] = _cards[index].copyWith(
      cardNumber: cardNumber,
      codeType: codeType,
    );
    await _saveCards();
    notifyListeners();
  }

  Future<void> deleteCard(String id) async {
    _cards.removeWhere((LoyaltyCardModel card) => card.id == id);
    await _saveCards();
    notifyListeners();
  }

  Future<void> reorderCustom(int oldIndex, int newIndex) async {
    if (_sortMode != CardSortMode.custom) {
      return;
    }
    final List<LoyaltyCardModel> visible = filteredCards;
    if (oldIndex < 0 || oldIndex >= visible.length) {
      return;
    }

    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0 || newIndex >= visible.length) {
      return;
    }

    final LoyaltyCardModel moved = visible.removeAt(oldIndex);
    visible.insert(newIndex, moved);

    final Map<String, LoyaltyCardModel> byId = <String, LoyaltyCardModel>{
      for (final LoyaltyCardModel card in _cards) card.id: card,
    };

    final List<LoyaltyCardModel> reordered = visible
        .map((LoyaltyCardModel c) => byId[c.id]!)
        .toList();

    final Set<String> reorderedIds = reordered
        .map((LoyaltyCardModel c) => c.id)
        .toSet();
    for (final LoyaltyCardModel card in _cards) {
      if (!reorderedIds.contains(card.id)) {
        reordered.add(card);
      }
    }

    _cards = reordered;
    await _saveCards();
    notifyListeners();
  }

  Future<void> setSortMode(CardSortMode mode) async {
    _sortMode = mode;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sortModeKey, mode.name);
    notifyListeners();
  }

  Future<void> setThemePreference(AppThemePreference pref) async {
    _themePreference = pref;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, pref.name);
    notifyListeners();
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    notifyListeners();
  }
}

class LoyaltyApp extends StatelessWidget {
  const LoyaltyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: Consumer<AppState>(
        builder: (BuildContext context, AppState state, Widget? child) {
          return MaterialApp(
            title: 'Loyalty Card',
            debugShowCheckedModeBanner: false,
            themeMode: state.themeMode,
            theme: _buildTheme(Brightness.light),
            darkTheme: _buildTheme(Brightness.dark),
            home: const HomePage(),
          );
        },
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF123B6D),
      brightness: brightness,
    );

    final TextTheme baseText = GoogleFonts.manropeTextTheme(
      ThemeData(brightness: brightness).textTheme,
    );

    return ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      scaffoldBackgroundColor: isDark
          ? const Color(0xFF071221)
          : const Color(0xFFF5F7FB),
      textTheme: baseText,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xFF0E1D33) : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? const Color(0xFF0E1D33) : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (BuildContext context, AppState state, Widget? child) {
        if (!state.isLoaded) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final List<LoyaltyCardModel> cards = state.filteredCards;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Mes cartes'),
            actions: <Widget>[
              IconButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsPage(),
                    ),
                  );
                },
                icon: const Icon(Icons.settings_outlined),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _addCardFlow(context),
            child: const Icon(Icons.add),
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: state.setSearchQuery,
                          decoration: const InputDecoration(
                            hintText: 'Rechercher une carte',
                            prefixIcon: Icon(Icons.search),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).inputDecorationTheme.fillColor,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<CardSortMode>(
                            value: state.sortMode,
                            items: const <DropdownMenuItem<CardSortMode>>[
                              DropdownMenuItem<CardSortMode>(
                                value: CardSortMode.alphabetical,
                                child: Text('A-Z'),
                              ),
                              DropdownMenuItem<CardSortMode>(
                                value: CardSortMode.custom,
                                child: Text('Custom'),
                              ),
                            ],
                            onChanged: (CardSortMode? mode) {
                              if (mode != null) {
                                unawaited(state.setSortMode(mode));
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: cards.isEmpty
                        ? const _EmptyState()
                        : state.sortMode == CardSortMode.custom
                        ? ReorderableGridView.builder(
                            itemCount: cards.length,
                            dragEnabled: true,
                            onReorder: state.reorderCustom,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 1.1,
                                ),
                            itemBuilder: (BuildContext context, int index) {
                              final LoyaltyCardModel card = cards[index];
                              return _CardTile(
                                key: ValueKey<String>(card.id),
                                card: card,
                              );
                            },
                          )
                        : GridView.builder(
                            itemCount: cards.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 1.1,
                                ),
                            itemBuilder: (BuildContext context, int index) {
                              return _CardTile(card: cards[index]);
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _addCardFlow(BuildContext context) async {
    final StoreBrand? brand = await Navigator.of(context).push<StoreBrand>(
      MaterialPageRoute<StoreBrand>(builder: (_) => const BrandSelectionPage()),
    );

    if (!context.mounted || brand == null) {
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => CardFormPage(brand: brand, cardToEdit: null),
      ),
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile({required this.card, super.key});

  final LoyaltyCardModel card;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => CardDetailPage(cardId: card.id),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              CircleAvatar(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  card.brandName.substring(0, 1).toUpperCase(),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                card.brandName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _maskCardNumber(card.cardNumber),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _maskCardNumber(String value) {
    if (value.length <= 6) {
      return value;
    }
    final String tail = value.substring(value.length - 6);
    return '...$tail';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.wallet_outlined,
            size: 52,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          const Text(
            'Aucune carte pour le moment',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text('Ajoute une carte avec le bouton +'),
        ],
      ),
    );
  }
}

class BrandSelectionPage extends StatefulWidget {
  const BrandSelectionPage({super.key});

  @override
  State<BrandSelectionPage> createState() => _BrandSelectionPageState();
}

class _BrandSelectionPageState extends State<BrandSelectionPage> {
  final TextEditingController _searchController = TextEditingController();
  String _search = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String query = _search.trim().toLowerCase();
    final List<StoreBrand> filtered = kMockBrands
        .where((StoreBrand b) => b.name.toLowerCase().contains(query))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Choisir une enseigne')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            TextField(
              controller: _searchController,
              onChanged: (String value) => setState(() => _search = value),
              decoration: const InputDecoration(
                hintText: 'Rechercher une enseigne',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (BuildContext context, int index) {
                  final StoreBrand brand = filtered[index];
                  return Card(
                    child: ListTile(
                      leading: CircleAvatar(child: Text(brand.name[0])),
                      title: Text(brand.name),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).pop(brand),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CardFormPage extends StatefulWidget {
  const CardFormPage({
    required this.brand,
    required this.cardToEdit,
    super.key,
  });

  final StoreBrand brand;
  final LoyaltyCardModel? cardToEdit;

  @override
  State<CardFormPage> createState() => _CardFormPageState();
}

class _CardFormPageState extends State<CardFormPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _numberController;
  CardCodeType _codeType = CardCodeType.barcode;

  bool get _isEdit => widget.cardToEdit != null;

  @override
  void initState() {
    super.initState();
    _numberController = TextEditingController(
      text: widget.cardToEdit?.cardNumber ?? '',
    );
    _codeType = widget.cardToEdit?.codeType ?? CardCodeType.barcode;
  }

  @override
  void dispose() {
    _numberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Modifier la carte' : 'Ajouter la carte'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Card(
                child: ListTile(
                  leading: CircleAvatar(child: Text(widget.brand.name[0])),
                  title: Text(widget.brand.name),
                  subtitle: const Text('Enseigne selectionnee'),
                ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<CardCodeType>(
                segments: const <ButtonSegment<CardCodeType>>[
                  ButtonSegment<CardCodeType>(
                    value: CardCodeType.barcode,
                    label: Text('Code-barres'),
                    icon: Icon(Icons.qr_code_2),
                  ),
                  ButtonSegment<CardCodeType>(
                    value: CardCodeType.qr,
                    label: Text('QR Code'),
                    icon: Icon(Icons.qr_code),
                  ),
                ],
                selected: <CardCodeType>{_codeType},
                onSelectionChanged: (Set<CardCodeType> values) {
                  setState(() => _codeType = values.first);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _numberController,
                decoration: const InputDecoration(
                  labelText: 'Numero de carte',
                  hintText: 'Saisis le numero',
                ),
                validator: (String? value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Le numero est obligatoire';
                  }
                  if (value.trim().length < 4) {
                    return 'Le numero semble trop court';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openScanner,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Scanner avec la camera'),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _save,
                child: Text(_isEdit ? 'Mettre a jour' : 'Ajouter la carte'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openScanner() async {
    final String? scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const ScannerPage()),
    );
    if (!mounted || scanned == null || scanned.isEmpty) {
      return;
    }
    setState(() => _numberController.text = scanned);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final AppState state = context.read<AppState>();
    final String number = _numberController.text.trim();

    if (_isEdit) {
      await state.updateCard(
        widget.cardToEdit!.id,
        cardNumber: number,
        codeType: _codeType,
      );
    } else {
      await state.addCard(
        brand: widget.brand,
        cardNumber: number,
        codeType: _codeType,
      );
    }

    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
  }
}

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final ms.MobileScannerController _controller = ms.MobileScannerController();
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scanner la carte')),
      body: Stack(
        children: <Widget>[
          ms.MobileScanner(
            controller: _controller,
            onDetect: (ms.BarcodeCapture capture) {
              if (_done) {
                return;
              }
              final String value = capture.barcodes
                  .map((ms.Barcode barcode) => barcode.rawValue)
                  .whereType<String>()
                  .firstWhere(
                    (String val) => val.trim().isNotEmpty,
                    orElse: () => '',
                  );
              if (value.isEmpty || !mounted) {
                return;
              }
              _done = true;
              Navigator.of(context).pop(value.trim());
            },
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Positionne le code-barres ou QR code dans le cadre.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CardDetailPage extends StatefulWidget {
  const CardDetailPage({required this.cardId, super.key});

  final String cardId;

  @override
  State<CardDetailPage> createState() => _CardDetailPageState();
}

class _CardDetailPageState extends State<CardDetailPage> {
  double? _previousBrightness;

  @override
  void initState() {
    super.initState();
    _maximizeBrightness();
  }

  @override
  void dispose() {
    if (_previousBrightness != null) {
      unawaited(
        ScreenBrightness().setApplicationScreenBrightness(_previousBrightness!),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final LoyaltyCardModel? card = state.getCardById(widget.cardId);

    if (card == null) {
      return const Scaffold(body: Center(child: Text('Carte introuvable')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(card.brandName),
        actions: <Widget>[
          PopupMenuButton<String>(
            onSelected: (String action) async {
              if (action == 'edit') {
                final StoreBrand brand = StoreBrand(
                  id: card.brandId,
                  name: card.brandName,
                );
                await Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        CardFormPage(brand: brand, cardToEdit: card),
                  ),
                );
                return;
              }

              if (action == 'delete') {
                final bool? confirm = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Text('Supprimer cette carte ?'),
                      content: const Text('Cette action est definitive.'),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Annuler'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Supprimer'),
                        ),
                      ],
                    );
                  },
                );

                if (confirm == true && context.mounted) {
                  await context.read<AppState>().deleteCard(card.id);
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                }
              }
            },
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: 'edit', child: Text('Modifier')),
                  PopupMenuItem<String>(
                    value: 'delete',
                    child: Text('Supprimer'),
                  ),
                ],
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: <Widget>[
              const SizedBox(height: 16),
              Text(
                card.brandName,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 26),
              Expanded(
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: BarcodeWidget(
                        barcode: card.codeType == CardCodeType.qr
                            ? Barcode.qrCode()
                            : Barcode.code128(),
                        data: card.cardNumber,
                        drawText: false,
                        width: double.infinity,
                        height: 240,
                        errorBuilder: (BuildContext context, String error) {
                          return const Center(
                            child: Text('Numero invalide pour ce format'),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                card.cardNumber,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _maximizeBrightness() async {
    final ScreenBrightness brightness = ScreenBrightness();
    try {
      _previousBrightness = await brightness.application;
      await brightness.setApplicationScreenBrightness(1.0);
    } catch (_) {
      _previousBrightness = null;
    }
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Parametres')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Theme',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text('Choisis le mode de couleur de l\'application'),
            const SizedBox(height: 16),
            SegmentedButton<AppThemePreference>(
              segments: const <ButtonSegment<AppThemePreference>>[
                ButtonSegment<AppThemePreference>(
                  value: AppThemePreference.system,
                  label: Text('Systeme'),
                  icon: Icon(Icons.phone_android),
                ),
                ButtonSegment<AppThemePreference>(
                  value: AppThemePreference.light,
                  label: Text('Clair'),
                  icon: Icon(Icons.light_mode),
                ),
                ButtonSegment<AppThemePreference>(
                  value: AppThemePreference.dark,
                  label: Text('Sombre'),
                  icon: Icon(Icons.dark_mode),
                ),
              ],
              selected: <AppThemePreference>{state.themePreference},
              onSelectionChanged: (Set<AppThemePreference> values) {
                unawaited(state.setThemePreference(values.first));
              },
            ),
          ],
        ),
      ),
    );
  }
}
