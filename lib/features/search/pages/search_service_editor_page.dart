import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models/api_keys.dart';
import '../../../core/services/search/search_service.dart';
import '../../../core/services/search/search_service_usage_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/brand_assets.dart';
import 'search_api_keys_page.dart';

class SearchServiceEditorResult {
  const SearchServiceEditorResult.saved(this.service) : deleted = false;

  const SearchServiceEditorResult.deleted() : service = null, deleted = true;

  final SearchServiceOptions? service;
  final bool deleted;
}

typedef SearchServiceUsageFetcher =
    Future<SearchServiceUsageInfo> Function(SearchServiceOptions options);
typedef SearchServiceTestFetcher =
    Future<SearchResult> Function(String query, SearchServiceOptions options);

typedef _SearchUsageCacheKey = ({
  String id,
  String provider,
  String credential,
  String endpoint,
});

class SearchServiceEditorPage extends StatefulWidget {
  const SearchServiceEditorPage({
    super.key,
    this.initialService,
    required this.commonOptions,
    this.canDelete = false,
    this.autoQueryUsage = true,
    this.usageFetcher,
    this.searchFetcher,
  });

  final SearchServiceOptions? initialService;
  final SearchCommonOptions commonOptions;
  final bool canDelete;
  final bool autoQueryUsage;
  final SearchServiceUsageFetcher? usageFetcher;
  final SearchServiceTestFetcher? searchFetcher;

  @override
  State<SearchServiceEditorPage> createState() =>
      _SearchServiceEditorPageState();
}

class _SearchServiceEditorPageState extends State<SearchServiceEditorPage> {
  static final Map<_SearchUsageCacheKey, SearchServiceUsageInfo> _usageCache =
      {};
  static const int _usageCacheMaxEntries = 50;

  final _formKey = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  final _queryController = TextEditingController();
  late List<ApiKeyConfig> _editKeys;
  KeyManagementConfig? _keyManagement;

  late final String _serviceId;
  late String _selectedType;
  bool _leaving = false;
  bool _dirty = false;
  bool _testing = false;
  bool _usageLoading = false;
  int _testRequestGeneration = 0;
  int _usageRequestGeneration = 0;
  SearchResult? _testResult;
  String? _testError;
  SearchServiceUsageInfo? _usage;
  String? _usageError;

  bool get _isAdding => widget.initialService == null;

  @override
  void initState() {
    super.initState();
    _serviceId = widget.initialService?.id ?? const Uuid().v4().substring(0, 8);
    _selectedType = _typeForService(
      widget.initialService ?? BingLocalOptions(id: _serviceId),
    );
    final initial =
        widget.initialService ?? _defaultService(_selectedType, _serviceId);
    _editKeys = List<ApiKeyConfig>.of(initial.apiKeys);
    _keyManagement = initial.keyManagement;
    _initializeControllers(initial);
    _usage = _cachedUsage(widget.initialService);
    if (widget.autoQueryUsage && _hasUsageCredential(widget.initialService)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _queryUsage();
      });
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final current = _currentService();
    final title = _isAdding
        ? l10n.searchServicesAddDialogTitle
        : SearchService.getService(current).name;

