import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fieldops/core/app_exception.dart';
import 'package:flutter_test/flutter_test.dart';

DioException resp(int status, [Object? body]) => DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: RequestOptions(path: '/x'), statusCode: status, data: body),
    );

void main() {
  test('wrong credentials show the server message, not "session expired"', () {
    final e = AppException.from(resp(401, {'error': {'code': 'invalid_credentials', 'message': 'Incorrect email or password'}}));
    expect(e.kind, ErrorKind.unauthorized);
    expect(e.message, 'Incorrect email or password');
  });

  test('other 401s mean the session expired', () {
    expect(AppException.from(resp(401, {'error': {'code': 'token_expired', 'message': 'x'}})).kind, ErrorKind.sessionExpired);
  });

  test('validation errors carry per-field messages', () {
    final e = AppException.from(resp(422, {'error': {'code': 'incomplete_job', 'message': 'Job cannot be completed yet', 'fields': {'evidence': 'At least 2 required'}}}));
    expect(e.kind, ErrorKind.validation);
    expect(e.fields['evidence'], 'At least 2 required');
  });

  test('409 is a conflict, 404 not found, 413 too large', () {
    expect(AppException.from(resp(409, {'error': {'code': 'invalid_transition', 'message': 'no'}})).kind, ErrorKind.conflict);
    expect(AppException.from(resp(404)).kind, ErrorKind.notFound);
    expect(AppException.from(resp(413)).kind, ErrorKind.tooLarge);
  });

  test('5xx (even with an HTML error page body) is a transient server error', () {
    final e = AppException.from(resp(502, '<html>Bad gateway</html>'));
    expect(e.kind, ErrorKind.server);
    expect(e.isTransient, isTrue);
  });

  test('timeouts and connection failures are transient and worded for humans', () {
    final t = AppException.from(DioException(requestOptions: RequestOptions(path: '/'), type: DioExceptionType.receiveTimeout));
    expect(t.kind, ErrorKind.timeout);
    expect(t.isTransient, isTrue);
    final n = AppException.from(DioException(requestOptions: RequestOptions(path: '/'), type: DioExceptionType.unknown, error: const SocketException('x')));
    expect(n.kind, ErrorKind.network);
    expect(n.message, isNot(contains('Socket')));
  });

  test('validation problems are not transient', () {
    expect(AppException.from(resp(422, {'error': {'code': 'validation_error', 'message': 'bad'}})).isTransient, isFalse);
  });
}
