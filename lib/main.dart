import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'views/people_page.dart';
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
      onGenerateRoute: (settings) {
        final segs = settings.name == '/' ? <String>[] : settings.name!.split('/').where((s) => s.isNotEmpty).toList();
        Widget page = const PeoplePage();
        if (segs.isEmpty) {
          page = const PeoplePage();
        } else if (segs.length == 3 && segs[0] == 'person' && segs[2] == 'map') {
          page = PersonShell(personId: segs[1], initialTab: 0);
        } else if (segs.length == 3 && segs[0] == 'person' && segs[2] == 'timeline') {
          page = PersonShell(personId: segs[1], initialTab: 1);
        } else if (segs.length == 3 && segs[0] == 'person' && segs[2] == 'stats') {
          page = PersonShell(personId: segs[1], initialTab: 2);
        } else if (segs.length == 4 && segs[0] == 'person' && segs[2] == 'trip') {
          page = TripDetailPage(personId: segs[1], tripId: segs[3]);
        } else if (segs.length == 1 && segs[0] == 'settings') {
          page = const SettingsPage();
        }
        return MaterialPageRoute(builder: (_) => page, settings: settings);
      },
    );
  }
}