    return PopScope<SearchServiceEditorResult?>(
      canPop: _leaving || !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _requestClose();
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          leading: Tooltip(
            message: l10n.searchServicesPageBackTooltip,
            child: _EditorIconButton(
              icon: Lucide.ArrowLeft,
              semanticLabel: l10n.searchServicesPageBackTooltip,
              onTap: _requestClose,
            ),
          ),
          title: Text(title),
          actions: [
            if (!_isAdding && widget.canDelete) ...[
              Tooltip(
                message: l10n.searchServiceEditorDeleteTooltip,
                child: _EditorIconButton(
                  icon: Lucide.Trash2,
                  color: cs.error,
                  semanticLabel: l10n.searchServiceEditorDeleteTooltip,
                  onTap: _confirmDelete,
                ),
              ),
              const SizedBox(width: 4),
            ],
            Tooltip(
              message: _isAdding
                  ? l10n.searchServicesAddDialogAdd
                  : l10n.searchServicesEditDialogSave,
              child: _EditorIconButton(
                icon: Lucide.Check,
                semanticLabel: _isAdding
                    ? l10n.searchServicesAddDialogAdd
                    : l10n.searchServicesEditDialogSave,
                onTap: _save,
              ),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: SafeArea(
          child: Form(
            key: _formKey,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (_isAdding) ...[
                      _sectionHeader(
                        context,
                        l10n.searchServiceEditorProviderTypeTitle,
                        first: true,
                      ),
                      _sectionCard(
                        context,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final spec in _providerTypes)
                                _ProviderTypeChip(
                                  label: _serviceTypeName(context, spec.type),
                                  brand: spec.brand,
                                  selected: spec.type == _selectedType,
                                  onTap: () => _changeType(spec.type),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    _sectionHeader(
                      context,
                      l10n.searchServiceEditorConfigurationTitle,
                      first: !_isAdding,
                    ),
                    _buildConfigurationCard(context, current),
                    if (SearchServiceUsageService.supports(current)) ...[
                      _sectionHeader(
                        context,
                        l10n.searchServiceEditorUsageTitle,
                      ),
                      _buildUsageCard(context),
                    ],
                    _sectionHeader(context, l10n.searchServiceEditorTestTitle),
                    _buildTestCard(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConfigurationCard(
    BuildContext context,
    SearchServiceOptions service,
  ) {
    final fields = _configurationFields(context, service);
    final cs = Theme.of(context).colorScheme;
    return _sectionCard(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              key: const ValueKey('search-service-provider-header'),
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _SearchBrandBadge.forService(service, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    SearchService.getService(service).name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            if (fields.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Divider(
                  height: 1,
                  thickness: 0.6,
                  color: cs.outlineVariant.withValues(alpha: 0.16),
                ),
              ),
              for (var i = 0; i < fields.length; i++) ...[
                fields[i],
                if (i != fields.length - 1) const SizedBox(height: 14),
              ],
            ] else ...[
              const SizedBox(height: 12),
              Text(
                AppLocalizations.of(
                  context,
                )!.searchServiceEditorNoConfiguration,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.68),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _configurationFields(
    BuildContext context,
    SearchServiceOptions service,
  ) {
    final l10n = AppLocalizations.of(context)!;
    String? requiredUrl(String? value) {
      if (value == null || value.trim().isEmpty) {
        return l10n.searchServicesEditDialogUrlRequired;
      }
      return null;
    }

    _SearchEditorTextField field({
      required String key,
      required String label,
      String? hint,
      bool obscure = false,
      TextInputType? keyboardType,
      int minLines = 1,
      int maxLines = 1,
      FormFieldValidator<String>? validator,
    }) {
      return _SearchEditorTextField(
        key: ValueKey('search-service-field-$key'),
        label: label,
        controller: _controller(key),
        hint: hint,
        obscure: obscure,
        keyboardType: keyboardType,
        minLines: minLines,
        maxLines: maxLines,
        validator: validator,
        onChanged: (_) => _markDirty(),
      );
    }

    final multiKey = _buildMultiKeyEntry(context, service);

    if (service is BingLocalOptions) {
      return const [];
    }
    if (service is DuckDuckGoOptions) {
      return [
        field(
          key: 'region',
          label: l10n.searchServicesEditDialogRegionOptional,
          hint: 'us-en',
        ),
      ];
    }
    if (service is TavilyOptions) {
      return [
        field(
          key: 'url',
          label: l10n.searchServicesFieldCustomUrlOptional,
          hint: TavilyOptions.defaultUrl,
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 14),
        multiKey,
      ];
    }
    if (service is ExaOptions) {
      return [
        field(
          key: 'url',
          label: l10n.searchServicesFieldCustomUrlOptional,
          hint: ExaOptions.defaultUrl,
          keyboardType: TextInputType.url,
        ),
        const SizedBox(height: 14),
        multiKey,
      ];
    }
    if (service is SearXNGOptions) {
      return [
        field(
          key: 'url',
          label: l10n.searchServicesEditDialogInstanceUrl,
          keyboardType: TextInputType.url,
          validator: requiredUrl,
        ),
        field(
          key: 'engines',
          label: l10n.searchServicesEditDialogEnginesOptional,
          hint: 'google,duckduckgo',
        ),
        field(
          key: 'language',
          label: l10n.searchServicesEditDialogLanguageOptional,
          hint: 'en-US',
        ),
        field(
          key: 'username',
          label: l10n.searchServicesEditDialogUsernameOptional,
        ),
        field(
          key: 'password',
          label: l10n.searchServicesEditDialogPasswordOptional,
          obscure: true,
        ),
      ];
    }
    if (service is SerperOptions) {
      return [
        multiKey,
        field(
          key: 'gl',
          label: l10n.searchServicesDialogCountryOptional,
          hint: 'cn',
        ),
        field(
          key: 'hl',
          label: l10n.searchServicesDialogLanguageOptional,
          hint: 'zh-cn',
        ),
        field(
          key: 'tbs',
          label: l10n.searchServicesDialogTimeFilterOptional,
          hint: 'qdr:d',
        ),
        field(
          key: 'page',
          label: l10n.searchServicesDialogPageOptional,
          hint: '1',
          keyboardType: TextInputType.number,
          validator: (value) {
            final text = value?.trim() ?? '';
            if (text.isEmpty) return null;
            final page = int.tryParse(text);
            return page == null || page < 1
                ? l10n.searchServicesDialogPageInvalid
                : null;
          },
        ),
      ];
    }
    if (service is QueritOptions) {
      return [
        multiKey,
        field(
          key: 'sitesInclude',
          label: l10n.searchServicesDialogSitesIncludeOptional,
          hint: l10n.searchServicesDialogSitesHint,
        ),
        field(
          key: 'sitesExclude',
          label: l10n.searchServicesDialogSitesExcludeOptional,
          hint: l10n.searchServicesDialogSitesHint,
        ),
        field(
          key: 'timeRange',
          label: l10n.searchServicesDialogTimeRangeOptional,
          hint: l10n.searchServicesDialogTimeRangeHint,
        ),
        field(
          key: 'countries',
          label: l10n.searchServicesDialogCountriesOptional,
          hint: l10n.searchServicesDialogCountriesHint,
        ),
        field(
          key: 'languages',
          label: l10n.searchServicesDialogLanguagesOptional,
          hint: l10n.searchServicesDialogLanguagesHint,
        ),
      ];
    }
    if (service is GrokOptions) {
      return [
        multiKey,
        field(
          key: 'model',
          label: l10n.searchServicesDialogModel,
          hint: GrokOptions.defaultModel,
        ),
        field(
          key: 'reasoningEffort',
          label: l10n.reasoningBudgetSheetTitle,
          hint: 'none / low / medium / high / xhigh',
        ),
        field(
          key: 'customUrl',
          label: l10n.searchServicesFieldCustomUrlOptional,
          hint: GrokOptions.defaultUrl,
          keyboardType: TextInputType.url,
        ),
        field(
          key: 'systemPrompt',
          label: l10n.searchServicesDialogSystemPrompt,
          minLines: 3,
          maxLines: 6,
        ),
      ];
    }
    if (service is StepFunOptions) {
      return [
        multiKey,
        field(
          key: 'url',
          label: l10n.searchServicesFieldCustomUrlOptional,
          hint: StepFunOptions.defaultUrl,
          keyboardType: TextInputType.url,
        ),
        field(
          key: 'category',
          label: l10n.searchServiceEditorCategoryLabel,
          hint: 'programming / research / gov / business',
        ),
      ];
    }
    if (service is FirecrawlOptions) {
      return [
        multiKey,
        field(
          key: 'url',
          label: l10n.searchServicesFieldCustomUrlOptional,
          hint: FirecrawlOptions.defaultUrl,
          keyboardType: TextInputType.url,
        ),
        field(
          key: 'country',
          label: l10n.searchServiceEditorCountryLabel,
          hint: 'US',
        ),
        field(key: 'location', label: l10n.searchServiceEditorLocationLabel),
      ];
    }
    if (service is TinyFishOptions) {
      return [
        multiKey,
        field(
          key: 'url',
          label: l10n.searchServicesFieldCustomUrlOptional,
          hint: TinyFishOptions.defaultUrl,
          keyboardType: TextInputType.url,
        ),
        field(
          key: 'location',
          label: l10n.searchServiceEditorLocationLabel,
          hint: 'US',
        ),
        field(
          key: 'language',
          label: l10n.searchServiceEditorLanguageLabel,
          hint: 'en',
        ),
        field(
          key: 'includeDomains',
          label: l10n.searchServiceEditorIncludeDomainsLabel,
        ),
        field(
          key: 'excludeDomains',
          label: l10n.searchServiceEditorExcludeDomainsLabel,
        ),
      ];
    }

    return [multiKey];
  }

  Widget _buildMultiKeyEntry(
    BuildContext context,
    SearchServiceOptions service,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final count = _editKeys.length;

    final rows = <Widget>[];
    for (int i = 0; i < _editKeys.length; i++) {
      final k = _editKeys[i];
      final idx = i;
      rows.add(
        Container(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(
              alpha: isDark ? 0.18 : 0.5,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        k.name ??
                            '${l10n.searchServicesDialogApiKey} ${idx + 1}',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        k.key.length > 20
                            ? '${k.key.substring(0, 20)}...'
                            : k.key,
                        style: TextStyle(
                          fontSize: 14,
                          color: cs.onSurface,
                          fontWeight: AppFontWeights.medium,
                        ),
                      ),
                    ],
                  ),
                ),
                IosSwitch(
                  value: k.isEnabled,
                  onChanged: (v) {
                    setState(() {
                      _editKeys[idx] = k.copyWith(isEnabled: v);
                      _dirty = true;
                    });
                  },
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _editKeys.removeAt(idx);
                      _dirty = true;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Lucide.X, size: 16, color: cs.error),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      rows.add(const SizedBox(height: 8));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.searchServiceEditorMultiKeyTitle,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.72),
          ),
        ),
        const SizedBox(height: 7),
        ...rows,
        Row(
          children: [
            Expanded(
              child: InkWell(
                key: const ValueKey('search-service-multikey-entry'),
                borderRadius: BorderRadius.circular(12),
                onTap: _openApiKeysPage,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(
                      alpha: isDark ? 0.18 : 0.5,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Lucide.KeyRound, size: 18, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          count == 0
                              ? l10n.searchServiceEditorMultiKeyNone
                              : l10n.searchServiceEditorMultiKeyCount('$count'),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: AppFontWeights.medium,
                            color: count == 0
                                ? cs.onSurface.withValues(alpha: 0.58)
                                : cs.onSurface.withValues(alpha: 0.92),
                          ),
                        ),
                      ),
                      Icon(
                        Lucide.ChevronRight,
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            _AddKeyButton(
              onTap: () async {
                final result = await _promptAddKey();
                final key = result?.trim() ?? '';
                if (key.isNotEmpty && mounted) {
                  setState(() {
                    _editKeys.add(ApiKeyConfig.create(key));
                    _dirty = true;
                  });
                }
              },
            ),
          ],
        ),
      ],
    );
  }

  Future<String?> _promptAddKey() async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => const _AddKeyDialog(),
    );
  }

  void _openApiKeysPage() {
    FocusScope.of(context).unfocus();
    Navigator.of(context)
        .push<List<ApiKeyConfig>>(
          MaterialPageRoute(
            builder: (_) => SearchApiKeysPage(
              service: _currentService(),
              onPop: _applyKeyPool,
            ),
          ),
        )
        .then((pool) {
          if (pool != null) _applyKeyPool(pool);
        });
  }

  void _applyKeyPool(List<ApiKeyConfig> pool) {
    if (!mounted) return;
    if (listEquals(pool, _editKeys)) return;
    setState(() {
      _editKeys = List<ApiKeyConfig>.of(pool);
    });
    _markDirty();
  }

  Widget _buildUsageCard(BuildContext context) {
    return _SearchServiceUsageCard(
      service: _currentService(),
      usage: _usage,
      error: _usageError,
      loading: _usageLoading,
      onQuery: _queryUsage,
    );
  }

  Widget _buildTestCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final canRun = !_testing && _queryController.text.trim().isNotEmpty;
    return _sectionCard(
      context,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    textInputAction: TextInputAction.search,
                    key: const ValueKey('search-service-test-query'),
                    onChanged: _onTestQueryChanged,
                    onSubmitted: (_) {
                      if (canRun) _runTestSearch();
                    },
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface.withValues(alpha: 0.92),
                    ),
                    decoration: _inputDecoration(
                      context,
                      hint: l10n.searchServiceEditorTestQueryHint,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: l10n.searchServiceEditorTestRun,
                  child: _SquareActionButton(
                    enabled: canRun,
                    semanticLabel: l10n.searchServiceEditorTestRun,
                    onTap: _runTestSearch,
                    child: _testing
                        ? SizedBox.square(
                            dimension: 19,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cs.primary,
                            ),
                          )
                        : Icon(Lucide.Search, size: 20, color: cs.primary),
                  ),
                ),
              ],
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: _buildTestResult(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestResult(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (_testing) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          children: [
            Text(
              l10n.searchServiceEditorTestRunning,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.68),
              ),
            ),
          ],
        ),
      );
    }
    if (_testError != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Lucide.TriangleAlert, size: 18, color: cs.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.searchServiceEditorTestFailed(_testError!),
                style: TextStyle(fontSize: 13, height: 1.4, color: cs.error),
              ),
            ),
          ],
        ),
      );
    }
    final result = _testResult;
    if (result == null) return const SizedBox.shrink();
    if (result.items.isEmpty && (result.answer?.trim().isEmpty ?? true)) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          children: [
            Icon(
              Lucide.Search,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.62),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.searchServiceEditorTestNoResults,
                style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurface.withValues(alpha: 0.68),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result.answer?.trim().isNotEmpty == true) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Lucide.Sparkles, size: 17, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: SelectableText(
                    result.answer!.trim(),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: cs.onSurface.withValues(alpha: 0.82),
                    ),
                  ),
                ),
              ],
            ),
            if (result.items.isNotEmpty) const SizedBox(height: 12),
          ],
          for (var i = 0; i < result.items.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 0.6,
                color: cs.outlineVariant.withValues(alpha: 0.16),
              ),
            _SearchResultRow(item: result.items[i], index: i + 1),
          ],
        ],
      ),
    );
  }

  Future<void> _runTestSearch() async {
    if (_testing || _queryController.text.trim().isEmpty) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final query = _queryController.text.trim();
    final options = _currentService();
    final requestGeneration = ++_testRequestGeneration;
    setState(() {
      _testing = true;
      _testResult = null;
      _testError = null;
    });
    try {
      final result = widget.searchFetcher != null
          ? await widget.searchFetcher!(query, options)
          : await SearchService.getService(options).search(
              query: query,
              commonOptions: widget.commonOptions,
              serviceOptions: options,
            );
      if (!mounted || requestGeneration != _testRequestGeneration) return;
      setState(() => _testResult = result);
    } catch (error) {
      if (!mounted || requestGeneration != _testRequestGeneration) return;
      setState(() => _testError = _cleanError(error));
    } finally {
      if (mounted && requestGeneration == _testRequestGeneration) {
        setState(() => _testing = false);
      }
    }
  }

  void _onTestQueryChanged(String _) {
    setState(() {
      _testRequestGeneration++;
      _testing = false;
      _testResult = null;
      _testError = null;
    });
  }

  Future<void> _queryUsage() async {
    if (_usageLoading) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final options = _currentService();
    if (!SearchServiceUsageService.supports(options)) return;
    final cacheKey = _usageCacheKey(options);
    final requestGeneration = ++_usageRequestGeneration;
    setState(() {
      _usageLoading = true;
      _usage ??= cacheKey == null ? null : _usageCache[cacheKey];
      _usageError = null;
    });
    try {
      final usage = widget.usageFetcher != null
          ? await widget.usageFetcher!(options)
          : await SearchServiceUsageService.fetch(
              options,
              timeout: Duration(
                milliseconds: widget.commonOptions.timeout.clamp(1000, 30000),
              ),
            );
      if (!mounted ||
          requestGeneration != _usageRequestGeneration ||
          _usageCacheKey(_currentService()) != cacheKey) {
        return;
      }
      if (cacheKey != null) {
        if (_usageCache.length >= _usageCacheMaxEntries) _usageCache.clear();
        _usageCache[cacheKey] = usage;
      }
      setState(() => _usage = usage);
    } catch (error) {
      if (!mounted ||
          requestGeneration != _usageRequestGeneration ||
          _usageCacheKey(_currentService()) != cacheKey) {
        return;
      }
      setState(() => _usageError = _cleanError(error));
    } finally {
      if (mounted && requestGeneration == _usageRequestGeneration) {
        setState(() => _usageLoading = false);
      }
    }
  }

  void _changeType(String type) {
    if (type == _selectedType) return;
    // Preserve the user-entered key pool and key-management config across
    // provider switches (keys are provider-agnostic). Only the per-provider
    // text fields are reset.
    final next = _defaultService(type, _serviceId);
    final staleControllers = _controllers.values.toList();
    _controllers.clear();
    _initializeControllers(next);
    setState(() {
      _selectedType = type;
      _dirty = true;
      _testRequestGeneration++;
      _usageRequestGeneration++;
      _testing = false;
      _usageLoading = false;
      _testResult = null;
      _testError = null;
      _usage = _cachedUsage(_currentService());
      _usageError = null;
    });
    // Dispose the old controllers only after the frame rebuilt with the new
    // ones; disposing them synchronously would hit widgets still bound to
    // them mid-frame ("used after dispose").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in staleControllers) {
        controller.dispose();
      }
    });
  }

  void _markDirty() {
    setState(() {
      _dirty = true;
      _testRequestGeneration++;
      _usageRequestGeneration++;
      _testing = false;
      _usageLoading = false;
      _testResult = null;
      _testError = null;
      _usage = _cachedUsage(_currentService());
      _usageError = null;
    });
  }

  static SearchServiceUsageInfo? _cachedUsage(SearchServiceOptions? options) {
    if (options == null) return null;
    final key = _usageCacheKey(options);
    return key == null ? null : _usageCache[key];
  }

  static _SearchUsageCacheKey? _usageCacheKey(SearchServiceOptions options) {
    if (options is TavilyOptions) {
      return (
        id: options.id,
        provider: 'tavily',
        credential: options.apiKey.trim(),
        endpoint: options.resolvedUrl,
      );
    }
    if (options is LinkUpOptions) {
      return (
        id: options.id,
        provider: 'linkup',
        credential: options.apiKey.trim(),
        endpoint: '',
      );
    }
    return null;
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final current = _currentService();
    final keyed = SearchService.serviceUsesKeys(current);
    final hasUsableKey = current.apiKeys.any(
      (k) => k.isEnabled && k.key.trim().isNotEmpty,
    );
    if (keyed && !hasUsableKey && current is! FirecrawlOptions) {
      final l10n = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.searchServicesEditDialogApiKeyRequired)),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    _popWithResult(SearchServiceEditorResult.saved(current));
  }

  Future<void> _confirmDelete() async {
    if (!widget.canDelete || _leaving) return;
    final l10n = AppLocalizations.of(context)!;
    final providerName = SearchService.getService(_currentService()).name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.searchServiceEditorDeleteTitle),
        content: Text(l10n.searchServiceEditorDeleteMessage(providerName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.searchServicesAddDialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.searchServiceEditorDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      _popWithResult(const SearchServiceEditorResult.deleted());
    }
  }

  Future<void> _requestClose() async {
    if (_leaving) return;
    if (!_dirty) {
      _popWithResult(null);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.searchServiceEditorDiscardTitle),
        content: Text(l10n.searchServiceEditorDiscardMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.searchServiceEditorKeepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(l10n.searchServiceEditorDiscard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      _popWithResult(null);
    }
  }

  void _popWithResult(SearchServiceEditorResult? result) {
    if (_leaving) return;
    _leaving = true;
    _dirty = false;
    Navigator.of(context).pop(result);
  }

  void _initializeControllers(SearchServiceOptions service) {
    if (service is DuckDuckGoOptions) {
      _putController('region', service.region);
    } else if (service is TavilyOptions) {
      _putController('url', service.url);
    } else if (service is ExaOptions) {
      _putController('url', service.url);
    } else if (service is SearXNGOptions) {
      _putController('url', service.url);
      _putController('engines', service.engines);
      _putController('language', service.language);
      _putController('username', service.username);
      _putController('password', service.password);
    } else if (service is SerperOptions) {
      _putController('gl', service.gl);
      _putController('hl', service.hl);
      _putController('tbs', service.tbs);
      _putController('page', service.page == 1 ? '' : '${service.page}');
    } else if (service is QueritOptions) {
      _putController('sitesInclude', service.sitesInclude);
      _putController('sitesExclude', service.sitesExclude);
      _putController('timeRange', service.timeRange);
      _putController('countries', service.countries);
      _putController('languages', service.languages);
    } else if (service is GrokOptions) {
      _putController('model', service.model);
      _putController('reasoningEffort', service.reasoningEffort);
      _putController('customUrl', service.customUrl);
      _putController('systemPrompt', service.systemPrompt);
    } else if (service is StepFunOptions) {
      _putController('url', service.url);
      _putController('category', service.category);
    } else if (service is FirecrawlOptions) {
      _putController('url', service.url);
      _putController('country', service.country);
      _putController('location', service.location);
    } else if (service is TinyFishOptions) {
      _putController('url', service.url);
      _putController('location', service.location);
      _putController('language', service.language);
      _putController('includeDomains', service.includeDomains);
      _putController('excludeDomains', service.excludeDomains);
    }
  }

  void _putController(String key, String value) {
    _controllers[key] = TextEditingController(text: value);
  }

  TextEditingController _controller(String key) =>
      _controllers.putIfAbsent(key, TextEditingController.new);

  String _text(String key) => _controller(key).text.trim();

  SearchServiceOptions _currentService() {
    final initial = widget.initialService;
    switch (_selectedType) {
      case 'bing_local':
        return BingLocalOptions(
          id: _serviceId,
          acceptLanguage: initial is BingLocalOptions
              ? initial.acceptLanguage
              : 'en-US,en;q=0.9',
        );
      case 'duckduckgo':
        return DuckDuckGoOptions(
          id: _serviceId,
          region: _text('region').isEmpty ? 'us-en' : _text('region'),
        );
      case 'tavily':
        return TavilyOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          url: _text('url'),
        );
      case 'exa':
        return ExaOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          url: _text('url'),
        );
      case 'zhipu':
        return ZhipuOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
        );
      case 'searxng':
        return SearXNGOptions(
          id: _serviceId,
          url: _text('url'),
          engines: _text('engines'),
          language: _text('language'),
          username: _text('username'),
          password: _controller('password').text,
        );
      case 'linkup':
        return LinkUpOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
        );
      case 'brave':
        return BraveOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
        );
      case 'metaso':
        return MetasoOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
        );
      case 'ollama':
        return OllamaOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
        );
      case 'jina':
        return JinaOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
        );
      case 'perplexity':
        return PerplexityOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          country: initial is PerplexityOptions ? initial.country : null,
          searchDomainFilter: initial is PerplexityOptions
              ? initial.searchDomainFilter
              : null,
          maxTokensPerPage: initial is PerplexityOptions
              ? initial.maxTokensPerPage
              : null,
        );
      case 'bocha':
        return BochaOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          freshness: initial is BochaOptions ? initial.freshness : null,
          summary: initial is BochaOptions ? initial.summary : true,
          include: initial is BochaOptions ? initial.include : null,
          exclude: initial is BochaOptions ? initial.exclude : null,
        );
      case 'doubao':
        return DoubaoOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
        );
      case 'serper':
        return SerperOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          gl: _text('gl'),
          hl: _text('hl'),
          tbs: _text('tbs'),
          page: int.tryParse(_text('page')) ?? 1,
        );
      case 'querit':
        return QueritOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          sitesInclude: _text('sitesInclude'),
          sitesExclude: _text('sitesExclude'),
          timeRange: _text('timeRange'),
          countries: _text('countries'),
          languages: _text('languages'),
        );
      case 'grok':
        return GrokOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          model: _text('model'),
          reasoningEffort: _text('reasoningEffort'),
          customUrl: _text('customUrl'),
          systemPrompt: _controller('systemPrompt').text,
        );
      case 'stepfun':
        return StepFunOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          url: _text('url'),
          category: _text('category'),
        );
      case 'firecrawl':
        final existing = initial is FirecrawlOptions ? initial : null;
        return FirecrawlOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          url: _text('url'),
          sources: existing?.sources ?? const <String>['web'],
          categories: existing?.categories ?? const <String>[],
          country: _text('country'),
          location: _text('location'),
        );
      case 'tinyfish':
        return TinyFishOptions(
          id: _serviceId,
          apiKeys: _editKeys,
          keyManagement: _keyManagement,
          url: _text('url'),
          location: _text('location'),
          language: _text('language'),
          includeDomains: _text('includeDomains'),
          excludeDomains: _text('excludeDomains'),
        );
      default:
        return BingLocalOptions(id: _serviceId);
    }
  }
}

