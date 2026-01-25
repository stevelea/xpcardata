import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app manual viewer
/// Displays the user manual with navigation and search
class ManualScreen extends StatefulWidget {
  const ManualScreen({super.key});

  @override
  State<ManualScreen> createState() => _ManualScreenState();
}

class _ManualScreenState extends State<ManualScreen> {
  String _manualContent = '';
  bool _isLoading = true;
  String _searchQuery = '';
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _showSearch = false;

  // Table of contents for quick navigation
  final List<_Section> _sections = [
    _Section('Introduction', 'introduction'),
    _Section('Installation', 'installation'),
    _Section('Quick Start', 'quick-start'),
    _Section('AI Box Setup', 'android-ai-box-setup'),
    _Section('Dashboard', 'dashboard-overview'),
    _Section('OBD-II Connection', 'obd-ii-connection'),
    _Section('MQTT & Home Assistant', 'mqtt--home-assistant'),
    _Section('ABRP Integration', 'abrp-integration'),
    _Section('Tailscale VPN', 'tailscale-vpn'),
    _Section('Charging Sessions', 'charging-sessions'),
    _Section('Fleet Statistics', 'fleet-statistics'),
    _Section('Settings', 'settings-reference'),
    _Section('Troubleshooting', 'troubleshooting'),
    _Section('Privacy', 'privacy--data'),
  ];

