import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../core/firebase/firestore_collections.dart';
import '../../core/firebase/u_panel_firestore.dart';
import '../../core/theme/app_theme.dart';

/// Admin-only directory of registered lecturers ([lecturers] collection).
class LecturersListScreen extends StatelessWidget {
  const LecturersListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lecturers'),
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: uPanelFirestore()
            .collection(FirestoreCollections.lecturers)
            .snapshots(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs
              .where((d) => d.data()['isLecturer'] == true)
              .toList()
            ..sort((a, b) {
              final sa = (a.data()['staffNumber'] as String?) ?? '';
              final sb = (b.data()['staffNumber'] as String?) ?? '';
              return sa.compareTo(sb);
            });
          if (docs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No lecturers yet. Open Dashboard → Staff & accounts → Register staff.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final d = docs[i];
              final data = d.data();
              final staff = (data['staffNumber'] as String?) ?? '—';
              final name = (data['fullName'] as String?)?.trim();
              final title = (name != null && name.isNotEmpty) ? name : staff;
              final subtitle = (name != null && name.isNotEmpty) ? staff : null;
              return ListTile(
                title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: subtitle != null
                    ? Text(subtitle, style: const TextStyle(fontSize: 12))
                    : null,
              );
            },
          );
        },
      ),
    );
  }
}