class _SearchServiceUsageCard extends StatelessWidget {
  const _SearchServiceUsageCard({
    required this.service,
    required this.usage,
    required this.error,
    required this.loading,
    required this.onQuery,
  });

  final SearchServiceOptions service;
  final SearchServiceUsageInfo? usage;
  final String? error;
  final bool loading;
  final VoidCallback onQuery;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return _sectionCard(
      context,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Lucide.Wallet, size: 18, color: cs.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.searchServiceEditorUsageTitle,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: AppFontWeights.semibold,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  key: const ValueKey('search-service-usage-query'),
                  message: loading
                      ? l10n.searchServiceEditorUsageQuerying
                      : l10n.searchServiceEditorUsageQuery,
                  child: loading
                      ? SizedBox.square(
                          dimension: 44,
                          child: Center(
                            child: SizedBox.square(
                              key: const ValueKey('usage-refreshing'),
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: cs.primary,
                              ),
                            ),
                          ),
                        )
                      : _EditorIconButton(
                          icon: Lucide.RefreshCw,
                          size: 18,
                          color: cs.primary,
                          semanticLabel: l10n.searchServiceEditorUsageQuery,
                          onTap: onQuery,
                        ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _buildStatus(context),
            ),
            if (usage != null && error != null) ...[
              const SizedBox(height: 10),
              _buildUsageError(context, error!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    if (loading && usage == null) {
      return Row(
        key: const ValueKey('usage-loading'),
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
          const SizedBox(width: 10),
          Text(
            l10n.searchServiceEditorUsageQuerying,
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      );
    }
    if (error != null && usage == null) {
      return _buildUsageError(context, error!);
    }
    final value = usage;
    if (value == null) {
      return Text(
        l10n.searchServiceEditorUsageNotQueried,
        key: const ValueKey('usage-empty'),
        style: TextStyle(
          fontSize: 13,
          color: cs.onSurface.withValues(alpha: 0.64),
        ),
      );
    }
    if (service is TavilyOptions && value.used != null && value.limit != null) {
      final limit = value.limit!;
      final progress = limit <= 0
          ? 0.0
          : (value.used! / limit).clamp(0.0, 1.0).toDouble();
      return Column(
        key: ValueKey(
          'tavily-usage-${value.remaining}-${value.used}-${value.limit}',
        ),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.searchServiceEditorUsageRemaining(
                    _formatUsageNumber(context, value.remaining),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                l10n.searchServiceEditorUsageUsed(
                  _formatUsageNumber(context, value.used!),
                  _formatUsageNumber(context, value.limit!),
                ),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 12.5,
                  color: cs.onSurface.withValues(alpha: 0.68),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const ValueKey('tavily-usage-progress'),
              value: progress,
              minHeight: 7,
              color: cs.primary,
              backgroundColor: cs.primary.withValues(alpha: 0.13),
            ),
          ),
        ],
      );
    }
    if (service is LinkUpOptions) {
      return Text(
        l10n.searchServiceEditorUsageBalance(
          _formatUsageNumber(context, value.remaining),
        ),
        key: ValueKey('linkup-balance-${value.remaining}'),
        style: TextStyle(
          fontSize: 20,
          fontWeight: AppFontWeights.semibold,
          color: cs.primary,
        ),
      );
    }
    return Text(
      l10n.searchServiceEditorUsageRemaining(
        _formatUsageNumber(context, value.remaining),
      ),
      key: ValueKey('usage-${value.remaining}'),
      style: TextStyle(
        fontSize: 17,
        fontWeight: AppFontWeights.semibold,
        color: cs.primary,
      ),
    );
  }

