import 'dart:async';

import 'api_client.dart';
import 'api_config.dart';
import 'api_exceptions.dart';
import 'api_field_value.dart';

typedef DocumentReference<T> = ApiDocRef;

class ApiDocumentSnapshot {
  ApiDocumentSnapshot({
    required this.id,
    required this.collection,
    required this.exists,
    Map<String, dynamic>? data,
  }) : _data = data;

  final String id;
  final String collection;
  final bool exists;
  final Map<String, dynamic>? _data;

  Map<String, dynamic>? data() => _data;

  ApiDocRef get reference => ApiDocRef(collection, id);
}

class ApiQuerySnapshot {
  ApiQuerySnapshot(this.docs);
  final List<ApiDocumentSnapshot> docs;
}

class ApiGetOptions {
  const ApiGetOptions({this.source = ApiSource.defaultSource});
  final ApiSource source;
}

enum ApiSource {
  defaultSource,
  server,
  serverAndCache,
}

class ApiSetOptions {
  const ApiSetOptions({this.merge = false});
  final bool merge;
}

class ApiDocRef {
  ApiDocRef(this.collection, this.id);

  final String collection;
  final String id;

  String get path => _path;

  String get _path => '/api/${collection.replaceAll('.', '/')}/$id/';

  Future<ApiDocumentSnapshot> get([ApiGetOptions? options]) async {
    try {
      final json = await ApiClient.instance.getJson(_path);
      if (json == null) {
        return ApiDocumentSnapshot(
          id: id,
          collection: collection,
          exists: false,
        );
      }
      return ApiDocumentSnapshot(
        id: id,
        collection: collection,
        exists: true,
        data: json,
      );
    } on ApiException catch (e) {
      if (e.code == 'not-found') {
        return ApiDocumentSnapshot(
          id: id,
          collection: collection,
          exists: false,
        );
      }
      rethrow;
    }
  }

  Future<void> set(
    Map<String, dynamic> payload, [
    ApiSetOptions? options,
  ]) async {
    final body = options?.merge == true
        ? serializeApiPatch(payload)
        : _serializePayload(payload);
    if (options?.merge == true) {
      await ApiClient.instance.patchJson(_path, body);
    } else {
      await ApiClient.instance.postJson(_path, body);
    }
  }

  Future<void> update(Map<String, dynamic> payload) async {
    await ApiClient.instance.patchJson(_path, _serializePayload(payload));
  }

  Future<void> delete() => ApiClient.instance.delete(_path);

  Stream<ApiDocumentSnapshot> snapshots({
    Duration interval = const Duration(seconds: 3),
  }) async* {
    ApiDocumentSnapshot? last;
    while (true) {
      final snap = await get();
      if (last == null ||
          last.exists != snap.exists ||
          last.data()?.toString() != snap.data()?.toString()) {
        last = snap;
        yield snap;
      }
      await Future<void>.delayed(interval);
    }
  }
}

class ApiCollectionQuery {
  ApiCollectionQuery(this.collection, [this._query = const {}]);

  final String collection;
  final Map<String, String> _query;

  ApiCollectionQuery limit(int n) {
    return ApiCollectionQuery(collection, {..._query, 'limit': '$n'});
  }

  ApiCollectionQuery orderBy(String field, {bool descending = false}) {
    return ApiCollectionQuery(collection, {
      ..._query,
      'ordering': descending ? '-$field' : field,
    });
  }

  ApiCollectionQuery where(
    String field, {
    Object? isEqualTo,
    List<Object?>? whereIn,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
  }) {
    final next = {..._query};
    if (whereIn != null) {
      next['${field}__in'] = whereIn.map((e) => e.toString()).join(',');
    } else if (isEqualTo != null) {
      next[field] = isEqualTo.toString();
    }
    if (isGreaterThan != null) {
      next['${field}__gt'] = isGreaterThan.toString();
    }
    if (isGreaterThanOrEqualTo != null) {
      next['${field}__gte'] = isGreaterThanOrEqualTo.toString();
    }
    if (isLessThan != null) {
      next['${field}__lt'] = isLessThan.toString();
    }
    if (isLessThanOrEqualTo != null) {
      next['${field}__lte'] = isLessThanOrEqualTo.toString();
    }
    return ApiCollectionQuery(collection, next);
  }

