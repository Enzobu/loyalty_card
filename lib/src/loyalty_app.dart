import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:diacritic/diacritic.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart' as ms;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'package:screen_brightness/screen_brightness.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CardCodeType { barcode, qr }

enum CardSortMode { alphabetical, custom }

enum AppThemePreference { system, light, dark }

String _normalizeSearchText(String value) {
  final String withoutAccents = removeDiacritics(value).toLowerCase().trim();
  return withoutAccents.replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

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
    this.clickCount = 0,
  });

  final String id;
  final String brandId;
  final String brandName;
  final String? brandLogoUrl;
  final String cardNumber;
  final CardCodeType codeType;
  final DateTime createdAt;
  final int clickCount;

  LoyaltyCardModel copyWith({
    String? brandId,
    String? brandName,
    String? brandLogoUrl,
    String? cardNumber,
    CardCodeType? codeType,
    int? clickCount,
  }) {
    return LoyaltyCardModel(
      id: id,
      brandId: brandId ?? this.brandId,
      brandName: brandName ?? this.brandName,
      brandLogoUrl: brandLogoUrl ?? this.brandLogoUrl,
      cardNumber: cardNumber ?? this.cardNumber,
      codeType: codeType ?? this.codeType,
      createdAt: createdAt,
      clickCount: clickCount ?? this.clickCount,
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
      'clickCount': clickCount,
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
      clickCount: json['clickCount'] as int? ?? 0,
    );
  }
}

class CardsImportResult {
  const CardsImportResult({
    required this.added,
    required this.replaced,
    required this.ignored,
  });