  Widget _buildUsageError(BuildContext context, String message) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return Row(
      key: ValueKey('usage-error-$message'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Lucide.TriangleAlert, size: 18, color: cs.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l10n.searchServiceEditorUsageFailed(message),
            style: TextStyle(fontSize: 13, height: 1.35, color: cs.error),
          ),
        ),
      ],
    );
  }
}

String _formatUsageNumber(BuildContext context, num value) {
  final format =
      NumberFormat.decimalPattern(
          Localizations.localeOf(context).toLanguageTag(),
        )
        ..minimumFractionDigits = 0
        ..maximumFractionDigits = 2;
  return format.format(value);
}

class _SearchEditorTextField extends StatefulWidget {
  const _SearchEditorTextField({
    super.key,
    required this.label,
    required this.controller,
    required this.onChanged,
    this.hint,
    this.obscure = false,
    this.keyboardType,
    this.minLines = 1,
    this.maxLines = 1,
    this.validator,
  });

  final String label;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool obscure;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final FormFieldValidator<String>? validator;

  @override
  State<_SearchEditorTextField> createState() => _SearchEditorTextFieldState();
}

class _SearchEditorTextFieldState extends State<_SearchEditorTextField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFontWeights.semibold,
            color: cs.onSurface.withValues(alpha: 0.72),
          ),
        ),
        const SizedBox(height: 7),
        TextFormField(
          controller: widget.controller,
          obscureText: widget.obscure && _obscured,
          keyboardType: widget.keyboardType,
          minLines: widget.obscure ? 1 : widget.minLines,
          maxLines: widget.obscure ? 1 : widget.maxLines,
          validator: widget.validator,
          onChanged: widget.onChanged,
          style: TextStyle(
            fontSize: 15,
            fontWeight: AppFontWeights.medium,
            color: cs.onSurface.withValues(alpha: 0.92),
          ),
          decoration: _inputDecoration(
            context,
            hint: widget.hint,
            suffix: widget.obscure
                ? _EditorIconButton(
                    icon: _obscured ? Lucide.Eye : Lucide.EyeOff,
                    size: 18,
                    minSize: 40,
                    semanticLabel: widget.label,
                    onTap: () => setState(() => _obscured = !_obscured),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

class _AddKeyDialog extends StatefulWidget {
  const _AddKeyDialog();

  @override
  State<_AddKeyDialog> createState() => _AddKeyDialogState();
}

class _AddKeyDialogState extends State<_AddKeyDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: cs.surface,
      title: Text(l10n.searchServicesDialogAddKey),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: l10n.searchServicesDialogApiKey),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.searchServicesEditDialogCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(l10n.searchServicesEditDialogSave),
        ),
      ],
    );
  }
}

