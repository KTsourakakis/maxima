import 'dart:collection';
import 'dart:math';

import 'remote_ai_gateway.dart';

class SearchResult {
    const SearchResult({
        required this.id,
        required this.source,
        required this.text,
        required this.score,
    });

    final String id;
    final String source;
    final String text;
    final double score;
}

class CognitiveSearch {
    CognitiveSearch({
        RemoteAiGateway? gateway,
        this.chunkSize = 1200,
        this.chunkOverlap = 160,
        this.maxNodes = 5000,
        this.lexicalDimensions = 384,
    }) : _gateway = gateway,
         _index = HnswVectorIndex(maxElements: maxNodes);

    RemoteAiGateway? _gateway;
    final int chunkSize;
    final int chunkOverlap;
    final int maxNodes;
    final int lexicalDimensions;
    final HnswVectorIndex _index;
    int _documentCounter = 0;

    /// Repoints embedding lookups when the remote host is
    /// (re)configured at runtime.
    set gateway(RemoteAiGateway? value) => _gateway = value;

    Future<void> ingestText({
        required String source,
        required String text,
    }) async {
        for (final chunk in _chunks(text)) {
            await _addChunk(source: source, text: chunk);
        }
    }

    Future<void> ingestLines({
        required String source,
        required Stream<String> lines,
    }) async {
        final buffer = StringBuffer();
        await for (final line in lines) {
            buffer
                ..write(line)
                ..write('\n');
            while (buffer.length >= chunkSize) {
                final chunk = buffer.toString().substring(0, chunkSize);
                final overlapStart = max(0, chunkSize - chunkOverlap);
                final remainder = buffer.toString().substring(overlapStart);
                buffer
                    ..clear()
                    ..write(remainder);
                await _addChunk(source: source, text: chunk);
            }
        }
        final tail = buffer.toString().trim();
        if (tail.isNotEmpty) {
            await _addChunk(source: source, text: tail);
        }
    }

    Future<List<SearchResult>> search(
        String query, {
        int topK = 5,
    }) async {
        final vector = await _vectorize(query);
        return _index.search(vector, topK: topK);
    }

    Iterable<String> _chunks(String text) sync* {
        var start = 0;
        final step = max(1, chunkSize - chunkOverlap);
        while (start < text.length) {
            final end = min(text.length, start + chunkSize);
            final chunk = text.substring(start, end).trim();
            if (chunk.isNotEmpty) yield chunk;
            start += step;
        }
    }

    Future<void> _addChunk({
        required String source,
        required String text,
    }) async {
        final result = SearchResult(
            id: '${source.hashCode}_${_documentCounter++}',
            source: source,
            text: text,
            score: 0,
        );
        _index.insert(result, await _vectorize(text));
    }

    Future<List<double>> _vectorize(String text) async {
        final gateway = _gateway;
        if (gateway != null) {
            try {
                return await gateway.embed(text);
            } catch (_) {
            }
        }
        return _lexicalVector(text);
    }

    List<double> _lexicalVector(String text) {
        final vector = List<double>.filled(lexicalDimensions, 0);
        final tokens = RegExp(
            r'[\p{L}\p{N}_]+',
            unicode: true,
        ).allMatches(text.toLowerCase());

        for (final token in tokens) {
            var hash = 0x811c9dc5;
            for (final unit in token.group(0)!.codeUnits) {
                hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
            }
            vector[hash % lexicalDimensions] += 1;
        }
        return vector;
    }
}

class HnswVectorIndex {
    HnswVectorIndex({
        this.maxElements = 5000,
        this.maxConnections = 16,
        this.efConstruction = 80,
        Random? random,
    }) : _random = random ?? Random();

    final int maxElements;
    final int maxConnections;
    final int efConstruction;
    final Random _random;
    final Map<int, _HnswNode> _nodes = {};
    final Queue<int> _insertionOrder = Queue<int>();
    int _entryPoint = -1;
    int _maxLevel = -1;
    int _nextId = 0;
    int? _dimensions;

    void insert(SearchResult document, List<double> vector) {
        final normalized = _prepareVector(vector);
        final node = _HnswNode(
            id: _nextId++,
            document: document,
            vector: normalized,
            level: _randomLevel(),
        );

        _nodes[node.id] = node;
        _insertionOrder.addLast(node.id);
        _evictIfNeeded();

        if (_entryPoint < 0) {
            _entryPoint = node.id;
            _maxLevel = node.level;
            return;
        }

        var entryPoints = [_entryPoint];
        for (var level = _maxLevel; level > node.level; --level) {
            final nearest = _searchLayer(normalized, entryPoints, level, 1);
            if (nearest.isNotEmpty) {
                entryPoints = [nearest.first.id];
            }
        }

        final upperLevel = min(node.level, _maxLevel);
        for (var level = upperLevel; level >= 0; --level) {
            final neighbors = _searchLayer(
                normalized,
                entryPoints,
                level,
                efConstruction,
            ).where((candidate) => candidate.id != node.id)
                .take(maxConnections)
                .toList();

            node.connections[level] = neighbors.map((item) => item.id).toSet();
            for (final neighbor in neighbors) {
                final connections = _nodes[neighbor.id]
                    ?.connections
                    .putIfAbsent(level, () => <int>{});
                connections?.add(node.id);
                _pruneConnections(neighbor.id, level);
            }
            if (neighbors.isNotEmpty) {
                entryPoints = neighbors.map((item) => item.id).toList();
            }
        }

        if (node.level > _maxLevel) {
            _entryPoint = node.id;
            _maxLevel = node.level;
        }
    }

