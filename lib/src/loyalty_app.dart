import 'dart:async';
import 'dart:convert';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart' as ms;
import 'package:provider/provider.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CardCodeType { barcode, qr }

enum CardSortMode { alphabetical, custom }

enum AppThemePreference { system, light, dark }

class StoreBrand {
  const StoreBrand({required this.id, required this.name, this.logoUrl});

  final String id;
  final String name;
  final String? logoUrl;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{'id': id, 'name': name, 'logoUrl': logoUrl};
  }

  static StoreBrand fromJson(Map<String, dynamic> json) {
    return StoreBrand(
      id: json['id'] as String,
      name: json['name'] as String,
      logoUrl: json['logoUrl'] as String?,
    );
  }
}

class BrandRepository {
  BrandRepository._();

  static final BrandRepository instance = BrandRepository._();

  static const String _cacheKey = 'brands_cache_v2';
  static const String _cacheTimestampKey = 'brands_cache_ts_v1';
  static const Duration _cacheTtl = Duration(hours: 24);

  final http.Client _client = http.Client();

  Future<List<StoreBrand>> searchBrands(String query) async {
    final String normalizedQuery = query.trim();
    if (normalizedQuery.length < 2) {
      return <StoreBrand>[];
    }

    final Uri uri =
        Uri.https('www.wikidata.org', '/w/api.php', <String, String>{
          'action': 'wbsearchentities',
          'format': 'json',
          'language': 'fr',
          'uselang': 'fr',
          'type': 'item',
          'limit': '20',
          'search': normalizedQuery,
        });

    final http.Response response = await _client
        .get(
          uri,
          headers: <String, String>{
            'User-Agent': 'loyalty_card/1.0 (flutter-app)',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final Map<String, dynamic> decoded =
        jsonDecode(response.body) as Map<String, dynamic>;
    final List<dynamic> matches =
        decoded['search'] as List<dynamic>? ?? <dynamic>[];

    final List<Map<String, String>> parsed = <Map<String, String>>[];
    for (final dynamic value in matches) {
      final Map<String, dynamic> row = Map<String, dynamic>.from(
        value as Map<dynamic, dynamic>,
      );

      final String? id = row['id'] as String?;
      final String? name = row['label'] as String?;
      final String? description = row['description'] as String?;

      if (id == null ||
          !id.startsWith('Q') ||
          name == null ||
          name.trim().isEmpty) {
        continue;
      }

      if (description != null) {
        final String lowerDescription = description.toLowerCase();
        if (lowerDescription.contains('homonymie') ||
            lowerDescription.contains('disambiguation')) {
          continue;
        }
      }

      parsed.add(<String, String>{'id': id, 'name': name.trim()});
    }

    final Map<String, Map<String, String?>> mediaById =
        await _fetchBrandMediaById(
          parsed.map((Map<String, String> row) => row['id']!).toList(),
        );

    final Map<String, StoreBrand> dedup = <String, StoreBrand>{};
    for (final Map<String, String> row in parsed) {
      final String id = row['id']!;
      final String name = row['name']!;
      final String key = name.toLowerCase();
      if (dedup.containsKey(key)) {
        continue;
      }

      final Map<String, String?> media = mediaById[id] ?? <String, String?>{};
      final String? logoUrl =
          media['logoUrl'] ?? _toWebsiteLogoUrl(media['website']);

      dedup[key] = StoreBrand(id: id, name: name, logoUrl: logoUrl);
    }

    return dedup.values.toList();
  }

  Future<List<StoreBrand>> getBrands({bool forceRefresh = false}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<StoreBrand> cached = _readCachedBrands(prefs);
    final int? cacheTs = prefs.getInt(_cacheTimestampKey);

    final bool hasFreshCache =
        !forceRefresh &&
        cached.isNotEmpty &&
        cacheTs != null &&
        DateTime.now().millisecondsSinceEpoch - cacheTs <
            _cacheTtl.inMilliseconds;

    if (hasFreshCache) {
      return cached;
    }

    try {
      final List<StoreBrand> remote = await _fetchRemoteBrands();
      if (remote.isNotEmpty) {
        await prefs.setString(
          _cacheKey,
          jsonEncode(remote.map((StoreBrand brand) => brand.toJson()).toList()),
        );
        await prefs.setInt(
          _cacheTimestampKey,
          DateTime.now().millisecondsSinceEpoch,
        );
      }
      return remote.isNotEmpty ? remote : cached;
    } catch (_) {
      if (cached.isNotEmpty) {
        return cached;
      }
      rethrow;
    }
  }

  List<StoreBrand> _readCachedBrands(SharedPreferences prefs) {
    final String? raw = prefs.getString(_cacheKey);
    if (raw == null || raw.isEmpty) {
      return <StoreBrand>[];
    }

    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (dynamic value) => StoreBrand.fromJson(
              Map<String, dynamic>.from(value as Map<dynamic, dynamic>),
            ),
          )
          .toList();
    } catch (_) {
      return <StoreBrand>[];
    }
  }