class _AddKeyButton extends StatefulWidget {
  const _AddKeyButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_AddKeyButton> createState() => _AddKeyButtonState();
}

class _AddKeyButtonState extends State<_AddKeyButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark
        ? cs.primary.withValues(alpha: 0.18)
        : cs.primary.withValues(alpha: 0.11);
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: _pressed
                ? Color.alphaBlend(cs.onSurface.withValues(alpha: 0.08), base)
                : base,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: cs.primary.withValues(alpha: 0.28),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Lucide.Plus, size: 16, color: cs.primary),
              const SizedBox(width: 5),
              Text(
                AppLocalizations.of(context)!.searchServicesDialogAddKey,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: AppFontWeights.semibold,
                  color: cs.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderTypeChip extends StatefulWidget {
  const _ProviderTypeChip({
    required this.label,
    required this.brand,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String brand;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_ProviderTypeChip> createState() => _ProviderTypeChipState();
}

class _ProviderTypeChipState extends State<_ProviderTypeChip> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = widget.selected
        ? cs.primary.withValues(alpha: isDark ? 0.2 : 0.12)
        : (isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96));
    final overlay = _pressed
        ? cs.onSurface.withValues(alpha: 0.08)
        : (_hovered
              ? cs.onSurface.withValues(alpha: 0.04)
              : Colors.transparent);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Color.alphaBlend(overlay, base),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.selected
                    ? cs.primary.withValues(alpha: 0.42)
                    : cs.outlineVariant.withValues(alpha: 0.14),
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SearchBrandBadge(name: widget.brand, size: 24),
                const SizedBox(width: 7),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: AppFontWeights.semibold,
                    color: widget.selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchResultRow extends StatelessWidget {
  const _SearchResultRow({required this.item, required this.index});

  final SearchResultItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context)!;
    final webUri = _normalizeWebUri(item.url);
    return Semantics(
      button: webUri != null,
      label: webUri == null
          ? item.title
          : '${item.title}, ${l10n.searchServiceEditorResultOpenTooltip}',
      child: InkWell(
        onTap: webUri == null ? null : () => _openUrl(webUri),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 11),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: AppFontWeights.semibold,
                    color: cs.primary,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title.trim().isEmpty ? item.url : item.title.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        fontWeight: AppFontWeights.semibold,
                        color: cs.onSurface,
                      ),
                    ),
                    if (item.url.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.url.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: webUri == null
                              ? cs.onSurface.withValues(alpha: 0.58)
                              : cs.primary,
                        ),
                      ),
                    ],
                    if (item.text.trim().isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        item.text.trim(),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: cs.onSurface.withValues(alpha: 0.67),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (webUri != null) ...[
                const SizedBox(width: 8),
                Icon(
                  Lucide.ExternalLink,
                  size: 16,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static Uri? _normalizeWebUri(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('//')) {
      value = 'https:$value';
    } else {
      final isHostPort = RegExp(
        r'^(?:\[[^\]]+\]|[^/?#:\s]+):[0-9]+(?:[/?#]|$)',
      ).hasMatch(value);
      final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(value);
      if (isHostPort || !hasScheme) value = 'https://$value';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https' ? uri : null;
  }

  static Future<void> _openUrl(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) await launchUrl(uri);
    } catch (_) {
      // The visible URL remains selectable through the platform text menu.
    }
  }
}