    List<SearchResult> search(
        List<double> query, {
        int topK = 5,
    }) {
        if (_entryPoint < 0) return const [];
        final normalized = _prepareVector(query);
        var entryPoints = [_entryPoint];

        for (var level = _maxLevel; level > 0; --level) {
            final nearest = _searchLayer(normalized, entryPoints, level, 1);
            if (nearest.isEmpty) break;
            entryPoints = [nearest.first.id];
        }

        return _searchLayer(
            normalized,
            entryPoints,
            0,
            max(efConstruction, topK),
        ).take(topK).map((candidate) {
            final document = candidate.node.document;
            return SearchResult(
                id: document.id,
                source: document.source,
                text: document.text,
                score: 1 - candidate.distance,
            );
        }).toList();
    }

    void _evictIfNeeded() {
        while (_nodes.length > maxElements && _insertionOrder.isNotEmpty) {
            _remove(_insertionOrder.removeFirst());
        }
    }

    void _remove(int id) {
        _nodes.remove(id);
        for (final node in _nodes.values) {
            for (final connections in node.connections.values) {
                connections.remove(id);
            }
        }
        if (_entryPoint == id) {
            _entryPoint = _nodes.isEmpty ? -1 : _nodes.keys.first;
            _maxLevel = _entryPoint < 0 ? -1 : _nodes[_entryPoint]!.level;
        }
    }

    int _randomLevel() {
        var level = 0;
        final multiplier = 1 / max(1, maxConnections);
        while (_random.nextDouble() < multiplier && level < 16) {
            level++;
        }
        return level;
    }

    List<_Candidate> _searchLayer(
        List<double> query,
        List<int> entryPoints,
        int level,
        int ef,
    ) {
        final visited = <int>{...entryPoints};
        final expanded = <int>{};
        final candidates = entryPoints
            .map((id) => _nodes[id])
            .whereType<_HnswNode>()
            .map((node) => _Candidate(node, _distance(query, node.vector)))
            .toList()
          ..sort((a, b) => a.distance.compareTo(b.distance));

        while (true) {
            _Candidate? next;
            for (final candidate in candidates) {
                if (!expanded.contains(candidate.id)) {
                    next = candidate;
                    break;
                }
            }
            if (next == null) break;
            expanded.add(next.id);

            final connections = next.node.connections[level] ?? const <int>{};
            for (final id in connections) {
                if (!visited.add(id)) continue;
                final node = _nodes[id];
                if (node == null) continue;
                candidates.add(_Candidate(node, _distance(query, node.vector)));
            }
            candidates.sort((a, b) => a.distance.compareTo(b.distance));
            if (candidates.length > ef) {
                candidates.removeRange(ef, candidates.length);
            }
        }
        return candidates;
    }

    void _pruneConnections(int id, int level) {
        final node = _nodes[id];
        final connections = node?.connections[level];
        if (node == null || connections == null ||
            connections.length <= maxConnections) {
            return;
        }

        final nearest = connections
            .map((neighborId) => _nodes[neighborId])
            .whereType<_HnswNode>()
            .map(
                (neighbor) => _Candidate(
                    neighbor,
                    _distance(node.vector, neighbor.vector),
                ),
            )
            .toList()
          ..sort((a, b) => a.distance.compareTo(b.distance));
        connections
            ..clear()
            ..addAll(nearest.take(maxConnections).map((item) => item.id));
    }

    List<double> _prepareVector(List<double> vector) {
        _dimensions ??= vector.length;
        final output = List<double>.from(vector);
        if (output.length < _dimensions!) {
            output.addAll(List<double>.filled(_dimensions! - output.length, 0));
        } else if (output.length > _dimensions!) {
            output.removeRange(_dimensions!, output.length);
        }

        var norm = 0.0;
        for (final value in output) {
            norm += value * value;
        }
        norm = sqrt(norm);
        if (norm == 0) return output;
        for (var i = 0; i < output.length; ++i) {
            output[i] /= norm;
        }
        return output;
    }

    double _distance(List<double> a, List<double> b) {
        var dot = 0.0;
        final length = min(a.length, b.length);
        for (var i = 0; i < length; ++i) {
            dot += a[i] * b[i];
        }
        return 1 - dot;
    }
}

class _HnswNode {
    _HnswNode({
        required this.id,
        required this.document,
        required this.vector,
        required this.level,
    });

    final int id;
    final SearchResult document;
    final List<double> vector;
    final int level;
    final Map<int, Set<int>> connections = {};
}

class _Candidate {
    const _Candidate(this.node, this.distance);

    final _HnswNode node;
    final double distance;

    int get id => node.id;
}
