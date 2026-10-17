import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xml/xml.dart';
import '../providers/app_state.dart';
import '../l10n/app_localizations.dart';

class ToolsInspectorView extends StatefulWidget {
  const ToolsInspectorView({super.key});

  @override
  State<ToolsInspectorView> createState() => _ToolsInspectorViewState();
}

class _ToolsInspectorViewState extends State<ToolsInspectorView> {
  XmlDocument? _xmlDoc;
  XmlElement? _selectedNode;
  File? _screenshot;
  bool _isLoading = false;
  final Set<XmlElement> _expandedNodes = {};
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = "";

  // 寬度比例控制
  double _previewWidth = 360;
  double _treeWidth = 400;
  bool _isInitialized = false;

  Size? _imageOriginalSize;
  final ScrollController _treeScrollCtrl = ScrollController();
  final Map<XmlElement, GlobalKey> _nodeKeys = {};
  int _dumpGeneration = 0;

  @override
  void dispose() {
    _dumpGeneration++;
    _searchCtrl.dispose();
    _treeScrollCtrl.dispose();
    final screenshot = _screenshot;
    if (screenshot != null) {
      screenshot.delete().catchError((_) => screenshot);
    }
    super.dispose();
  }

  Future<void> _dump() async {
    if (_isLoading) return;
    final appState = context.read<AppState>();
    final serial = appState.currentDevice;
    if (serial == null || !appState.isConnected) return;
    final deviceEpoch = appState.deviceSessionEpoch;
    final generation = ++_dumpGeneration;
    setState(() => _isLoading = true);
    File? capturedScreenshot;

    try {
      // 同时抓取 XML 和 截图
      final results = await Future.wait([
        appState.adb.dumpUi(serial: serial),
        appState.adb.takeScreenshot(serial: serial),
      ]);

      final xmlStr = results[0] as String;
      final screenFile = results[1] as File?;
      capturedScreenshot = screenFile;
      if (!_isCaptureCurrent(appState, generation, serial, deviceEpoch)) {
        await _deleteScreenshot(screenFile);
        capturedScreenshot = null;
        return;
      }

      if (screenFile != null) {
        await FileImage(screenFile).evict();
      }
      if (!_isCaptureCurrent(appState, generation, serial, deviceEpoch)) {
        await _deleteScreenshot(screenFile);
        capturedScreenshot = null;
        return;
      }

      XmlDocument? document;
      if (xmlStr.isNotEmpty) {
        try {
          document = XmlDocument.parse(xmlStr);
        } catch (_) {}
      }

      Size? imageSize;
      if (screenFile != null && await screenFile.exists()) {
        try {
          final bytes = await screenFile.readAsBytes();
          final decoded = await decodeImageFromList(bytes);
          imageSize = Size(decoded.width.toDouble(), decoded.height.toDouble());
          decoded.dispose();
        } catch (_) {}
      }
      if (!_isCaptureCurrent(appState, generation, serial, deviceEpoch)) {
        await _deleteScreenshot(screenFile);
        capturedScreenshot = null;
        return;
      }

      final previousScreenshot = _screenshot;

      setState(() {
        _xmlDoc = document;
        _expandedNodes.clear();
        _nodeKeys.clear();
        if (_xmlDoc != null) _autoExpand(_xmlDoc!.rootElement);
        _imageOriginalSize = imageSize;
        _screenshot = screenFile;
        _selectedNode = null;
      });
      capturedScreenshot = null;
      if (previousScreenshot != null &&
          previousScreenshot.path != screenFile?.path) {
        await FileImage(previousScreenshot).evict();
        await _deleteScreenshot(previousScreenshot);
      }
    } catch (e) {
      await _deleteScreenshot(capturedScreenshot);
      if (appState.isDeviceSessionActive(serial, deviceEpoch)) {
        appState.addLog('Inspector capture failed: $e');
      }
    } finally {
      if (mounted && generation == _dumpGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  bool _isCaptureCurrent(
    AppState appState,
    int generation,
    String serial,
    int deviceEpoch,
  ) =>
      mounted &&
      generation == _dumpGeneration &&
      appState.isDeviceSessionActive(serial, deviceEpoch);

  Future<void> _deleteScreenshot(File? screenshot) async {
    if (screenshot == null) return;
    try {
      if (await screenshot.exists()) await screenshot.delete();
    } catch (_) {}
  }

  void _autoExpand(XmlElement node) {
    _expandedNodes.add(node);
    for (var child in node.findElements('node')) {
      if (node.findElements('node').length < 3) {
        _autoExpand(child);
      }
    }
  }

  Rect? _getBounds(XmlElement? node) {
    if (node == null) return null;
    final boundsStr = node.getAttribute('bounds');
    if (boundsStr == null) return null;
    // 格式 [left,top][right,bottom]
    final regex = RegExp(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]");
    final match = regex.firstMatch(boundsStr);
    if (match != null) {
      final left = double.parse(match.group(1)!);
      final top = double.parse(match.group(2)!);
      final right = double.parse(match.group(3)!);
      final bottom = double.parse(match.group(4)!);
      return Rect.fromLTRB(left, top, right, bottom);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final i18n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Column(
      children: [
        // 工具栏
        Container(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: _isLoading ? null : _dump,
                icon: const Icon(Icons.videocam_outlined),
                label: Text(i18n.toolsInspDump),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: "Search Text or ID...",
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onChanged: (val) {
                    final query = val.toLowerCase();
                    setState(() => _searchQuery = query);
                    if (query.isNotEmpty) {
                      final match =
                          _findFirstMatch(_xmlDoc?.rootElement, query);
                      if (match != null) {
                        setState(() {
                          _selectedNode = match;
                          // 自動展開路徑
                          var parent = match.parent;
                          while (parent != null && parent is XmlElement) {
                            _expandedNodes.add(parent);
                            parent = parent.parent;
                          }
                        });
                        _scrollToSelected();
                      }
                    }
                  },
                ),
              ),
              if (_isLoading) ...[
                const SizedBox(width: 16),
                const CircularProgressIndicator(),
              ],
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            if (!_isInitialized) {
              _treeWidth = (constraints.maxWidth - _previewWidth) * 0.6;
              _isInitialized = true;
            }

            return Stack(
              children: [
                Row(
                  children: [
                    // 1. 截圖預覽區
                    SizedBox(
                      width: _previewWidth,
                      child: Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.05),
                        ),
                        child: _screenshot == null
                            ? const Center(
                                child: Icon(Icons.screenshot_outlined,
                                    size: 80, color: Colors.grey))
                            : _buildScreenshotPreview(),
                      ),
                    ),
                    // 分隔線 1
                    _buildDivider(
                      onDrag: (delta) {
                        setState(() {
                          _previewWidth = (_previewWidth + delta)
                              .clamp(100, constraints.maxWidth - 200);
                        });
                      },
                    ),
                    // 2. 樹狀結構區
                    SizedBox(
                      width: _treeWidth,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.symmetric(
                              vertical: BorderSide(color: theme.dividerColor)),
                        ),
                        child: _xmlDoc == null
                            ? const Center(
                                child: Icon(Icons.account_tree_outlined,
                                    size: 80, color: Colors.grey))
                            : ListView(
                                controller: _treeScrollCtrl,
                                children: [_buildNode(_xmlDoc!.rootElement)],
                              ),
                      ),
                    ),
                    // 分隔線 2
                    _buildDivider(
                      onDrag: (delta) {
                        setState(() {
                          _treeWidth = (_treeWidth + delta).clamp(
                              100, constraints.maxWidth - _previewWidth - 100);
                        });
                      },
                    ),
                    // 3. 屬性詳情區
                    Expanded(
                      child: _buildPropertyPanel(),
                    ),
                  ],
                ),
              ],
            );
          }),
        ),
      ],
    );
  }

  Widget _buildDivider({required Function(double) onDrag}) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: (details) => onDrag(details.delta.dx),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: Container(
          width: 8,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 1,
              color: Theme.of(context).dividerColor,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScreenshotPreview() {
    if (_screenshot == null || _imageOriginalSize == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(builder: (context, constraints) {
      // 計算圖片在 BoxFit.contain 下的實際顯示尺寸和偏移
      final double containerW = constraints.maxWidth;
      final double containerH = constraints.maxHeight;
      final double imgW = _imageOriginalSize!.width;
      final double imgH = _imageOriginalSize!.height;

      final double scale = (containerW / imgW < containerH / imgH)
          ? containerW / imgW
          : containerH / imgH;

      final double displayedW = imgW * scale;
      final double displayedH = imgH * scale;
      final double offsetX = (containerW - displayedW) / 2;
      final double offsetY = (containerH - displayedH) / 2;

      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final localPos = details.localPosition;
            // 轉換為設備坐標
            final double deviceX = (localPos.dx - offsetX) / scale;
            final double deviceY = (localPos.dy - offsetY) / scale;

            if (deviceX >= 0 &&
                deviceX <= imgW &&
                deviceY >= 0 &&
                deviceY <= imgH) {
              final node = _findNodeAt(_xmlDoc?.rootElement, deviceX, deviceY);
              if (node != null) {
                setState(() {
                  _selectedNode = node;
                  // 自動展開選中路徑
                  var parent = node.parent;
                  while (parent != null && parent is XmlElement) {
                    _expandedNodes.add(parent);
                    parent = parent.parent;
                  }
                });
                _scrollToSelected();
              }
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
                child: Image.file(
                  _screenshot!,
                  key: ValueKey(_screenshot!.path),
                  fit: BoxFit.contain,
                ),
              ),
              if (_selectedNode != null)
                _buildBoundsHighlight(scale, offsetX, offsetY),
            ],
          ),
        ),
      );
    });
  }

  XmlElement? _findFirstMatch(XmlElement? root, String query) {
    if (root == null) return null;
    final text = root.getAttribute('text')?.toLowerCase() ?? "";
    final id = root.getAttribute('resource-id')?.toLowerCase() ?? "";
    if (text.contains(query) || id.contains(query)) return root;

    for (var child in root.findElements('node')) {
      final match = _findFirstMatch(child, query);
      if (match != null) return match;
    }
    return null;
  }

  void _scrollToSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_selectedNode == null) return;
      final key = _nodeKeys[_selectedNode];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  XmlElement? _findNodeAt(XmlElement? root, double x, double y) {
    if (root == null) return null;

    final bounds = _getBounds(root);
    if (bounds != null && !bounds.contains(Offset(x, y))) {
      return null;
    }

    // 收集所有匹配的子節點
    List<XmlElement> matches = [];
    for (var child in root.findElements('node')) {
      final match = _findNodeAt(child, x, y);
      if (match != null) {
        matches.add(match);
      }
    }

    if (matches.isNotEmpty) {
      // 在匹配項中尋找「面積最小」的節點（通常是最具體的元件）
      matches.sort((a, b) {
        final bA = _getBounds(a);
        final bB = _getBounds(b);
        if (bA == null) return 1;
        if (bB == null) return -1;
        return (bA.width * bA.height).compareTo(bB.width * bB.height);
      });
      return matches.first;
    }

    // 如果沒有子節點匹配，但當前節點本身匹配，則返回當前節點
    return bounds != null ? root : null;
  }

  Widget _buildBoundsHighlight(double scale, double offsetX, double offsetY) {
    final bounds = _getBounds(_selectedNode);
    if (bounds == null) return const SizedBox.shrink();

    return Positioned(
      left: offsetX + bounds.left * scale,
      top: offsetY + bounds.top * scale,
      width: bounds.width * scale,
      height: bounds.height * scale,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.red, width: 2),
            color: Colors.red.withValues(alpha: 0.2),
          ),
        ),
      ),
    );
  }

  Widget _buildPropertyPanel() {
    final i18n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    if (_selectedNode == null) {
      return Center(
          child: Text(i18n.toolsInspNodeInfo,
              style: const TextStyle(color: Colors.grey)));
    }

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(i18n.toolsInspNodeInfo, style: theme.textTheme.titleMedium),
          const Divider(),
          Expanded(
            child: ListView(
              children: _selectedNode!.attributes.map((attr) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(attr.name.local,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: Colors.grey)),
                      SelectableText(attr.value,
                          style: TextStyle(
                              color: theme.colorScheme.primary, fontSize: 14)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNode(XmlElement node, {int depth = 0}) {
    final theme = Theme.of(context);
    final children = node.findElements('node').toList();
    final String text = node.getAttribute('text') ?? "";
    final String id = node.getAttribute('resource-id')?.split('/').last ?? "";

    final bool isExpanded = _expandedNodes.contains(node);
    final bool isSelected = _selectedNode == node;
    final bool hasChildren = children.isNotEmpty;
    final bool isMatched = _searchQuery.isNotEmpty &&
        (text.toLowerCase().contains(_searchQuery) ||
            id.toLowerCase().contains(_searchQuery));

    // 如果子節點中有匹配項，自動展開父節點
    if (_searchQuery.isNotEmpty && !isExpanded) {
      bool hasMatchInDescendants(XmlElement n) {
        for (var child in n.findElements('node')) {
          final cText = child.getAttribute('text')?.toLowerCase() ?? "";
          final cId = child.getAttribute('resource-id')?.toLowerCase() ?? "";
          if (cText.contains(_searchQuery) || cId.contains(_searchQuery)) {
            return true;
          }
          if (hasMatchInDescendants(child)) return true;
        }
        return false;
      }

      if (hasMatchInDescendants(node)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_expandedNodes.contains(node)) {
            setState(() => _expandedNodes.add(node));
          }
        });
      }
    }

    final key = _nodeKeys.putIfAbsent(node, () => GlobalKey());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: key,
          onTap: () => setState(() => _selectedNode = node),
          onDoubleTap: () {
            setState(() {
              if (isExpanded) {
                _expandedNodes.remove(node);
              } else {
                _expandedNodes.add(node);
              }
              _selectedNode = node;
            });
          },
          child: Container(
            color: isSelected
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                : (isMatched ? Colors.yellow.withValues(alpha: 0.3) : null),
            padding: EdgeInsets.only(left: depth * 12.0, top: 2, bottom: 2),
            child: Row(
              children: [
                if (hasChildren)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      isExpanded ? Icons.arrow_drop_down : Icons.arrow_right,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() {
                        if (isExpanded) {
                          _expandedNodes.remove(node);
                        } else {
                          _expandedNodes.add(node);
                        }
                      });
                    },
                  )
                else
                  const SizedBox(width: 40),
                Icon(
                  hasChildren
                      ? Icons.folder_open_outlined
                      : Icons.widgets_outlined,
                  size: 16,
                  color: isSelected ? theme.colorScheme.primary : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text("<",
                    style:
                        TextStyle(color: Colors.grey.withValues(alpha: 0.5))),
                Text(
                  node.name.local,
                  style: TextStyle(
                    color: isSelected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.secondary,
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                if (text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      "text=\"$text\"",
                      style: const TextStyle(color: Colors.blue, fontSize: 12),
                    ),
                  ),
                if (id.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      "id=\"$id\"",
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                Text(">",
                    style:
                        TextStyle(color: Colors.grey.withValues(alpha: 0.5))),
              ],
            ),
          ),
        ),
        if (isExpanded) ...children.map((c) => _buildNode(c, depth: depth + 1)),
      ],
    );
  }
}