class _SearchBrandBadge extends StatelessWidget {
  const _SearchBrandBadge({required this.name, this.size = 24});

  final String name;
  final double size;

  static Widget forService(SearchServiceOptions service, {double size = 24}) =>
      _SearchBrandBadge(name: _brandForService(service), size: size);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final asset = BrandAssets.assetForName(name);
    final bg = cs.primary.withValues(alpha: isDark ? 0.18 : 0.1);
    final childSize = size * 0.62;
    Widget child;
    if (asset == null) {
      child = Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: cs.primary,
          fontSize: size * 0.42,
          fontWeight: AppFontWeights.emphasis,
        ),
      );
    } else if (asset.endsWith('.svg')) {
      child = SvgPicture.asset(
        asset,
        width: childSize,
        height: childSize,
        colorFilter: isDark && BrandAssets.assetNeedsDarkInvert(asset)
            ? ColorFilter.mode(cs.onSurface, BlendMode.srcIn)
            : null,
      );
    } else {
      child = Image.asset(
        asset,
        width: childSize,
        height: childSize,
        fit: BoxFit.contain,
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: child,
    );
  }
}

class _EditorIconButton extends StatefulWidget {
  const _EditorIconButton({
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
    this.color,
    this.size = 22,
    this.minSize = 44,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String semanticLabel;
  final Color? color;
  final double size;
  final double minSize;

  @override
  State<_EditorIconButton> createState() => _EditorIconButtonState();
}

class _EditorIconButtonState extends State<_EditorIconButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = widget.color ?? cs.onSurface;
    final bg = _pressed
        ? cs.onSurface.withValues(alpha: 0.1)
        : (_hovered
              ? cs.onSurface.withValues(alpha: isDark ? 0.08 : 0.06)
              : Colors.transparent);
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: widget.minSize,
              minHeight: widget.minSize,
            ),
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(widget.icon, size: widget.size, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SquareActionButton extends StatefulWidget {
  const _SquareActionButton({
    required this.enabled,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
  });

  final bool enabled;
  final String semanticLabel;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_SquareActionButton> createState() => _SquareActionButtonState();
}

class _SquareActionButtonState extends State<_SquareActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark
        ? cs.primary.withValues(alpha: 0.18)
        : cs.primary.withValues(alpha: 0.11);
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled
            ? (_) => setState(() => _pressed = true)
            : null,
        onTapUp: widget.enabled
            ? (_) => setState(() => _pressed = false)
            : null,
        onTapCancel: widget.enabled
            ? () => setState(() => _pressed = false)
            : null,
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedOpacity(
          opacity: widget.enabled ? 1 : 0.42,
          duration: const Duration(milliseconds: 160),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _pressed
                  ? Color.alphaBlend(cs.onSurface.withValues(alpha: 0.08), base)
                  : base,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: cs.primary.withValues(alpha: 0.28),
                width: 0.8,
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

InputDecoration _inputDecoration(
  BuildContext context, {
  String? hint,
  Widget? suffix,
}) {
  final cs = Theme.of(context).colorScheme;
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final fieldBg = cs.surfaceContainerHighest.withValues(
    alpha: isDark ? 0.18 : 0.5,
  );
  return InputDecoration(
    hintText: hint,
    isDense: true,
    filled: true,
    fillColor: fieldBg,
    hintStyle: TextStyle(
      fontSize: 14,
      color: cs.onSurface.withValues(alpha: 0.58),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.primary, width: 1),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.error, width: 1),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.error, width: 1),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    suffixIcon: suffix,
    suffixIconConstraints: const BoxConstraints.tightFor(width: 44, height: 44),
  );
}

Widget _sectionCard(BuildContext context, {required Widget child}) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  final isDark = theme.brightness == Brightness.dark;
  final bg = isDark ? Colors.white10 : Colors.white.withValues(alpha: 0.96);
  return Container(
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: cs.outlineVariant.withValues(alpha: isDark ? 0.08 : 0.06),
        width: 0.6,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

Widget _sectionHeader(BuildContext context, String text, {bool first = false}) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: EdgeInsets.fromLTRB(12, first ? 2 : 20, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: AppFontWeights.semibold,
        color: cs.onSurface.withValues(alpha: 0.78),
      ),
    ),
  );
}