  @override
  void initState() {
    super.initState();
    _loadManual();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadManual() async {
    try {
      final content = await rootBundle.loadString('docs/MANUAL.md');
      setState(() {
        _manualContent = content;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _manualContent = _getFallbackManual();
        _isLoading = false;
      });
    }
  }

  String _getFallbackManual() {
    return '''
# XPCarData User Manual

## Quick Start

1. **Install the app** on your Android device
2. **Connect OBD-II adapter** to your vehicle's OBD port
3. **Scan and connect** via Settings > OBD-II Connection
4. **View real-time data** on the dashboard

## AI Box Setup

For Android AI Boxes (Carlinkit, Ottocast), the car's 12V system must remain powered for charging monitoring.

### Enable 12V Power During Charging

Use the XPENG app to create an automation:
1. Open XPENG App > Vehicle > Automation
2. Create rule: "Keep 12V on Exit 24 Hours"
3. Conditions: Driver Exit + Door Closed
4. Action: Trunk Power Delay Off = 24 hours

This keeps 12V active for charging session monitoring.

## Key Features

- **Real-time monitoring** - SOC, voltage, current, temperature
- **Charging tracking** - Automatic session detection
- **MQTT integration** - Home Assistant auto-discovery
- **ABRP telemetry** - Route planning integration
- **Fleet statistics** - Anonymous benchmarking

## Support

- GitHub: https://github.com/stevelea/xpcardata
- Full manual: https://github.com/stevelea/xpcardata/blob/main/docs/MANUAL.md
''';
  }

  void _scrollToSection(String anchor) {
    // Find the section in the content
    final pattern = RegExp(r'## ' + RegExp.escape(anchor.replaceAll('-', ' ')), caseSensitive: false);
    final match = pattern.firstMatch(_manualContent);
    if (match != null) {
      // Estimate scroll position based on character position
      final charPosition = match.start;
      final totalChars = _manualContent.length;
      final scrollPosition = (charPosition / totalChars) * _scrollController.position.maxScrollExtent;
      _scrollController.animateTo(
        scrollPosition,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
    Navigator.pop(context); // Close drawer
  }

  void _openOnGitHub() async {
    final uri = Uri.parse('https://github.com/stevelea/xpcardata/blob/main/docs/MANUAL.md');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open browser: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _showSearch
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search manual...',
                  border: InputBorder.none,
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value.toLowerCase();
                  });
                },
              )
            : const Text('User Manual'),
        actions: [
          IconButton(
            icon: Icon(_showSearch ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _searchController.clear();
                  _searchQuery = '';
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Open on GitHub',
            onPressed: _openOnGitHub,
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Row(
                  children: [
                    Icon(
                      Icons.menu_book,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Contents',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _sections.length,
                  itemBuilder: (context, index) {
                    final section = _sections[index];
                    return ListTile(
                      leading: Text(
                        '${index + 1}.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      title: Text(section.title),
                      onTap: () => _scrollToSection(section.anchor),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              child: _buildManualContent(),
            ),
    );
  }

  Widget _buildManualContent() {
    final lines = _manualContent.split('\n');
    final widgets = <Widget>[];

    bool inCodeBlock = false;
    StringBuffer codeBuffer = StringBuffer();
    bool inTable = false;
    List<String> tableRows = [];

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Skip lines that don't match search
      if (_searchQuery.isNotEmpty) {
        // For search, we need to check if any nearby content matches
        final searchWindow = lines.sublist(
          (i - 2).clamp(0, lines.length),
          (i + 3).clamp(0, lines.length),
        ).join(' ').toLowerCase();
        if (!searchWindow.contains(_searchQuery)) {
          continue;
        }
      }

      // Code blocks
      if (line.startsWith('```')) {
        if (inCodeBlock) {
          widgets.add(_buildCodeBlock(codeBuffer.toString()));
          codeBuffer.clear();
          inCodeBlock = false;
        } else {
          inCodeBlock = true;
        }
        continue;
      }

      if (inCodeBlock) {
        codeBuffer.writeln(line);
        continue;
      }

      // Tables
      if (line.startsWith('|')) {
        if (!inTable) {
          inTable = true;
          tableRows = [];
        }
        tableRows.add(line);
        continue;
      } else if (inTable) {
        widgets.add(_buildTable(tableRows));
        tableRows = [];
        inTable = false;
      }

      // Headers
      if (line.startsWith('# ')) {
        widgets.add(const SizedBox(height: 24));
        widgets.add(_buildHeader(line.substring(2), 1));
        widgets.add(const Divider(thickness: 2));
      } else if (line.startsWith('## ')) {
        widgets.add(const SizedBox(height: 20));
        widgets.add(_buildHeader(line.substring(3), 2));
        widgets.add(const Divider());
      } else if (line.startsWith('### ')) {
        widgets.add(const SizedBox(height: 16));
        widgets.add(_buildHeader(line.substring(4), 3));
      } else if (line.startsWith('#### ')) {
        widgets.add(const SizedBox(height: 12));
        widgets.add(_buildHeader(line.substring(5), 4));
      }
      // Horizontal rule
      else if (line == '---') {
        widgets.add(const Divider(thickness: 1, height: 32));
      }
      // List items
      else if (line.startsWith('- ') || line.startsWith('* ')) {
        widgets.add(_buildListItem(line.substring(2), false));
      } else if (RegExp(r'^\d+\. ').hasMatch(line)) {
        final match = RegExp(r'^(\d+)\. (.*)').firstMatch(line);
        if (match != null) {
          widgets.add(_buildListItem(match.group(2)!, true, int.parse(match.group(1)!)));
        }
      }
      // Regular paragraph
      else if (line.trim().isNotEmpty) {
        widgets.add(_buildParagraph(line));
      }
      // Empty line
      else {
        widgets.add(const SizedBox(height: 8));
      }
    }

    // Handle any remaining table
    if (inTable && tableRows.isNotEmpty) {
      widgets.add(_buildTable(tableRows));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _buildHeader(String text, int level) {
    final styles = {
      1: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold),
      2: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
      3: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
      4: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: styles[level] ?? styles[4],
      ),
    );
  }

  Widget _buildParagraph(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: _buildRichText(text),
    );
  }

  Widget _buildRichText(String text) {
    // Parse inline formatting: **bold**, *italic*, `code`, [link](url)
    final spans = <TextSpan>[];
    final pattern = RegExp(
      r'\*\*(.+?)\*\*|'  // Bold
      r'\*(.+?)\*|'      // Italic
      r'`(.+?)`|'        // Inline code
      r'\[(.+?)\]\((.+?)\)',  // Links
    );

    int lastEnd = 0;
    for (final match in pattern.allMatches(text)) {
      // Add text before match
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }

      if (match.group(1) != null) {
        // Bold
        spans.add(TextSpan(
          text: match.group(1),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (match.group(2) != null) {
        // Italic
        spans.add(TextSpan(
          text: match.group(2),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      } else if (match.group(3) != null) {
        // Inline code
        spans.add(TextSpan(
          text: match.group(3),
          style: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        ));
      } else if (match.group(4) != null && match.group(5) != null) {
        // Link - just show the text
        spans.add(TextSpan(
          text: match.group(4),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline,
          ),
        ));
      }

      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }

    if (spans.isEmpty) {
      spans.add(TextSpan(text: text));
    }

    return Text.rich(
      TextSpan(
        style: Theme.of(context).textTheme.bodyMedium,
        children: spans,
      ),
    );
  }

  Widget _buildListItem(String text, bool ordered, [int? number]) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              ordered ? '$number.' : '\u2022',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Expanded(child: _buildRichText(text)),
        ],
      ),
    );
  }

  Widget _buildCodeBlock(String code) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          code.trimRight(),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildTable(List<String> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();

    // Parse table rows
    final parsedRows = rows.map((row) {
      return row
          .split('|')
          .where((cell) => cell.isNotEmpty)
          .map((cell) => cell.trim())
          .toList();
    }).toList();

    // Skip separator row (contains ---)
    final dataRows = parsedRows.where((row) {
      return !row.any((cell) => cell.contains('---'));
    }).toList();

    if (dataRows.isEmpty) return const SizedBox.shrink();

    final headerRow = dataRows.first;
    final bodyRows = dataRows.skip(1).toList();

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
          columns: headerRow.map((cell) {
            return DataColumn(
              label: Text(
                cell,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            );
          }).toList(),
          rows: bodyRows.map((row) {
            return DataRow(
              cells: List.generate(headerRow.length, (i) {
                return DataCell(Text(i < row.length ? row[i] : ''));
              }),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _Section {
  final String title;
  final String anchor;

  _Section(this.title, this.anchor);
}
