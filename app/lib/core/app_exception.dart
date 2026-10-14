import 'dart:io';

import 'package:dio/dio.dart';

enum ErrorKind { network, timeout, unauthorized, sessionExpired, validation, conflict, notFound, tooLarge, server, unknown }

/// Every failure the UI can see. Raw Dio/socket errors are converted here once.
class AppException implements Exception {
  const AppException(this.kind, this.message, {this.code, this.fields = const {}});

  factory AppException.validation(Map<String, String> fields, [String message = 'Please fix the highlighted fields.']) =>
      AppException(ErrorKind.validation, message, fields: fields);

  final ErrorKind kind;
  final String message;
  final String? code;
  final Map<String, String> fields;

  /// Worth retrying later without user action (offline, timeout, server hiccup).
  bool get isTransient => kind == ErrorKind.network || kind == ErrorKind.timeout || kind == ErrorKind.server;

  factory AppException.from(Object error) {
    if (error is AppException) return error;
    if (error is DioException) return _fromDio(error);
    return const AppException(ErrorKind.unknown, 'Something went wrong. Please try again.');
  }

  static AppException _fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const AppException(ErrorKind.timeout, 'The request timed out. Check your connection and try again.');
      case DioExceptionType.connectionError:
        return const AppException(ErrorKind.network, 'No internet connection.');
      case DioExceptionType.cancel:
        return const AppException(ErrorKind.unknown, 'The request was cancelled.');
      case DioExceptionType.unknown:
      case DioExceptionType.badCertificate:
        if (e.response == null) {
          final inner = e.error;
          if (inner is SocketException || inner is HandshakeException || inner is HttpException) {
            return const AppException(ErrorKind.network, 'No internet connection.');
          }
          return const AppException(ErrorKind.unknown, 'Something went wrong. Please try again.');
        }
      case DioExceptionType.badResponse:
        break;
    }
    final res = e.response!;
    final status = res.statusCode ?? 0;
    String? code;
    String? message;
    var fields = <String, String>{};
    final data = res.data;
    if (data is Map && data['error'] is Map) {
      final err = data['error'] as Map;
      code = err['code'] as String?;
      message = err['message'] as String?;
      if (err['fields'] is Map) {
        fields = (err['fields'] as Map).map((k, v) => MapEntry('$k', '$v'));
      }
    }
    if (status >= 500) {
      return AppException(ErrorKind.server, 'The server had a problem. Please try again shortly.', code: code);
    }
    if (status == 401) {
      if (code == 'invalid_credentials') {
        return AppException(ErrorKind.unauthorized, message ?? 'Incorrect email or password.', code: code);
      }
      return AppException(ErrorKind.sessionExpired, 'Your session has expired. Please sign in again.', code: code);
    }
    final kind = switch (status) {
      404 => ErrorKind.notFound,
      409 => ErrorKind.conflict,
      413 => ErrorKind.tooLarge,
      _ => ErrorKind.validation,
    };
    return AppException(kind, message ?? 'The request could not be completed.', code: code, fields: fields);
  }

  @override
  String toString() => message;
}