String _cleanError(Object error) {
  var message = error.toString().trim();
  while (message.startsWith('Exception: ')) {
    message = message.substring('Exception: '.length).trim();
  }
  return message;
}

bool _hasUsageCredential(SearchServiceOptions? options) {
  return switch (options) {
    TavilyOptions value => value.apiKey.trim().isNotEmpty,
    LinkUpOptions value => value.apiKey.trim().isNotEmpty,
    _ => false,
  };
}

String _typeForService(SearchServiceOptions service) {
  if (service is BingLocalOptions) return 'bing_local';
  if (service is DuckDuckGoOptions) return 'duckduckgo';
  if (service is TavilyOptions) return 'tavily';
  if (service is ExaOptions) return 'exa';
  if (service is ZhipuOptions) return 'zhipu';
  if (service is SearXNGOptions) return 'searxng';
  if (service is LinkUpOptions) return 'linkup';
  if (service is BraveOptions) return 'brave';
  if (service is MetasoOptions) return 'metaso';
  if (service is JinaOptions) return 'jina';
  if (service is OllamaOptions) return 'ollama';
  if (service is PerplexityOptions) return 'perplexity';
  if (service is BochaOptions) return 'bocha';
  if (service is DoubaoOptions) return 'doubao';
  if (service is SerperOptions) return 'serper';
  if (service is QueritOptions) return 'querit';
  if (service is GrokOptions) return 'grok';
  if (service is StepFunOptions) return 'stepfun';
  if (service is FirecrawlOptions) return 'firecrawl';
  if (service is TinyFishOptions) return 'tinyfish';
  return 'bing_local';
}

