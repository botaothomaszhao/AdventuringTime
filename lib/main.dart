import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'views/event_detail_page.dart';
import 'views/person_shell.dart';
import 'views/settings_page.dart';
import 'views/trip_detail_page.dart';

void main() {
  runApp(const ProviderScope(child: AdventuringTimeApp()));
}

class AdventuringTimeApp extends StatelessWidget {
  const AdventuringTimeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '探索的时光',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A7C59)),
        useMaterial3: true,
      ),
      initialRoute: '/',
      onGenerateRoute: generateRoute,
    );
  }
}

/// 路由生成（App 与测试入口共用）。
Route<dynamic> generateRoute(RouteSettings settings) {
  final segs = settings.name == '/' ? <String>[] : settings.name!.split('/').where((s) => s.isNotEmpty).toList();
  Widget page = const PersonHome();
  if (segs.isEmpty) {
    page = const PersonHome();
  } else if (segs.length == 4 && segs[0] == 'person' && segs[2] == 'trip') {
    page = TripDetailPage(personId: segs[1], tripId: segs[3]);
  } else if (segs.length == 4 && segs[0] == 'person' && segs[2] == 'event') {
    page = EventDetailPage(personId: segs[1], waypointId: segs[3]);
  } else if (segs.length == 1 && segs[0] == 'settings') {
    page = const SettingsPage();
  }
  return MaterialPageRoute(builder: (_) => page, settings: settings);
}