  final int added;
  final int replaced;
  final int ignored;
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
    final String normalizedQuery = _normalizeSearchText(_searchQuery);
    final List<LoyaltyCardModel> list = _cards.where((LoyaltyCardModel card) {
      if (normalizedQuery.isEmpty) {
        return true;
      }
      return _normalizeSearchText(card.brandName).contains(normalizedQuery) ||
          _normalizeSearchText(card.cardNumber).contains(normalizedQuery);
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

  String exportCardsJson() {
    final Map<String, dynamic> payload = <String, dynamic>{
      'format': 'loyalty_card_export',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'cards': _cards.map((LoyaltyCardModel card) => card.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<CardsImportResult> importCardsJson(String rawJson) async {
    final String trimmed = rawJson.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Le fichier est vide.');
    }

    final dynamic decoded = jsonDecode(trimmed);

    List<dynamic> rawCards;
    if (decoded is List<dynamic>) {
      rawCards = decoded;
    } else if (decoded is Map<String, dynamic>) {
      final dynamic rawFormat = decoded['format'];
      if (rawFormat != null && rawFormat != 'loyalty_card_export') {
        throw const FormatException('Format non supporte.');
      }
      final dynamic cardsNode = decoded['cards'];
      if (cardsNode is! List<dynamic>) {
        throw const FormatException('Le fichier ne contient pas de cartes.');
      }
      rawCards = cardsNode;
    } else {
      throw const FormatException('Structure JSON invalide.');
    }

    int added = 0;
    int replaced = 0;
    int ignored = 0;

    final Set<String> usedIds = _cards
        .map((LoyaltyCardModel card) => card.id)
        .toSet();

    for (final dynamic entry in rawCards) {
      if (entry is! Map<dynamic, dynamic>) {
        ignored += 1;
        continue;
      }

      LoyaltyCardModel imported;
      try {
        imported = LoyaltyCardModel.fromJson(Map<String, dynamic>.from(entry));
      } catch (_) {
        ignored += 1;
        continue;
      }

      final String normalizedImported = _normalizeCardNumber(
        imported.cardNumber,
      );
      if (normalizedImported.isEmpty) {
        ignored += 1;
        continue;
      }

      final int existingIndex = _cards.indexWhere(
        (LoyaltyCardModel card) =>
            _normalizeCardNumber(card.cardNumber) == normalizedImported,
      );

      if (existingIndex != -1) {
        final LoyaltyCardModel existing = _cards[existingIndex];
        _cards[existingIndex] = LoyaltyCardModel(
          id: existing.id,
          brandId: imported.brandId,
          brandName: imported.brandName,
          brandLogoUrl: imported.brandLogoUrl,
          cardNumber: imported.cardNumber,
          codeType: imported.codeType,
          createdAt: existing.createdAt,
          clickCount: imported.clickCount > existing.clickCount
              ? imported.clickCount
              : existing.clickCount,
        );
        replaced += 1;
        continue;
      }

      final String uniqueId = _nextUniqueId(imported.id, usedIds);
      usedIds.add(uniqueId);
      _cards.add(
        LoyaltyCardModel(
          id: uniqueId,
          brandId: imported.brandId,
          brandName: imported.brandName,
          brandLogoUrl: imported.brandLogoUrl,
          cardNumber: imported.cardNumber,
          codeType: imported.codeType,
          createdAt: imported.createdAt,
          clickCount: imported.clickCount,
        ),
      );
      added += 1;
    }

    await _saveCards();
    notifyListeners();

    return CardsImportResult(
      added: added,
      replaced: replaced,
      ignored: ignored,
    );
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
      clickCount: 0,
    );
    _cards.add(newCard);
    await _saveCards();
    notifyListeners();
  }

  Future<void> incrementCardClick(String id) async {
    final int index = _cards.indexWhere((LoyaltyCardModel c) => c.id == id);
    if (index == -1) {
      return;
    }

    _cards[index] = _cards[index].copyWith(
      clickCount: _cards[index].clickCount + 1,
    );
    // Sauvegarde en arrière-plan sans notifier pour ne pas causer de saccades
    unawaited(_saveCards());
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

  static String _normalizeCardNumber(String value) {
    return value.trim().replaceAll(RegExp(r'[\s\-]+'), '').toLowerCase();
  }

  static String _nextUniqueId(String requestedId, Set<String> usedIds) {
    final String cleanRequested = requestedId.trim();
    if (cleanRequested.isNotEmpty && !usedIds.contains(cleanRequested)) {
      return cleanRequested;
    }

    String generated = DateTime.now().microsecondsSinceEpoch.toString();
    while (usedIds.contains(generated)) {
      generated = '${DateTime.now().microsecondsSinceEpoch}_${usedIds.length}';
    }
    return generated;
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
            home: const MainScreen(),
          );
        },
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF2B5CFA),
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
          ? const Color(0xFF0F172A)
          : const Color(0xFFF6F8FD),
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

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = <Widget>[
    const HomePage(),
    const SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: _pages[_currentIndex],
      bottomNavigationBar: BottomAppBar(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        elevation: 8,
        surfaceTintColor: Colors.transparent,
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 60,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: <Widget>[
              _buildTabIcon(icon: Icons.home_rounded, label: 'HOME', index: 0),
              _buildAddButton(context),
              _buildTabIcon(
                icon: Icons.person_rounded,
                label: 'PROFILE',
                index: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddButton(BuildContext context) {
    return GestureDetector(
      onTap: () => _addCardFlow(context),
      child: Material(
        color: const Color(0xFF2B5CFA),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAliasWithSaveLayer,
        elevation: 4,
        shadowColor: const Color(0x4D2B5CFA),
        child: const Padding(
          padding: EdgeInsets.all(12),
          child: Icon(
            Icons.add,
            color: Colors.white,
            size: 28,
          ),
        ),
      ),
    );
  }

  Widget _buildTabIcon({
    required IconData icon,
    required String label,
    required int index,
  }) {
    final bool isSelected = _currentIndex == index;
    final Color color = isSelected
        ? const Color(0xFF2B5CFA)
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);

    return InkWell(
      onTap: () => setState(() => _currentIndex = index),
      customBorder: const CircleBorder(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, color: color, size: 26),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            ),
          ),
        ],
      ),
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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: context.read<AppState>().searchQuery,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (BuildContext context, AppState state, Widget? child) {
        return Scaffold(
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              children: <Widget>[
                _buildHeader(),
                const SizedBox(height: 24),
                _buildSearchBar(state),
                const SizedBox(height: 32),
                ..._buildCardList(state),
                const SizedBox(height: 80),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Row(
          children: <Widget>[
            CircleAvatar(
              radius: 22,
              backgroundColor: Colors.orange.shade100,
              backgroundImage: const NetworkImage(
                'https://api.dicebear.com/7.x/open-peeps/png?seed=Felix&backgroundColor=ffdfbf',
              ),
            ),
            const SizedBox(width: 12),
            const Text(
              'My Wallet',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.05),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.notifications_none_rounded),
        ),
      ],
    );
  }

  Widget _buildSearchBar(AppState state) {
    return TextField(
      controller: _searchController,
      onChanged: state.setSearchQuery,
      decoration: InputDecoration(
        hintText: 'Search cards, brands, or offe...',
        hintStyle: TextStyle(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          fontWeight: FontWeight.w500,
        ),
        prefixIcon: Icon(
          Icons.search_rounded,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
        ),
        suffixIcon: _searchController.text.isNotEmpty
            ? IconButton(
                icon: Icon(
                  Icons.clear_rounded,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.4),
                ),
                onPressed: () {
                  _searchController.clear();
                  state.setSearchQuery('');
                },
              )
            : null,
        filled: true,
        fillColor: Theme.of(context).cardTheme.color,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 18),
      ),
    );
  }

  List<Widget> _buildCardList(AppState state) {
    if (!state.isLoaded || state.filteredCards.isEmpty) {
      return <Widget>[];
    }

    final List<LoyaltyCardModel> sortedCards =
        List<LoyaltyCardModel>.of(state.filteredCards)..sort(
          (LoyaltyCardModel a, LoyaltyCardModel b) =>
              b.clickCount.compareTo(a.clickCount),
        );

    return sortedCards.map((LoyaltyCardModel card) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: ModernCardWidget(card: card),
      );
    }).toList();
  }
}