String _brandForService(SearchServiceOptions service) {
  final type = _typeForService(service);
  return type == 'bing_local' ? 'bing' : type;
}

SearchServiceOptions _defaultService(String type, String id) {
  switch (type) {
    case 'bing_local':
      return BingLocalOptions(id: id);
    case 'duckduckgo':
      return DuckDuckGoOptions(id: id);
    case 'tavily':
      return TavilyOptions(id: id);
    case 'exa':
      return ExaOptions(id: id);
    case 'zhipu':
      return ZhipuOptions(id: id);
    case 'searxng':
      return SearXNGOptions(id: id, url: '');
    case 'linkup':
      return LinkUpOptions(id: id);
    case 'brave':
      return BraveOptions(id: id);
    case 'metaso':
      return MetasoOptions(id: id);
    case 'jina':
      return JinaOptions(id: id);
    case 'ollama':
      return OllamaOptions(id: id);
    case 'perplexity':
      return PerplexityOptions(id: id);
    case 'bocha':
      return BochaOptions(id: id);
    case 'doubao':
      return DoubaoOptions(id: id);
    case 'serper':
      return SerperOptions(id: id);
    case 'querit':
      return QueritOptions(id: id);
    case 'grok':
      return GrokOptions(id: id);
    case 'stepfun':
      return StepFunOptions(id: id);
    case 'firecrawl':
      return FirecrawlOptions(id: id);
    case 'tinyfish':
      return TinyFishOptions(id: id);
    default:
      return BingLocalOptions(id: id);
  }
}

String _serviceTypeName(BuildContext context, String type) {
  final l10n = AppLocalizations.of(context)!;
  switch (type) {
    case 'bing_local':
      return l10n.searchServiceNameBingLocal;
    case 'duckduckgo':
      return l10n.searchServiceNameDuckDuckGo;
    case 'tavily':
      return l10n.searchServiceNameTavily;
    case 'exa':
      return l10n.searchServiceNameExa;
    case 'zhipu':
      return l10n.searchServiceNameZhipu;
    case 'searxng':
      return l10n.searchServiceNameSearXNG;
    case 'linkup':
      return l10n.searchServiceNameLinkUp;
    case 'brave':
      return l10n.searchServiceNameBrave;
    case 'metaso':
      return l10n.searchServiceNameMetaso;
    case 'jina':
      return l10n.searchServiceNameJina;
    case 'ollama':
      return l10n.searchServiceNameOllama;
    case 'perplexity':
      return l10n.searchServiceNamePerplexity;
    case 'bocha':
      return l10n.searchServiceNameBocha;
    case 'doubao':
      return l10n.searchServiceNameDoubao;
    case 'serper':
      return l10n.searchServiceNameSerper;
    case 'querit':
      return l10n.searchServiceNameQuerit;
    case 'grok':
      return l10n.searchServiceNameGrok;
    case 'stepfun':
      return l10n.searchServiceNameStepFun;
    case 'firecrawl':
      return l10n.searchServiceNameFirecrawl;
    case 'tinyfish':
      return l10n.searchServiceNameTinyFish;
    default:
      return type;
  }
}

const _providerTypes = <({String type, String brand})>[
  (type: 'bing_local', brand: 'bing'),
  (type: 'duckduckgo', brand: 'duckduckgo'),
  (type: 'tavily', brand: 'tavily'),
  (type: 'exa', brand: 'exa'),
  (type: 'zhipu', brand: 'zhipu'),
  (type: 'searxng', brand: 'searxng'),
  (type: 'linkup', brand: 'linkup'),
  (type: 'brave', brand: 'brave'),
  (type: 'metaso', brand: 'metaso'),
  (type: 'jina', brand: 'jina'),
  (type: 'ollama', brand: 'ollama'),
  (type: 'perplexity', brand: 'perplexity'),
  (type: 'bocha', brand: 'bocha'),
  (type: 'doubao', brand: 'doubao'),
  (type: 'serper', brand: 'serper'),
  (type: 'querit', brand: 'querit'),
  (type: 'grok', brand: 'grok'),
  (type: 'stepfun', brand: 'stepfun'),
  (type: 'firecrawl', brand: 'firecrawl'),
  (type: 'tinyfish', brand: 'tinyfish'),
];
