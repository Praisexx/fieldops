import 'dart:async';

import 'package:dio/dio.dart';

import '../core/app_exception.dart';
import 'token_storage.dart';

typedef Json = Map<String, dynamic>;

/// All HTTP lives here. Callers get parsed models or an [AppException]; they never see Dio.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required this.tokens,
    required this.onSessionExpired,
    Dio? dio,
  }) : _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = baseUrl
      ..connectTimeout = const Duration(seconds: 15)
      ..receiveTimeout = const Duration(seconds: 30)
      ..sendTimeout = const Duration(seconds: 60)
      ..headers['Accept'] = 'application/json';
    _dio.interceptors.add(InterceptorsWrapper(onRequest: _onRequest, onError: _onError));
  }

  final Dio _dio;
  final TokenStorage tokens;

  /// Called once when the refresh token is rejected; the app should return to the login screen.
  final void Function() onSessionExpired;

  Future<Session>? _refreshing;

  bool _isAuthPath(RequestOptions o) => o.path.startsWith('/auth/');

  Future<void> _onRequest(RequestOptions o, RequestInterceptorHandler h) async {
    if (!_isAuthPath(o)) {
      var s = await tokens.read();
      if (s != null) {
        final exp = s.accessExpiry;
        // Refresh ahead of expiry so multipart uploads (which can't be replayed) don't hit a 401.
        if (exp != null && exp.difference(DateTime.now()).inSeconds < 30) {
          try {
            s = await _refresh();
          } on AppException catch (e) {
            if (e.kind == ErrorKind.sessionExpired) return h.reject(DioException(requestOptions: o, error: e));
            // Network trouble: try with the old token; the server will say if it's really expired.
          }
        }
        if (s != null) o.headers['Authorization'] = 'Bearer ${s.accessToken}';
      }
    }
    h.next(o);
  }

  Future<void> _onError(DioException e, ErrorInterceptorHandler h) async {
    final o = e.requestOptions;
    final unauthorized = e.response?.statusCode == 401 && !_isAuthPath(o);
    if (!unauthorized || o.extra['retried'] == true || o.data is FormData) return h.next(e);
    try {
      await _refresh();
      o.extra['retried'] = true;
      h.resolve(await _dio.fetch(o));
    } on DioException catch (inner) {
      h.next(inner);
    } on AppException catch (inner) {
      h.next(DioException(requestOptions: o, error: inner));
    }
  }

  /// Single-flight: concurrent 401s share one refresh call (refresh tokens are single-use).
  Future<Session> _refresh() {
    return _refreshing ??= () async {
      try {
        final s = await tokens.read();
        if (s == null) throw const AppException(ErrorKind.sessionExpired, 'Your session has expired. Please sign in again.');
        final Response<dynamic> res;
        try {
          res = await _dio.post('/auth/refresh', data: {'refreshToken': s.refreshToken});
        } catch (err) {
          final ex = AppException.from(err);
          if (ex.kind == ErrorKind.sessionExpired) {
            await tokens.clear();
            onSessionExpired();
          }
          throw ex;
        }
        final next = s.withTokens(res.data['accessToken'] as String, res.data['refreshToken'] as String);
        await tokens.write(next);
        return next;
      } finally {
        _refreshing = null;
      }
    }();
  }

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } on DioException catch (e) {
      throw e.error is AppException ? e.error as AppException : AppException.from(e);
    }
  }

  // ---- auth ----
  Future<Session> login(String email, String password) => _call(() async {
        final res = await _dio.post('/auth/login', data: {'email': email.trim(), 'password': password});
        final d = res.data as Map;
        final u = d['user'] as Map;
        return Session(
          accessToken: d['accessToken'] as String,
          refreshToken: d['refreshToken'] as String,
          userId: u['id'] as String,
          name: u['name'] as String,
          email: u['email'] as String,
        );
      });

  Future<void> logout(String refreshToken) async {
    try {
      await _dio.post('/auth/logout', data: {'refreshToken': refreshToken});
    } catch (_) {
      // Best effort: local sign-out must work offline.
    }
  }

  // ---- jobs ----
  Future<List<Json>> listJobs() => _call(() async {
        final res = await _dio.get('/jobs', queryParameters: {'limit': 100});
        return [for (final j in (res.data['items'] as List)) Json.from(j as Map)];
      });

  Future<Json> getJob(String id) => _call(() async => Json.from((await _dio.get('/jobs/$id')).data as Map));

  Future<void> postStatus(String id, {required String status, String? reason, required String clientId, required String occurredAt}) =>
      _call(() => _dio.post('/jobs/$id/status', data: {
            'status': status,
            if (reason != null) 'reason': reason,
            'clientId': clientId,
            'occurredAt': occurredAt,
          }));

  Future<void> putForm(String id, Json answers) => _call(() => _dio.put('/jobs/$id/form', data: {'answers': answers}));

  Future<void> postNote(String id, {required String body, required String clientId}) =>
      _call(() => _dio.post('/jobs/$id/notes', data: {'body': body, 'clientId': clientId}));

  Future<void> uploadEvidence(
    String id, {
    required String kind,
    required String clientId,
    String? text,
    String? filePath,
    String? filename,
    String? mime,
    void Function(double)? onProgress,
  }) =>
      _call(() async {
        if (kind == 'text') {
          await _dio.post('/jobs/$id/evidence', data: {'kind': 'text', 'text': text, 'clientId': clientId});
          return;
        }
        final form = FormData.fromMap({
          'kind': kind,
          'clientId': clientId,
          'file': await MultipartFile.fromFile(filePath!, filename: filename, contentType: mime == null ? null : DioMediaType.parse(mime)),
        });
        await _dio.post('/jobs/$id/evidence', data: form, onSendProgress: (sent, total) {
          if (total > 0) onProgress?.call(sent / total);
        });
      });

  Future<void> deleteEvidence(String jobId, String evidenceId) => _call(() => _dio.delete('/jobs/$jobId/evidence/$evidenceId'));

  Future<List<int>> downloadEvidence(String jobId, String evidenceId) => _call(() async {
        final res = await _dio.get<List<int>>('/jobs/$jobId/evidence/$evidenceId/file', options: Options(responseType: ResponseType.bytes));
        return res.data!;
      });
}
