import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'features/auth/login_screen.dart';
import 'features/shell/home_shell.dart';
import 'state/providers.dart';
import 'widgets/common.dart';

class FieldOpsApp extends ConsumerWidget {
  const FieldOpsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return MaterialApp(
      title: 'FieldOps',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: auth.when(
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (e, _) => Scaffold(body: ErrorState(error: e, onRetry: () => ref.invalidate(authProvider))),
        data: (session) => session == null ? const LoginScreen() : const HomeShell(),
      ),
    );
  }
}