  Future<List<StoreBrand>> _fetchRemoteBrands() async {
    const String query = '''
SELECT DISTINCT ?item ?itemLabel ?logo ?website
WHERE {
  ?item wdt:P31/wdt:P279* wd:Q507619.
  {
    ?item wdt:P17 wd:Q142.
  }
  UNION
  {
    ?item wdt:P159/wdt:P17 wd:Q142.
  }
  OPTIONAL { ?item wdt:P154 ?logo. }
  OPTIONAL { ?item wdt:P856 ?website. }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "fr,en". }
}
LIMIT 800
''';

    final Uri uri = Uri.https('query.wikidata.org', '/sparql', <String, String>{
      'format': 'json',
      'query': query,
    });

    final http.Response response = await _client
        .get(
          uri,
          headers: <String, String>{
            'Accept': 'application/sparql-results+json',
            'User-Agent': 'loyalty_card/1.0 (flutter-app)',
          },
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final Map<String, dynamic> decoded =
        jsonDecode(response.body) as Map<String, dynamic>;
    final List<dynamic> bindings =
        ((decoded['results'] as Map<String, dynamic>)['bindings']
            as List<dynamic>?) ??
        <dynamic>[];

    final Map<String, StoreBrand> dedup = <String, StoreBrand>{};

    for (final dynamic rowDynamic in bindings) {
      final Map<String, dynamic> row = Map<String, dynamic>.from(
        rowDynamic as Map<dynamic, dynamic>,
      );
      final String? itemValue = _bindingValue(row, 'item');
      final String? label = _bindingValue(row, 'itemLabel');

      if (itemValue == null || label == null) {
        continue;
      }

      final String cleanLabel = label.trim();
      if (cleanLabel.isEmpty || cleanLabel.length < 2) {
        continue;
      }

      final String id = itemValue.split('/').last;
      final String key = cleanLabel.toLowerCase();
      if (dedup.containsKey(key)) {
        continue;
      }

      final String? logoUrl = _toLogoUrl(_bindingValue(row, 'logo'));
      dedup[key] = StoreBrand(
        id: id,
        name: cleanLabel,
        logoUrl: logoUrl ?? _toWebsiteLogoUrl(_bindingValue(row, 'website')),
      );
    }

    final List<StoreBrand> brands = dedup.values.toList()
      ..sort(
        (StoreBrand a, StoreBrand b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

    return brands;
  }

  static String? _bindingValue(Map<String, dynamic> row, String key) {
    final dynamic node = row[key];
    if (node is! Map<dynamic, dynamic>) {
      return null;
    }
    final dynamic value = node['value'];
    if (value is! String) {
      return null;
    }
    return value;
  }

  static String? _toLogoUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    if (raw.startsWith('http://') || raw.startsWith('https://')) {
      return raw.replaceFirst('http://', 'https://');
    }

    String fileName = raw;
    if (fileName.startsWith('File:')) {
      fileName = fileName.substring(5);
    }

    return 'https://commons.wikimedia.org/wiki/Special:FilePath/${Uri.encodeComponent(fileName)}';
  }

  static String? _toWebsiteLogoUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    final String website = raw.trim();
    Uri? parsed = Uri.tryParse(website);
    if (parsed == null || parsed.host.isEmpty) {
      parsed = Uri.tryParse('https://$website');
    }

    if (parsed == null || parsed.host.isEmpty) {
      return null;
    }

    String domain = parsed.host.toLowerCase();
    if (domain.startsWith('www.')) {
      domain = domain.substring(4);
    }
    if (domain.isEmpty) {
      return null;
    }

    return 'https://www.google.com/s2/favicons?sz=128&domain=${Uri.encodeComponent(domain)}';
  }

  Future<Map<String, Map<String, String?>>> _fetchBrandMediaById(
    List<String> ids,
  ) async {
    if (ids.isEmpty) {
      return <String, Map<String, String?>>{};
    }

    final String values = ids.map((String id) => 'wd:$id').join(' ');
    final String query =
        '''
SELECT ?item ?logo ?website
WHERE {
  VALUES ?item { $values }
  OPTIONAL { ?item wdt:P154 ?logo. }
  OPTIONAL { ?item wdt:P856 ?website. }
}
''';

    try {
      final Uri uri = Uri.https(
        'query.wikidata.org',
        '/sparql',
        <String, String>{'format': 'json', 'query': query},
      );

      final http.Response response = await _client
          .get(
            uri,
            headers: <String, String>{
              'Accept': 'application/sparql-results+json',
              'User-Agent': 'loyalty_card/1.0 (flutter-app)',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return <String, Map<String, String?>>{};
      }

      final Map<String, dynamic> decoded =
          jsonDecode(response.body) as Map<String, dynamic>;
      final List<dynamic> bindings =
          ((decoded['results'] as Map<String, dynamic>)['bindings']
              as List<dynamic>?) ??
          <dynamic>[];

      final Map<String, Map<String, String?>> result =
          <String, Map<String, String?>>{};

      for (final dynamic rowDynamic in bindings) {
        final Map<String, dynamic> row = Map<String, dynamic>.from(
          rowDynamic as Map<dynamic, dynamic>,
        );

        final String? item = _bindingValue(row, 'item');
        if (item == null || item.isEmpty) {
          continue;
        }

        final String id = item.split('/').last;
        final Map<String, String?> entry =
            result[id] ?? <String, String?>{'logoUrl': null, 'website': null};

        entry['logoUrl'] =
            entry['logoUrl'] ?? _toLogoUrl(_bindingValue(row, 'logo'));
        entry['website'] = entry['website'] ?? _bindingValue(row, 'website');

        result[id] = entry;
      }

      return result;
    } catch (_) {
      return <String, Map<String, String?>>{};
    }
  }
}

class LoyaltyCardModel {
  LoyaltyCardModel({
    required this.id,
    required this.brandId,
    required this.brandName,
    required this.brandLogoUrl,
    required this.cardNumber,
    required this.codeType,
    required this.createdAt,
  });

  final String id;
  final String brandId;
  final String brandName;
  final String? brandLogoUrl;
  final String cardNumber;
  final CardCodeType codeType;
  final DateTime createdAt;

  LoyaltyCardModel copyWith({
    String? brandId,
    String? brandName,
    String? brandLogoUrl,
    String? cardNumber,
    CardCodeType? codeType,
  }) {
    return LoyaltyCardModel(
      id: id,
      brandId: brandId ?? this.brandId,
      brandName: brandName ?? this.brandName,
      brandLogoUrl: brandLogoUrl ?? this.brandLogoUrl,
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
      'brandLogoUrl': brandLogoUrl,
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
      brandLogoUrl: json['brandLogoUrl'] as String?,
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
      brandLogoUrl: brand.logoUrl,
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

class _BrandAvatar extends StatelessWidget {
  const _BrandAvatar({
    required this.name,
    required this.logoUrl,
    this.radius = 18,
  });

  final String name;
  final String? logoUrl;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final String firstLetter = name.isEmpty ? '?' : name[0].toUpperCase();

    if (logoUrl == null || logoUrl!.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          firstLetter,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: ClipOval(
        child: Image.network(
          logoUrl!,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder:
              (BuildContext context, Object error, StackTrace? stackTrace) {
                return Center(
                  child: Text(
                    firstLetter,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                );
              },
        ),
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
              _BrandAvatar(
                name: card.brandName,
                logoUrl: card.brandLogoUrl,
                radius: 20,
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
  final BrandRepository _brandRepository = BrandRepository.instance;

  List<StoreBrand> _brands = <StoreBrand>[];
  List<StoreBrand> _remoteBrands = <StoreBrand>[];
  String _search = '';
  bool _isLoading = true;
  bool _isSearching = false;
  String? _errorMessage;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _loadBrands();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadBrands({bool forceRefresh = false}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final List<StoreBrand> brands = await _brandRepository.getBrands(
        forceRefresh: forceRefresh,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        _brands = brands;
        _isLoading = false;
        _remoteBrands = <StoreBrand>[];
      });

      _triggerRemoteSearch();
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage =
            'Impossible de charger les enseignes. Verifie la connexion puis reessaie.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final String query = _search.trim().toLowerCase();
    final List<StoreBrand> localFiltered = _brands
        .where((StoreBrand b) => b.name.toLowerCase().contains(query))
        .toList();

    final Map<String, StoreBrand> merged = <String, StoreBrand>{};
    for (final StoreBrand brand in localFiltered) {
      merged[brand.name.toLowerCase()] = brand;
    }
    for (final StoreBrand brand in _remoteBrands) {
      merged.putIfAbsent(brand.name.toLowerCase(), () => brand);
    }

    final List<StoreBrand> filtered = merged.values.toList()
      ..sort(
        (StoreBrand a, StoreBrand b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

    final String manualName = _search.trim();
    final bool showManualOption = manualName.isNotEmpty;

    Widget content;
    if (_isLoading && _brands.isEmpty) {
      content = const Center(child: CircularProgressIndicator());
    } else if (_errorMessage != null && _brands.isEmpty) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(_errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _loadBrands(forceRefresh: true),
              child: const Text('Reessayer'),
            ),
          ],
        ),
      );
    } else if (filtered.isEmpty && !showManualOption) {
      content = const Center(child: Text('Aucune enseigne trouvee'));
    } else {
      content = ListView.separated(
        itemCount: filtered.length + (showManualOption ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) {
          if (showManualOption && index == 0) {
            return Card(
              child: ListTile(
                leading: const Icon(Icons.add_business_outlined),
                title: Text('Ajouter "$manualName"'),
                subtitle: const Text('Creer une enseigne manuellement'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pop(_manualBrandFromQuery()),
              ),
            );
          }

          final int adjustedIndex = showManualOption ? index - 1 : index;
          final StoreBrand brand = filtered[adjustedIndex];
          return Card(
            child: ListTile(
              leading: _BrandAvatar(name: brand.name, logoUrl: brand.logoUrl),
              title: Text(brand.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).pop(brand),
            ),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choisir une enseigne'),
        actions: <Widget>[
          IconButton(
            onPressed: () => _loadBrands(forceRefresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: <Widget>[
            TextField(
              controller: _searchController,
              onChanged: (String value) {
                setState(() => _search = value);
                _triggerRemoteSearch();
              },
              decoration: const InputDecoration(
                hintText: 'Rechercher une enseigne',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 6),
            if (_isSearching)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
            const SizedBox(height: 12),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  void _triggerRemoteSearch() {
    _searchDebounce?.cancel();
    final String query = _search.trim();

    if (query.length < 2) {
      if (_remoteBrands.isNotEmpty || _isSearching) {
        setState(() {
          _remoteBrands = <StoreBrand>[];
          _isSearching = false;
        });
      }
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSearching = true;
      });

      try {
        final List<StoreBrand> remote = await _brandRepository.searchBrands(
          query,
        );
        if (!mounted || query != _search.trim()) {
          return;
        }

        setState(() {
          _remoteBrands = remote;
          _isSearching = false;
        });
      } catch (_) {
        if (!mounted || query != _search.trim()) {
          return;
        }

        setState(() {
          _remoteBrands = <StoreBrand>[];
          _isSearching = false;
        });
      }
    });
  }

  StoreBrand _manualBrandFromQuery() {
    final String name = _search.trim();
    final String slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final String fallback = DateTime.now().millisecondsSinceEpoch.toString();

    return StoreBrand(
      id: 'manual:${slug.isEmpty ? fallback : slug}',
      name: name,
      logoUrl: null,
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
                  leading: _BrandAvatar(
                    name: widget.brand.name,
                    logoUrl: widget.brand.logoUrl,
                  ),
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
                  logoUrl: card.brandLogoUrl,
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
                    color: Colors.white,
                    surfaceTintColor: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: Container(
                        color: Colors.white,
                        padding: const EdgeInsets.all(8),
                        child: BarcodeWidget(
                          barcode: card.codeType == CardCodeType.qr
                              ? Barcode.qrCode()
                              : Barcode.code128(),
                          data: card.cardNumber,
                          drawText: false,
                          width: double.infinity,
                          height: card.codeType == CardCodeType.qr ? 240 : 120,
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
