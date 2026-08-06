/// Placeholders for server-side field transforms (former Firestore [FieldValue]).

abstract final class ApiFieldValue {

  static const Object _serverTimestamp = _ServerTimestamp();

  static const Object _deleteField = _DeleteField();



  static Object serverTimestamp() => _serverTimestamp;



  static Object delete() => _deleteField;

}



class _ServerTimestamp {

  const _ServerTimestamp();



  @override

  String toString() => '__SERVER_TIMESTAMP__';

}



class _DeleteField {

  const _DeleteField();



  @override

  String toString() => '__DELETE_FIELD__';

}



bool apiFieldValueIsServerTimestamp(Object? value) => value is _ServerTimestamp;



bool apiFieldValueIsDelete(Object? value) => value is _DeleteField;



/// Recursively converts [ApiFieldValue] placeholders into JSON-safe values.

Map<String, dynamic> serializeApiPayload(Map<String, dynamic> input) {

  final out = <String, dynamic>{};

  input.forEach((key, value) {

    if (apiFieldValueIsDelete(value)) return;

    if (apiFieldValueIsServerTimestamp(value)) {

      out[key] = DateTime.now().toUtc().toIso8601String();

      return;

    }

    if (value is Map<String, dynamic>) {

      out[key] = serializeApiPayload(value);

      return;

    }

    if (value is Map) {

      out[key] = serializeApiPayload(Map<String, dynamic>.from(value));

      return;

    }

    out[key] = value;

  });

  return out;

}



/// Strips delete-field placeholders from a PATCH/merge body.

Map<String, dynamic> serializeApiPatch(Map<String, dynamic> input) {

  final out = serializeApiPayload(input);

  input.forEach((key, value) {

    if (apiFieldValueIsDelete(value)) {

      out[key] = null;

    }

  });

  return out;

}