  Future<ApiQuerySnapshot> get([ApiGetOptions? options]) async {
    final path = '/api/${collection.replaceAll('.', '/')}/';
    final raw = await ApiClient.instance.getDynamic(path, query: _query);
    final rows = _rowsFromListResponse(raw);
    final docs = <ApiDocumentSnapshot>[];
    for (final row in rows) {
      final id = (row['id'] ?? row['registration_number'] ?? row['registrationNumber'])
              ?.toString() ??
          '';
      docs.add(
        ApiDocumentSnapshot(
          id: id,
          collection: collection,
          exists: true,
          data: row,
        ),
      );
    }
    return ApiQuerySnapshot(docs);
  }

  Stream<ApiQuerySnapshot> snapshots({
    Duration interval = const Duration(seconds: 5),
  }) async* {
    ApiQuerySnapshot? last;
    while (true) {
      final snap = await get();
      final ids = snap.docs.map((d) => d.id).join(',');
      final lastIds = last?.docs.map((d) => d.id).join(',') ?? '';
      if (last == null || ids != lastIds) {
        last = snap;
        yield snap;
      }
      await Future<void>.delayed(interval);
    }
  }
}

class ApiCollectionRef {
  ApiCollectionRef(this.name);

  final String name;

  ApiDocRef doc(String id) => ApiDocRef(name, id);

  ApiCollectionQuery where(
    String field, {
    Object? isEqualTo,
    List<Object?>? whereIn,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
  }) =>
      ApiCollectionQuery(name).where(
        field,
        isEqualTo: isEqualTo,
        whereIn: whereIn,
        isGreaterThan: isGreaterThan,
        isGreaterThanOrEqualTo: isGreaterThanOrEqualTo,
        isLessThan: isLessThan,
        isLessThanOrEqualTo: isLessThanOrEqualTo,
      );

  ApiCollectionQuery orderBy(String field, {bool descending = false}) =>
      ApiCollectionQuery(name).orderBy(field, descending: descending);

  ApiCollectionQuery limit(int n) => ApiCollectionQuery(name).limit(n);

  Future<ApiQuerySnapshot> get([ApiGetOptions? options]) =>
      ApiCollectionQuery(name).get(options);

  Future<ApiDocumentSnapshot> add(Map<String, dynamic> payload) async {
    final path = '/api/${name.replaceAll('.', '/')}/';
    final body = _serializePayload(payload);
    final json = await ApiClient.instance.postJson(path, body);
    final id = (json?['id'] ?? json?['pk'])?.toString() ?? '';
    return ApiDocumentSnapshot(
      id: id,
      collection: name,
      exists: true,
      data: json,
    );
  }

  Stream<ApiQuerySnapshot> snapshots({
    Duration interval = const Duration(seconds: 5),
  }) =>
      ApiCollectionQuery(name).snapshots(interval: interval);
}

class ApiWriteBatch {
  final _pending = <Future<void>>[];

  void set(
    ApiDocRef ref,
    Map<String, dynamic> data, [
    ApiSetOptions? options,
  ]) {
    _pending.add(ref.set(data, options));
  }

  void delete(ApiDocRef ref) {
    _pending.add(ref.delete());
  }

  Future<void> commit() async {
    for (final op in _pending) {
      await op;
    }
  }
}

class ApiStore {
  ApiStore._();
  static final ApiStore instance = ApiStore._();

  ApiCollectionRef collection(String name) => ApiCollectionRef(name);

  ApiWriteBatch batch() => ApiWriteBatch();

  Future<T> runTransaction<T>(
    Future<T> Function(ApiTransaction transaction) action,
  ) async {
    final tx = ApiTransaction();
    final result = await action(tx);
    await tx.commit();
    return result;
  }
}

class ApiTransaction {
  final _pending = <Future<void>>[];

  Future<ApiDocumentSnapshot> get(ApiDocRef ref) => ref.get();

  void set(
    ApiDocRef ref,
    Map<String, dynamic> data, [
    ApiSetOptions? options,
  ]) {
    _pending.add(ref.set(data, options));
  }

  Future<void> commit() async {
    for (final op in _pending) {
      await op;
    }
  }
}

List<Map<String, dynamic>> _rowsFromListResponse(dynamic raw) {
  if (raw is List) {
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }
  if (raw is Map<String, dynamic>) {
    final results = raw['results'];
    if (results is List) {
      return results
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
  }
  return const [];
}

Map<String, dynamic> _serializePayload(Map<String, dynamic> input) =>
    serializeApiPayload(input);

bool get isApiInitialized => isApiConfigured;

ApiStore? tryApiStore() => isApiConfigured ? ApiStore.instance : null;

ApiStore apiStore() {
  if (!isApiConfigured) {
    throw StateError('API is not configured');
  }
  return ApiStore.instance;
}