class ModernCardWidget extends StatelessWidget {
  const ModernCardWidget({required this.card, super.key});

  final LoyaltyCardModel card;

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    // Génération d'une couleur déterministe basée sur l'ID
    final int hash = card.id.hashCode;
    final double hue = (hash % 360).toDouble();

    // Couleur de base (H, S, L)
    // On sature un peu plus en mode sombre pour que ça "pop"
    final Color baseColor = HSLColor.fromAHSL(
      1.0,
      hue,
      isDark ? 0.65 : 0.75,
      isDark ? 0.35 : 0.45,
    ).toColor();

    // Couleur foncée pour le dégradé
    final Color darkColor = HSLColor.fromAHSL(
      1.0,
      hue,
      isDark ? 0.8 : 0.9,
      isDark ? 0.15 : 0.25,
    ).toColor();

    final List<Color> gradientColors = <Color>[baseColor, darkColor];

    return GestureDetector(
      onTap: () {
        context.read<AppState>().incrementCardClick(card.id);
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CardDetailPage(cardId: card.id),
          ),
        );
      },
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: gradientColors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: gradientColors.first.withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.all(24),
        child: Stack(
          children: <Widget>[
            // Positioned Logo
            Positioned(
              top: 0,
              left: 0,
              child: Container(
                padding: const EdgeInsets.all(4),
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: Center(
                    child: (card.brandLogoUrl != null &&
                            card.brandLogoUrl!.isNotEmpty)
                        ? Image.network(
                            card.brandLogoUrl!,
                            fit: BoxFit.contain,
                            errorBuilder: (BuildContext context, Object error,
                                StackTrace? stackTrace) {
                              return _buildFallbackLetter();
                            },
                          )
                        : _buildFallbackLetter(),
                  ),
                ),
              ),
            ),
            // Info
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    card.brandName.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          card.cardNumber,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // NFC Icon
            Positioned(
              bottom: 0,
              right: 0,
              child: Icon(
                Icons.contactless_outlined,
                color: Colors.white.withValues(alpha: 0.8),
                size: 32,
              ),
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildFallbackLetter() {
    final String letter =
        card.brandName.isEmpty ? '?' : card.brandName[0].toUpperCase();
    return Text(
      letter,
      style: const TextStyle(
        color: Colors.black,
        fontWeight: FontWeight.bold,
        fontSize: 16,
      ),
    );
  }
}

class _BrandAvatar extends StatelessWidget {
  const _BrandAvatar({required this.name, required this.logoUrl});

  final String name;
  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    final String firstLetter = name.isEmpty ? '?' : name[0].toUpperCase();

    if (logoUrl == null || logoUrl!.isEmpty) {
      return CircleAvatar(
        radius: 18,
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
      radius: 18,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: ClipOval(
        child: Image.network(
          logoUrl!,
          width: 36,
          height: 36,
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


class BrandSelectionPage extends StatefulWidget {
  const BrandSelectionPage({super.key});

  @override
  State<BrandSelectionPage> createState() => _BrandSelectionPageState();
}

class _BrandSelectionPageState extends State<BrandSelectionPage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchFocusNode.dispose();
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
    final String query = _normalizeSearchText(_search);
    final List<StoreBrand> localFiltered = _brands
        .where((StoreBrand b) => _normalizeSearchText(b.name).contains(query))
        .toList();

    final Map<String, StoreBrand> merged = <String, StoreBrand>{};
    for (final StoreBrand brand in localFiltered) {
      merged[_normalizeSearchText(brand.name)] = brand;
    }
    for (final StoreBrand brand in _remoteBrands) {
      merged.putIfAbsent(_normalizeSearchText(brand.name), () => brand);
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
              focusNode: _searchFocusNode,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
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
                decoration: InputDecoration(
                  labelText: 'Numéro de carte',
                  hintText: 'Saisis le numéro',
                  filled: true,
                  fillColor: Theme.of(context).inputDecorationTheme.fillColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 18,
                  ),
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
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _openScanner,
                icon: const Icon(Icons.document_scanner_rounded),
                label: const Text('Scanner avec la caméra'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: Text(
                  _isEdit ? 'Mettre à jour' : 'Ajouter la carte',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
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
      appBar: AppBar(
        title: const Text('Scanner la carte'),
        backgroundColor: Colors.transparent,
      ),
      extendBodyBehindAppBar: true,
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
          // Calque semi-transparent
          Container(
            decoration: ShapeDecoration(
              shape: _ScannerOverlayShape(
                borderColor: Theme.of(context).colorScheme.primary,
                borderWidth: 4.0,
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 48),
              child: Text(
                'Positionne le code-barres ou QR code dans le cadre d\'analyse.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScannerOverlayShape extends ShapeBorder {
  const _ScannerOverlayShape({
    this.borderColor = Colors.white,
    this.borderWidth = 1.0,
  }) : overlayColor = const Color(0x99000000);

  final Color borderColor;
  final double borderWidth;
  final Color overlayColor;

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.all(10);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(getOuterPath(rect), Offset.zero);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    Path getLeftTopPath(Rect rect) {
      return Path()
        ..moveTo(rect.left, rect.bottom)
        ..lineTo(rect.left, rect.top)
        ..lineTo(rect.right, rect.top);
    }

    return getLeftTopPath(rect)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final double width = rect.width;
    final double height = rect.height;
    final double cutoutWidth = width * 0.8;
    final double cutoutHeight = cutoutWidth / 1.5;

    final Rect cutoutRect = Rect.fromCenter(
      center: Offset(width / 2, height / 2.5),
      width: cutoutWidth,
      height: cutoutHeight,
    );

    final Path backgroundPath = Path()..addRect(rect);
    final Path cutoutPath = Path()
      ..addRRect(
        RRect.fromRectAndRadius(cutoutRect, const Radius.circular(16)),
      );

    final Path backgroundWithCutout = Path.combine(
      PathOperation.difference,
      backgroundPath,
      cutoutPath,
    );

    final Paint backgroundPaint = Paint()
      ..color = overlayColor
      ..style = PaintingStyle.fill;

    canvas.drawPath(backgroundWithCutout, backgroundPaint);

    final Paint borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    // Coins décoratifs de la visée
    final double dx = cutoutRect.left;
    final double dy = cutoutRect.top;
    final double dxr = cutoutRect.right;
    final double dyb = cutoutRect.bottom;
    const double length = 30.0;

    canvas.drawPath(
      Path()
        ..moveTo(dx, dy + length)
        ..quadraticBezierTo(dx, dy, dx + length, dy)
        ..moveTo(dxr - length, dy)
        ..quadraticBezierTo(dxr, dy, dxr, dy + length)
        ..moveTo(dxr, dyb - length)
        ..quadraticBezierTo(dxr, dyb, dxr - length, dyb)
        ..moveTo(dx + length, dyb)
        ..quadraticBezierTo(dx, dyb, dx, dyb - length),
      borderPaint,
    );
  }

  @override
  ShapeBorder scale(double t) => this;
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
        backgroundColor: Colors.transparent,
        actions: <Widget>[
          IconButton(
            onPressed: () => _copyCardNumber(card.cardNumber),
            icon: const Icon(Icons.share_rounded),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
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
                      content: const Text('Cette action est définitive.'),
                      actions: <Widget>[
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Annuler'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red.shade600,
                          ),
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
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_rounded, size: 20),
                    SizedBox(width: 12),
                    Text('Modifier'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: Colors.red,
                    ),
                    SizedBox(width: 12),
                    Text('Supprimer', style: TextStyle(color: Colors.red)),
                  ],
                ),
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
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Theme.of(
                            context,
                          ).shadowColor.withValues(alpha: 0.08),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _copyCardNumber(card.cardNumber),
                          child: Padding(
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  color: Colors.white,
                                  child: BarcodeWidget(
                                    barcode: card.codeType == CardCodeType.qr
                                        ? Barcode.qrCode()
                                        : Barcode.code128(),
                                    data: card.cardNumber,
                                    drawText: false,
                                    color: const Color(0xFF0F172A),
                                    width: double.infinity,
                                    height: card.codeType == CardCodeType.qr
                                        ? 200
                                        : 100,
                                    errorBuilder:
                                        (BuildContext context, String error) {
                                          return const Center(
                                            child: Text(
                                              'Numero invalide pour ce format',
                                              style: TextStyle(
                                                color: Colors.black54,
                                              ),
                                            ),
                                          );
                                        },
                                  ),
                                ),
                                const SizedBox(height: 24),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: SelectableText(
                                    card.cardNumber,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      letterSpacing: 2,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
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

  Future<void> _copyCardNumber(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Numero copie dans le presse-papiers.')),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isExporting = false;
  bool _isImporting = false;

  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Paramètres'),
        backgroundColor: Colors.transparent,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'Thème',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).shadowColor.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Choisissez le mode de couleur de l\'application',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<AppThemePreference>(
                      segments: const <ButtonSegment<AppThemePreference>>[
                        ButtonSegment<AppThemePreference>(
                          value: AppThemePreference.system,
                          label: Text('Système'),
                          icon: Icon(Icons.phone_android_rounded),
                        ),
                        ButtonSegment<AppThemePreference>(
                          value: AppThemePreference.light,
                          label: Text('Clair'),
                          icon: Icon(Icons.light_mode_rounded),
                        ),
                        ButtonSegment<AppThemePreference>(
                          value: AppThemePreference.dark,
                          label: Text('Sombre'),
                          icon: Icon(Icons.dark_mode_rounded),
                        ),
                      ],
                      selected: <AppThemePreference>{state.themePreference},
                      onSelectionChanged: (Set<AppThemePreference> values) {
                        unawaited(state.setThemePreference(values.first));
                      },
                      style: SegmentedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            const Padding(
              padding: EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                'Sauvegarde',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).cardTheme.color,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).shadowColor.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Exportez vos cartes ou restaurez une sauvegarde existante (JSON).',
                    style: TextStyle(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isExporting || _isImporting
                              ? null
                              : _exportJson,
                          icon: _isExporting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.upload_file_rounded),
                          label: const Text('Exporter'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _isImporting || _isExporting
                              ? null
                              : _importJson,
                          icon: _isImporting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                          label: const Text('Importer'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.secondaryContainer.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 16,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Lors de l\'import, les cartes ayant le même numéro remplacent les cartes existantes.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportJson() async {
    setState(() {
      _isExporting = true;
    });

    try {
      final AppState state = context.read<AppState>();
      final String json = state.exportCardsJson();
      final String timestamp = _fileTimestamp(DateTime.now());
      final Directory exportDir = await _resolveExportDirectory();
      final File file = File('${exportDir.path}/loyalty_cards_$timestamp.json');

      await file.writeAsString(json, flush: true);

      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Export termine'),
            content: Text('Fichier cree avec succes:\n${file.path}'),
            actions: <Widget>[
              OutlinedButton.icon(
                onPressed: () async {
                  await Share.shareXFiles(<XFile>[XFile(file.path)]);
                },
                icon: const Icon(Icons.share_outlined),
                label: const Text('Partager'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Echec de l\'export JSON.')));
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  Future<void> _importJson() async {
    setState(() {
      _isImporting = true;
    });

    try {
      final AppState state = context.read<AppState>();
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['json'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) {
        return;
      }

      final PlatformFile picked = result.files.single;
      String content;

      if (picked.bytes != null) {
        content = utf8.decode(picked.bytes!);
      } else if (picked.path != null && picked.path!.isNotEmpty) {
        content = await File(picked.path!).readAsString();
      } else {
        throw const FormatException('Fichier non lisible.');
      }

      final CardsImportResult report = await state.importCardsJson(content);

      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Import termine: ${report.added} ajoutes, ${report.replaced} remplaces, ${report.ignored} ignores.',
          ),
        ),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Echec de l\'import JSON.')));
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
        });
      }
    }
  }

  static String _twoDigits(int value) {
    return value.toString().padLeft(2, '0');
  }

  static String _fileTimestamp(DateTime time) {
    return '${time.year}${_twoDigits(time.month)}${_twoDigits(time.day)}_${_twoDigits(time.hour)}${_twoDigits(time.minute)}${_twoDigits(time.second)}';
  }

  Future<Directory> _resolveExportDirectory() async {
    if (Platform.isAndroid) {
      final Directory androidDownloads = Directory(
        '/storage/emulated/0/Download',
      );
      if (await androidDownloads.exists()) {
        return androidDownloads;
      }
    }

    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null) {
      return downloads;
    }

    return getApplicationDocumentsDirectory();
  }
}
